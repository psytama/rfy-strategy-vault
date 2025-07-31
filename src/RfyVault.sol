// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC4626Upgradeable, IERC4626 } from "openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { AccessControlUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "openzeppelin-contracts-upgradeable/contracts/utils/ReentrancyGuardUpgradeable.sol";
import { IRfyVault } from "./interfaces/IRfyVault.sol";

/**
 * @title RfyVault
 * @dev Vault contract for managing deposits, withdrawals, and trading epochs
 */
contract RfyVault is
	ERC4626Upgradeable,
	AccessControlUpgradeable,
	UUPSUpgradeable,
	ReentrancyGuardUpgradeable,
	IRfyVault
{
	using SafeERC20 for IERC20;

	bytes32 public constant TRADER_ROLE = keccak256("TRADER_ROLE");
	bytes32 public constant BOOTSTRAPPER_ROLE = keccak256("BOOTSTRAPPER_ROLE");

	/*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

	/// @notice Address of external vault
	IERC4626 public override externalVault;

	/// @notice Whether deposits are currently allowed
	bool public override depositsPaused;

	/// @notice Whether withdrawals are currently allowed
	bool public override withdrawalsPaused;

	/// @notice Duration of each epoch in seconds
	uint256 public override epochDuration;

	/// @notice Current epoch number
	uint256 public override currentEpoch;

	/// @notice Total tracked balance of assets in the vault
	uint256 private _totalAssets;

	/// @notice Maximum total assets that can be deposited in the vault
	uint256 public maxTotalDeposits;

	/// @notice Meme name associated with this vault
	string public memeName;

	/// @notice Mapping of epoch number to epoch data
	mapping(uint256 => EpochData) public _epochs;

	/**
	 * @dev Initializes the contract after deployment
	 */
	function initialize(
		string calldata _tokenName,
		string calldata _tokenSymbol,
		string calldata _memeName,
		address _asset,
		address _owner,
		address _trader,
		address _externalVault,
		uint256 _epochDuration,
		uint256 _maxTotalDeposits
	) public override initializer {
		__ERC4626_init(IERC20(_asset));
		__ERC20_init(_tokenName, _tokenSymbol);
		__AccessControl_init();
		__UUPSUpgradeable_init();
		__ReentrancyGuard_init();

		if (address(_asset) == address(0) || _owner == address(0)) revert SV_InvalidAddress();

		_grantRole(DEFAULT_ADMIN_ROLE, _owner);
		_grantRole(TRADER_ROLE, _trader);
		_grantRole(BOOTSTRAPPER_ROLE, _owner);
		epochDuration = _epochDuration;
		externalVault = IERC4626(_externalVault);
		memeName = _memeName;
		maxTotalDeposits = _maxTotalDeposits;
	}

	/*//////////////////////////////////////////////////////////////
                        EPOCH MANAGEMENT
    //////////////////////////////////////////////////////////////*/

	/**
	 * @notice Starts a new trading epoch
	 * @dev Only admin can start an epoch, and only when no epoch is active
	 */
	function startNewEpoch() external override onlyRole(BOOTSTRAPPER_ROLE) {
		uint256 newEpochId = ++currentEpoch;
		if (_epochs[newEpochId - 1].isEpochActive) {
			revert SV_EpochActive();
		}

		EpochData storage newEpoch = _epochs[newEpochId];

		uint256 amountToDeposit = _totalAssets;
		if (amountToDeposit == 0) revert SV_NoAvailableFunds();

		newEpoch.startTime = uint96(block.timestamp);
		newEpoch.initialVaultAssets = amountToDeposit;

		uint256 maxDeposit_ = address(externalVault) != address(0) ? externalVault.maxDeposit(address(this)) : 0;
		uint256 unutilizedDeposit;
		if (amountToDeposit > maxDeposit_) {
			unutilizedDeposit = amountToDeposit - maxDeposit_;
			amountToDeposit = maxDeposit_;
		}

		// Deposit all available funds into external vault
		if (address(externalVault) != address(0)) {
			IERC20(asset()).approve(address(externalVault), amountToDeposit);
			externalVault.deposit(amountToDeposit, address(this));
		}

		newEpoch.initialExternalVaultDeposits = amountToDeposit;
		newEpoch.initialUnutilizedAsset = unutilizedDeposit;
		newEpoch.currentExternalVaultDeposits = amountToDeposit;
		newEpoch.currentUnutilizedAsset = unutilizedDeposit;
		newEpoch.isEpochActive = true;

		depositsPaused = true;
		withdrawalsPaused = true;

		emit EpochStarted(newEpochId, block.timestamp);
	}

	/*//////////////////////////////////////////////////////////////
                        TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

	/**
	 * @notice Allows trader to borrow funds during an active epoch
	 * @param amount Amount to borrow
	 */
	function borrow(uint256 amount) external override onlyRole(TRADER_ROLE) {
		if (amount == 0) revert SV_InvalidAmount();
		EpochData storage epoch = _epochs[currentEpoch];
		if (!epoch.isEpochActive) revert SV_EpochNotActive();

		uint256 unutilized = epoch.currentUnutilizedAsset;
		uint256 availableExternalVaultShares = _getExternalVaultBalance();

		uint256 borrowing = amount;

		// First use unutilized assets if available
		uint256 utilizing;
		if (unutilized != 0) {
			utilizing = borrowing > unutilized ? unutilized : borrowing;
			epoch.currentUnutilizedAsset -= utilizing;
			borrowing -= utilizing;
		}

		// If we still need more funds, withdraw from ExternalVault
		if (borrowing != 0) {
			if (availableExternalVaultShares == 0 && utilizing == 0) revert SV_ExternalVaultSharesZero();

			uint256 maxWithdrawable = _getExternalVaultPreviewRedeem();

			if (borrowing >= maxWithdrawable) {
				borrowing = _externalVaultRedeem(availableExternalVaultShares);

				int256 externalVaultPnl = int256(borrowing) - int256(epoch.currentExternalVaultDeposits);

				epoch.externalVaultPnl += externalVaultPnl;
				epoch.currentExternalVaultDeposits = 0;
			} else {
				if (address(externalVault) != address(0)) {
					externalVault.withdraw(borrowing, address(this), address(this));
				}
				epoch.currentExternalVaultDeposits -= borrowing;
			}
		}

		uint256 amountToTransfer = utilizing + borrowing;

		epoch.fundsBorrowed += amountToTransfer;
		IERC20(asset()).safeTransfer(msg.sender, amountToTransfer);

		emit FundsBorrowed(msg.sender, amountToTransfer);
	}

	/**
	 * @notice Settles borrowed funds with PnL
	 * @param pnl Profit (positive) or loss (negative)
	 */
	function settle(int256 pnl) external onlyRole(TRADER_ROLE) {
		EpochData storage epoch = _epochs[currentEpoch];
		if (!epoch.isEpochActive) revert SV_EpochNotActive();

		if (epoch.startTime + epochDuration > uint96(block.timestamp)) revert SV_EpochNotEnded();

		uint256 fundsBorrowed_ = epoch.fundsBorrowed;

		// Check if negative PnL exceeds funds borrowed
		if (pnl < 0 && uint256(-pnl) > fundsBorrowed_) revert SV_LossExceedsBorrowAmount();

		// Calculate funds to be returned by trader
		uint256 fundsToTransfer = pnl > 0 ? fundsBorrowed_ + uint256(pnl) : fundsBorrowed_ - uint256(-pnl);

		// Track total PnL including both trading and external vault

		// Transfer funds from trader if any
		if (fundsToTransfer != 0) {
			IERC20(asset()).safeTransferFrom(msg.sender, address(this), fundsToTransfer);
		}

		// Calculate ExternalVault yield
		int256 realizedExternalVaultPnl = epoch.externalVaultPnl;
		uint256 currentExternalVaultShares = _getExternalVaultBalance();

		if (currentExternalVaultShares != 0) {
			uint256 assets_ = _externalVaultRedeem(currentExternalVaultShares);

			realizedExternalVaultPnl += int256(assets_) - int256(epoch.currentExternalVaultDeposits);
		}
		int256 totalPnl = pnl + realizedExternalVaultPnl;

		// Update total assets based on PnL
		uint256 finalVaultAssets = uint256(int256(epoch.initialVaultAssets) + totalPnl);
		_totalAssets = finalVaultAssets;
		// Update epoch final state
		epoch.tradingPnl = pnl;
		epoch.externalVaultPnl = realizedExternalVaultPnl;
		epoch.finalVaultAssets = finalVaultAssets;
		epoch.currentExternalVaultDeposits = 0;
		epoch.currentUnutilizedAsset = 0;
		epoch.isSettled = true;
		epoch.endTime = uint96(block.timestamp);
		epoch.isEpochActive = false;

		// Update vault state - only unpause withdrawals, keep deposits paused
		withdrawalsPaused = false;
		// depositsPaused remains true until explicitly enabled by admin

		emit FundsSettled(msg.sender, fundsBorrowed_, pnl);
		emit EpochEnded(currentEpoch, block.timestamp);
	}
	/*//////////////////////////////////////////////////////////////
                        CORE VAULT LOGIC
    //////////////////////////////////////////////////////////////*/

	function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
		return _totalAssets;
	}

	function deposit(
		uint256 assets,
		address receiver
	) public override(ERC4626Upgradeable, IERC4626) nonReentrant returns (uint256) {
		if (depositsPaused) revert SV_DepositsArePaused();
		uint256 shares = super.deposit(assets, receiver);
		_totalAssets += assets;
		return shares;
	}

	function withdraw(
		uint256 assets,
		address receiver,
		address owner
	) public override(ERC4626Upgradeable, IERC4626) nonReentrant returns (uint256) {
		if (withdrawalsPaused) revert SV_WithdrawalsArePaused();

		uint256 shares = super.withdraw(assets, receiver, owner);
		_totalAssets -= assets;
		return shares;
	}

	function mint(
		uint256 shares,
		address receiver
	) public override(ERC4626Upgradeable, IERC4626) nonReentrant returns (uint256) {
		if (depositsPaused) revert SV_DepositsArePaused();

		uint256 actualAssets = super.mint(shares, receiver);
		_totalAssets += actualAssets;
		return actualAssets;
	}

	/**
	 * @notice Redeems vault shares
	 * @dev Updates internal accounting of total assets
	 */
	function redeem(
		uint256 shares,
		address receiver,
		address owner
	) public override(ERC4626Upgradeable, IERC4626) nonReentrant returns (uint256) {
		if (withdrawalsPaused) revert SV_WithdrawalsArePaused();
		uint256 assets = super.redeem(shares, receiver, owner);
		_totalAssets -= assets;
		return assets;
	}

	function _externalVaultRedeem(uint256 shares) internal returns (uint256 redeemed) {
		if (address(externalVault) != address(0)) {
			redeemed = externalVault.redeem(shares, address(this), address(this));
		}
	}

	/**
	 * @notice Returns the maximum amount of assets that can be deposited
	 * @dev Overrides the EIP-4626 maxDeposit function to reflect vault's deposit limit
	 * @return The maximum amount of assets that can be deposited
	 */
	function maxDeposit(address owner) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
		if (depositsPaused) return 0;
		
		// Check if we've reached the global cap
		if (_totalAssets >= maxTotalDeposits) return 0;
		
		uint256 remaining = maxTotalDeposits - _totalAssets;
		uint256 superMax = super.maxDeposit(owner);
		
		return remaining < superMax ? remaining : superMax;
	}

	/**
	 * @notice Returns the maximum amount of shares that can be minted
	 * @dev Overrides the EIP-4626 maxMint function to reflect vault's deposit limit
	 * @return The maximum amount of shares that can be minted
	 */
	function maxMint(address owner) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
		if (depositsPaused) return 0;
		
		// Check if we've reached the global cap
		if (_totalAssets >= maxTotalDeposits) return 0;
		
		uint256 remaining = maxTotalDeposits - _totalAssets;
		uint256 superMax = super.maxMint(owner);
		
		// Convert remaining assets to shares
		uint256 remainingShares = previewDeposit(remaining);
		
		return remainingShares < superMax ? remainingShares : superMax;
	}

	/**
	 * @notice Returns the maximum amount of assets that can be withdrawn
	 * @dev Overrides the EIP-4626 maxWithdraw function to reflect vault's withdrawal state
	 * @return The maximum amount of assets that can be withdrawn
	 */
	function maxWithdraw(address owner) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
		// If withdrawals are paused, no withdrawals are allowed
		if (withdrawalsPaused) return 0;
		return super.maxWithdraw(owner);
	}

	/**
	 * @notice Returns the maximum amount of shares that can be redeemed
	 * @dev Overrides the EIP-4626 maxRedeem function to reflect vault's withdrawal state
	 * @return The maximum amount of shares that can be redeemed
	 */
	function maxRedeem(address owner) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
		// If withdrawals are paused, no redemptions are allowed
		if (withdrawalsPaused) return 0;

		return super.maxRedeem(owner);
	}

	/**
	 * @notice Previews the amount of shares received for a deposit
	 * @dev Returns 0 if deposits are paused
	 */
	function previewDeposit(
		uint256 assets
	) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
		if (depositsPaused) return 0;
		return super.previewDeposit(assets);
	}

	/**
	 * @notice Previews the amount of assets required to mint shares
	 * @dev Returns 0 if deposits are paused
	 */
	function previewMint(uint256 shares) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
		if (depositsPaused) return 0;
		return super.previewMint(shares);
	}

	/**
	 * @notice Previews the amount of assets received for a withdrawal
	 * @dev Returns 0 if withdrawals are paused
	 */
	function previewWithdraw(
		uint256 assets
	) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
		if (withdrawalsPaused) return 0;
		return super.previewWithdraw(assets);
	}

	/**
	 * @notice Returns the maximum amount that can be borrowed during an active epoch
	 * @return The maximum amount that can be borrowed
	 */
	function maxBorrow() public view override returns (uint256) {
		EpochData memory epoch = _epochs[currentEpoch];
		if (!epoch.isEpochActive) return 0;

		uint256 unutilized = epoch.currentUnutilizedAsset;
		uint256 externalVaultDeposits = _getExternalVaultPreviewRedeem();
		uint256 totalAvailable;

		if (externalVaultDeposits > epoch.currentExternalVaultDeposits) {
			totalAvailable = unutilized + externalVaultDeposits;
		} else {
			totalAvailable = unutilized + epoch.currentExternalVaultDeposits;
		}
		return totalAvailable;
	}

	/**
	 * @notice Previews the amount of assets received for redeeming shares
	 * @dev Returns 0 if withdrawals are paused
	 */
	function previewRedeem(
		uint256 shares
	) public view virtual override(ERC4626Upgradeable, IERC4626) returns (uint256) {
		if (withdrawalsPaused) return 0;
		return super.previewRedeem(shares);
	}

	function getEpochData(uint256 epochId) public view override returns (EpochData memory) {
		return _epochs[epochId];
	}

	function _getExternalVaultBalance() internal view returns (uint256 balance) {
		if (address(externalVault) != address(0)) {
			balance = externalVault.balanceOf(address(this));
		}
	}

	function _getExternalVaultPreviewRedeem() internal view returns (uint256 reedemable) {
		if (address(externalVault) != address(0)) {
			reedemable = externalVault.previewRedeem(_getExternalVaultBalance());
		}
	}

	/*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

	function setDepositsPaused(bool paused) external override onlyRole(DEFAULT_ADMIN_ROLE) {
		depositsPaused = paused;
		emit DepositsStatusUpdated(paused);
	}

	function setWithdrawalsPaused(bool paused) external override onlyRole(DEFAULT_ADMIN_ROLE) {
		withdrawalsPaused = paused;
		emit WithdrawalsStatusUpdated(paused);
	}

	/**
	 * @notice Sets the duration for future epochs
	 * @dev Only admin can set the epoch duration, and it cannot be changed during an active epoch
	 * @param newDuration New duration in seconds
	 */
	function setEpochDuration(uint256 newDuration) external override onlyRole(DEFAULT_ADMIN_ROLE) {
		EpochData storage epoch = _epochs[currentEpoch];
		if (epoch.isEpochActive) revert SV_EpochNotActive();
		if (newDuration == 0) revert SV_InvalidDuration();

		epochDuration = newDuration;
		emit EpochDurationUpdated(newDuration);
	}

	/**
	 * @notice Sets the maximum total deposits allowed in the vault
	 * @dev Only admin can set this, and it cannot be set lower than current total assets
	 * @param newMaxTotalDeposits New maximum total deposits
	 */
	function setMaxTotalDeposits(uint256 newMaxTotalDeposits) external onlyRole(DEFAULT_ADMIN_ROLE) {
		if (newMaxTotalDeposits < _totalAssets) revert SV_InvalidAmount();
		maxTotalDeposits = newMaxTotalDeposits;
	}

	function pauseAll() external override onlyRole(DEFAULT_ADMIN_ROLE) {
		depositsPaused = true;
		withdrawalsPaused = true;
		emit DepositWithdrawalPaused();
	}

	function unpauseAll() external override onlyRole(DEFAULT_ADMIN_ROLE) {
		EpochData storage epoch = _epochs[currentEpoch];
		if (epoch.isEpochActive) revert SV_EpochNotActive();
		depositsPaused = false;
		withdrawalsPaused = false;
		emit DepositWithdrawalUnpaused();
	}

	function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
