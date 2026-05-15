// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { IRfyVault } from "./interfaces/IRfyVault.sol";
import { IRfyVaultManager } from "./interfaces/IRfyVaultManager.sol";

contract RfyVaultManager is Ownable, ReentrancyGuard, IRfyVaultManager {
	using SafeERC20 for IERC20;

	/*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

	/// @notice Whether a vault has been registered and is usable in this manager
	mapping(address vault => bool) public registeredVaults;

	/// @notice Deposit round data per vault per round id
	mapping(address vault => mapping(uint256 round => DepositRound)) public depositRounds;

	/// @notice Withdrawal round data per vault per round id
	mapping(address vault => mapping(uint256 round => WithdrawalRound)) public withdrawalRounds;

	/// @notice Currently open (unprocessed) deposit round id per vault
	mapping(address vault => uint256) public currentDepositRound;

	/// @notice Currently open (unprocessed) withdrawal round id per vault
	mapping(address vault => uint256) public currentWithdrawalRound;

	/// @notice Amount of assets each user queued per vault per deposit round
	mapping(address vault => mapping(address user => mapping(uint256 round => uint256))) public userDepositAmounts;

	/// @notice Amount of vault shares each user queued per vault per withdrawal round
	mapping(address vault => mapping(address user => mapping(uint256 round => uint256))) public userWithdrawalShares;

	/// @notice Tracks the highest deposit round a user has participated in per vault (for view helpers)
	mapping(address vault => mapping(address user => uint256)) private _userHighestDepositRound;

	/// @notice Tracks the highest withdrawal round a user has participated in per vault (for view helpers)
	mapping(address vault => mapping(address user => uint256)) private _userHighestWithdrawalRound;

	/// @notice Vault shares the user has parked inside this contract (via {claimSharesInternal}).
	///         {queueWithdrawal} will consume this balance before pulling from the user's wallet.
	mapping(address vault => mapping(address user => uint256)) public internalShareBalance;

	/// @notice Underlying assets the user has parked inside this contract (via direct
	///         {withdrawFromVault} / {withdraw}). Keyed by asset address — NOT by vault —
	///         so users with positions across multiple vaults sharing an asset can pull a
	///         single consolidated balance.
	mapping(address asset => mapping(address user => uint256)) public internalAssetBalance;

	/// @notice Public registry of every vault ever registered, in registration order.
	///         Mirrors {registeredVaults} — use this for off-chain enumeration.
	address[] public allVaults;

	/*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

	constructor(address _owner) Ownable(_owner) {}

	/*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

	modifier onlyRegisteredVault(address vault) {
		if (!registeredVaults[vault]) revert VM_VaultNotRegistered();
		_;
	}

	/*//////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

	/// @inheritdoc IRfyVaultManager
	function registerVault(address vault) external onlyOwner {
		if (vault == address(0)) revert VM_InvalidAddress();
		if (registeredVaults[vault]) revert VM_VaultAlreadyRegistered();

		IRfyVault(vault).asset();

		registeredVaults[vault] = true;
		allVaults.push(vault);
		emit VaultRegistered(vault);
	}

	/// @inheritdoc IRfyVaultManager
	function emergencyWithdraw(
		address token,
		address to,
		uint256 amount
	) external onlyOwner {
		if (token == address(0) || to == address(0)) revert VM_InvalidAddress();
		if (amount == 0) revert VM_InvalidAmount();
		IERC20(token).safeTransfer(to, amount);
		emit EmergencyWithdrawn(token, to, amount);
	}

	/// @inheritdoc IRfyVaultManager
	function vaultsLength() external view returns (uint256) {
		return allVaults.length;
	}

	/*//////////////////////////////////////////////////////////////
                            USER — DEPOSITS
    //////////////////////////////////////////////////////////////*/

	/// @inheritdoc IRfyVaultManager
	function queueDeposit(
		address vault,
		uint256 assets
	) external nonReentrant onlyRegisteredVault(vault) {
		if (assets == 0) revert VM_InvalidAmount();

		uint256 round = currentDepositRound[vault];
		address assetToken = IRfyVault(vault).asset();

		// consume parked internal asset balance first; pull only the shortfall from the wallet
		uint256 internalBal = internalAssetBalance[assetToken][msg.sender];
		uint256 fromInternal = internalBal < assets ? internalBal : assets;
		if (fromInternal != 0) {
			internalAssetBalance[assetToken][msg.sender] = internalBal - fromInternal;
			emit InternalAssetsConsumed(assetToken, msg.sender, fromInternal);
		}
		uint256 shortfall = assets - fromInternal;
		if (shortfall != 0) {
			IERC20(assetToken).safeTransferFrom(msg.sender, address(this), shortfall);
		}

		depositRounds[vault][round].totalAssets += assets;
		userDepositAmounts[vault][msg.sender][round] += assets;

		if (round > _userHighestDepositRound[vault][msg.sender]) {
			_userHighestDepositRound[vault][msg.sender] = round;
		}

		emit DepositQueued(vault, msg.sender, round, assets);
	}

	/// @inheritdoc IRfyVaultManager
	function cancelDeposit(
		address vault,
		uint256 round,
		uint256 amount
	) external nonReentrant onlyRegisteredVault(vault) {
		if (amount == 0) revert VM_InvalidAmount();
		if (depositRounds[vault][round].processed) revert VM_RoundAlreadyProcessed();

		uint256 userQueued = userDepositAmounts[vault][msg.sender][round];
		if (amount > userQueued) revert VM_InsufficientBalance();

		userDepositAmounts[vault][msg.sender][round] -= amount;
		depositRounds[vault][round].totalAssets -= amount;

		address assetToken = IRfyVault(vault).asset();
		IERC20(assetToken).safeTransfer(msg.sender, amount);

		emit DepositCancelled(vault, msg.sender, round, amount);
	}

	/*//////////////////////////////////////////////////////////////
                         USER — WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

	/// @inheritdoc IRfyVaultManager
	function queueWithdrawal(
		address vault,
		uint256 shares
	) external nonReentrant onlyRegisteredVault(vault) {
		if (shares == 0) revert VM_InvalidAmount();

		uint256 round = currentWithdrawalRound[vault];

		// consume parked internal balance first; pull only the shortfall from the wallet
		uint256 internalBal = internalShareBalance[vault][msg.sender];
		uint256 fromInternal = internalBal < shares ? internalBal : shares;
		if (fromInternal != 0) {
			internalShareBalance[vault][msg.sender] = internalBal - fromInternal;
			emit InternalSharesConsumed(vault, msg.sender, fromInternal);
		}
		uint256 shortfall = shares - fromInternal;
		if (shortfall != 0) {
			IERC20(vault).safeTransferFrom(msg.sender, address(this), shortfall);
		}

		withdrawalRounds[vault][round].totalShares += shares;
		userWithdrawalShares[vault][msg.sender][round] += shares;

		if (round > _userHighestWithdrawalRound[vault][msg.sender]) {
			_userHighestWithdrawalRound[vault][msg.sender] = round;
		}

		emit WithdrawalQueued(vault, msg.sender, round, shares);
	}

	/// @inheritdoc IRfyVaultManager
	function cancelWithdrawal(
		address vault,
		uint256 round,
		uint256 amount
	) external nonReentrant onlyRegisteredVault(vault) {
		if (amount == 0) revert VM_InvalidAmount();
		if (withdrawalRounds[vault][round].processed) revert VM_RoundAlreadyProcessed();

		uint256 userQueued = userWithdrawalShares[vault][msg.sender][round];
		if (amount > userQueued) revert VM_InsufficientBalance();

		userWithdrawalShares[vault][msg.sender][round] -= amount;
		withdrawalRounds[vault][round].totalShares -= amount;

		IERC20(vault).safeTransfer(msg.sender, amount);

		emit WithdrawalCancelled(vault, msg.sender, round, amount);
	}

	/*//////////////////////////////////////////////////////////////
                    DIRECT (UNPAUSED) DEPOSIT / WITHDRAW
    //////////////////////////////////////////////////////////////*/

	/// @inheritdoc IRfyVaultManager
	function depositToVault(
		address vault,
		uint256 amount
	) external nonReentrant onlyRegisteredVault(vault) {
		_directDeposit(vault, amount);
	}

	/// @inheritdoc IRfyVaultManager
	function deposit(
		address[] calldata vaults,
		uint256[] calldata amounts
	) external nonReentrant {
		uint256 len = vaults.length;
		if (len == 0) revert VM_EmptyInput();
		if (len != amounts.length) revert VM_LengthMismatch();
		for (uint256 i; i < len; ++i) {
			address v = vaults[i];
			if (!registeredVaults[v]) revert VM_VaultNotRegistered();
			_directDeposit(v, amounts[i]);
		}
	}

	/// @inheritdoc IRfyVaultManager
	function withdrawFromVault(
		address vault,
		uint256 shares
	) external nonReentrant onlyRegisteredVault(vault) {
		_directWithdraw(vault, shares);
	}

	/// @inheritdoc IRfyVaultManager
	function withdraw(
		address[] calldata vaults,
		uint256[] calldata shares
	) external nonReentrant {
		uint256 len = vaults.length;
		if (len == 0) revert VM_EmptyInput();
		if (len != shares.length) revert VM_LengthMismatch();
		for (uint256 i; i < len; ++i) {
			address v = vaults[i];
			if (!registeredVaults[v]) revert VM_VaultNotRegistered();
			_directWithdraw(v, shares[i]);
		}
	}

	/// @inheritdoc IRfyVaultManager
	function withdrawInternalAssets(address asset, uint256 amount) external nonReentrant {
		if (asset == address(0)) revert VM_InvalidAddress();
		if (amount == 0) revert VM_InvalidAmount();
		uint256 bal = internalAssetBalance[asset][msg.sender];
		if (amount > bal) revert VM_InsufficientInternalAssetBalance();

		internalAssetBalance[asset][msg.sender] = bal - amount;
		IERC20(asset).safeTransfer(msg.sender, amount);

		emit InternalAssetsWithdrawn(asset, msg.sender, amount);
	}

	/// @dev Pulls `amount` of underlying from the caller, deposits into `vault`,
	///      and credits the received shares to the caller's internal share balance.
	function _directDeposit(address vault, uint256 amount) internal {
		if (amount == 0) revert VM_InvalidAmount();
		IRfyVault rfyVault = IRfyVault(vault);
		if (rfyVault.depositsPaused()) revert VM_DepositsArePaused();

		address assetToken = rfyVault.asset();

		// consume parked internal asset balance first; pull only the shortfall from the wallet
		uint256 internalBal = internalAssetBalance[assetToken][msg.sender];
		uint256 fromInternal = internalBal < amount ? internalBal : amount;
		if (fromInternal != 0) {
			internalAssetBalance[assetToken][msg.sender] = internalBal - fromInternal;
			emit InternalAssetsConsumed(assetToken, msg.sender, fromInternal);
		}
		uint256 shortfall = amount - fromInternal;
		if (shortfall != 0) {
			IERC20(assetToken).safeTransferFrom(msg.sender, address(this), shortfall);
		}

		IERC20(assetToken).forceApprove(vault, amount);
		uint256 sharesReceived = rfyVault.deposit(amount, address(this));
		IERC20(assetToken).forceApprove(vault, 0);

		internalShareBalance[vault][msg.sender] += sharesReceived;
		emit VaultDeposited(vault, msg.sender, amount, sharesReceived);
	}

	/// @dev Sources `shares` from the caller's internal balance first, then their wallet,
	///      redeems from `vault`, and credits received assets to the caller's internal asset balance.
	function _directWithdraw(address vault, uint256 shares) internal {
		if (shares == 0) revert VM_InvalidAmount();
		IRfyVault rfyVault = IRfyVault(vault);
		if (rfyVault.withdrawalsPaused()) revert VM_WithdrawalsArePaused();

		uint256 internalBal = internalShareBalance[vault][msg.sender];
		uint256 fromInternal = internalBal < shares ? internalBal : shares;
		if (fromInternal != 0) {
			internalShareBalance[vault][msg.sender] = internalBal - fromInternal;
			emit InternalSharesConsumed(vault, msg.sender, fromInternal);
		}
		uint256 shortfall = shares - fromInternal;
		if (shortfall != 0) {
			IERC20(vault).safeTransferFrom(msg.sender, address(this), shortfall);
		}

		uint256 assetsReceived = rfyVault.redeem(shares, address(this), address(this));
		internalAssetBalance[rfyVault.asset()][msg.sender] += assetsReceived;
		emit VaultWithdrawn(vault, msg.sender, shares, assetsReceived);
	}

	/*//////////////////////////////////////////////////////////////
                       TRUSTLESS BATCH PROCESSING
    //////////////////////////////////////////////////////////////*/

	/// @inheritdoc IRfyVaultManager
	function processDeposits(address vault) external nonReentrant onlyRegisteredVault(vault) {
		IRfyVault rfyVault = IRfyVault(vault);
		if (rfyVault.depositsPaused()) revert VM_DepositsArePaused();
		if (depositRounds[vault][currentDepositRound[vault]].totalAssets == 0) revert VM_NothingToProcess();
		_processDeposits(vault);
	}

	/// @inheritdoc IRfyVaultManager
	function processWithdrawals(address vault) external nonReentrant onlyRegisteredVault(vault) {
		IRfyVault rfyVault = IRfyVault(vault);
		if (rfyVault.withdrawalsPaused()) revert VM_WithdrawalsArePaused();
		if (withdrawalRounds[vault][currentWithdrawalRound[vault]].totalShares == 0) revert VM_NothingToProcess();
		_processWithdrawals(vault);
	}

	/// @inheritdoc IRfyVaultManager
	function processAllDeposits() external nonReentrant returns (uint256 processed) {
		uint256 len = allVaults.length;
		for (uint256 i = 0; i < len; i++) {
			address vault = allVaults[i];
			if (IRfyVault(vault).depositsPaused()) continue;
			if (depositRounds[vault][currentDepositRound[vault]].totalAssets == 0) continue;
			_processDeposits(vault);
			unchecked { ++processed; }
		}
	}

	/// @inheritdoc IRfyVaultManager
	function processAllWithdrawals() external nonReentrant returns (uint256 processed) {
		uint256 len = allVaults.length;
		for (uint256 i = 0; i < len; i++) {
			address vault = allVaults[i];
			if (IRfyVault(vault).withdrawalsPaused()) continue;
			if (withdrawalRounds[vault][currentWithdrawalRound[vault]].totalShares == 0) continue;
			_processWithdrawals(vault);
			unchecked { ++processed; }
		}
	}

	/// @dev Core deposit-batch logic. Caller is responsible for `nonReentrant`,
	///      registration, paused, and non-empty-queue checks.
	function _processDeposits(address vault) internal {
		IRfyVault rfyVault = IRfyVault(vault);

		uint256 round = currentDepositRound[vault];
		DepositRound storage dr = depositRounds[vault][round];
		uint256 totalAssets_ = dr.totalAssets;

		// advance round before any external call so new queues open immediately
		currentDepositRound[vault] = round + 1;

		address assetToken = rfyVault.asset();

		// cap by current vault headroom so a partially-full cap (or a front-running
		// direct deposit) cannot freeze the entire round; unfilled portion becomes refund
		uint256 headroom = rfyVault.maxDeposit(address(this));
		uint256 assetsToDeposit = headroom < totalAssets_ ? headroom : totalAssets_;

		uint256 sharesReceived;
		if (assetsToDeposit != 0) {
			IERC20(assetToken).forceApprove(vault, assetsToDeposit);
			sharesReceived = rfyVault.deposit(assetsToDeposit, address(this));
			IERC20(assetToken).forceApprove(vault, 0);
		}

		dr.totalShares = sharesReceived;
		dr.refundAssets = totalAssets_ - assetsToDeposit;
		dr.processed = true;

		emit DepositsProcessed(vault, round, totalAssets_, sharesReceived);
	}

	/// @dev Core withdrawal-batch logic. Caller is responsible for `nonReentrant`,
	///      registration, paused, and non-empty-queue checks.
	function _processWithdrawals(address vault) internal {
		IRfyVault rfyVault = IRfyVault(vault);

		uint256 round = currentWithdrawalRound[vault];
		WithdrawalRound storage wr = withdrawalRounds[vault][round];
		uint256 totalShares_ = wr.totalShares;

		currentWithdrawalRound[vault] = round + 1;

		uint256 assetsReceived = rfyVault.redeem(totalShares_, address(this), address(this));

		wr.totalAssets = assetsReceived;
		wr.processed = true;

		emit WithdrawalsProcessed(vault, round, totalShares_, assetsReceived);
	}

	/*//////////////////////////////////////////////////////////////
                            CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

	/// @inheritdoc IRfyVaultManager
	function claimShares(address vault, uint256 round) external nonReentrant onlyRegisteredVault(vault) {
		DepositRound storage dr = depositRounds[vault][round];
		if (!dr.processed) revert VM_RoundNotProcessed();

		uint256 userAssets = userDepositAmounts[vault][msg.sender][round];
		if (userAssets == 0) revert VM_NothingToClaim();

		userDepositAmounts[vault][msg.sender][round] = 0;

		uint256 userShares = (userAssets * dr.totalShares) / dr.totalAssets;
		uint256 userRefund = (userAssets * dr.refundAssets) / dr.totalAssets;

		if (userShares != 0) {
			IERC20(vault).safeTransfer(msg.sender, userShares);
		}
		if (userRefund != 0) {
			IERC20(IRfyVault(vault).asset()).safeTransfer(msg.sender, userRefund);
		}

		emit SharesClaimed(vault, msg.sender, round, userShares);
	}

	/// @inheritdoc IRfyVaultManager
	function claimSharesInternal(
		address vault,
		uint256 round
	) external nonReentrant onlyRegisteredVault(vault) {
		DepositRound storage dr = depositRounds[vault][round];
		if (!dr.processed) revert VM_RoundNotProcessed();

		uint256 userAssets = userDepositAmounts[vault][msg.sender][round];
		if (userAssets == 0) revert VM_NothingToClaim();

		userDepositAmounts[vault][msg.sender][round] = 0;

		uint256 userShares = (userAssets * dr.totalShares) / dr.totalAssets;
		uint256 userRefund = (userAssets * dr.refundAssets) / dr.totalAssets;

		if (userShares != 0) {
			internalShareBalance[vault][msg.sender] += userShares;
		}
		// refund (cap-grief surplus) is always sent to the wallet — no internal-asset path
		if (userRefund != 0) {
			IERC20(IRfyVault(vault).asset()).safeTransfer(msg.sender, userRefund);
		}

		emit SharesClaimedInternal(vault, msg.sender, round, userShares);
	}

	/// @inheritdoc IRfyVaultManager
	function withdrawInternalShares(
		address vault,
		uint256 amount
	) external nonReentrant onlyRegisteredVault(vault) {
		if (amount == 0) revert VM_InvalidAmount();
		uint256 bal = internalShareBalance[vault][msg.sender];
		if (amount > bal) revert VM_InsufficientInternalBalance();

		internalShareBalance[vault][msg.sender] = bal - amount;
		IERC20(vault).safeTransfer(msg.sender, amount);

		emit InternalSharesWithdrawn(vault, msg.sender, amount);
	}

	/// @inheritdoc IRfyVaultManager
	function claimAssets(address vault, uint256 round) external nonReentrant onlyRegisteredVault(vault) {
		WithdrawalRound storage wr = withdrawalRounds[vault][round];
		if (!wr.processed) revert VM_RoundNotProcessed();

		uint256 userShares = userWithdrawalShares[vault][msg.sender][round];
		if (userShares == 0) revert VM_NothingToClaim();

		userWithdrawalShares[vault][msg.sender][round] = 0;

		uint256 userAssets = (userShares * wr.totalAssets) / wr.totalShares;

		address assetToken = IRfyVault(vault).asset();
		IERC20(assetToken).safeTransfer(msg.sender, userAssets);

		emit AssetsClaimed(vault, msg.sender, round, userAssets);
	}

	/*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

	/// @inheritdoc IRfyVaultManager
	function getClaimableShares(address vault, address user, uint256 round) external view returns (uint256) {
		DepositRound storage dr = depositRounds[vault][round];
		if (!dr.processed || dr.totalAssets == 0) return 0;

		uint256 userAssets = userDepositAmounts[vault][user][round];
		if (userAssets == 0) return 0;

		return (userAssets * dr.totalShares) / dr.totalAssets;
	}

	/// @inheritdoc IRfyVaultManager
	function getClaimableAssets(address vault, address user, uint256 round) external view returns (uint256) {
		WithdrawalRound storage wr = withdrawalRounds[vault][round];
		if (!wr.processed || wr.totalShares == 0) return 0;

		uint256 userShares = userWithdrawalShares[vault][user][round];
		if (userShares == 0) return 0;

		return (userShares * wr.totalAssets) / wr.totalShares;
	}

	/// @inheritdoc IRfyVaultManager
	function getUnclaimedDepositRounds(
		address vault,
		address user
	) external view returns (uint256[] memory rounds, uint256[] memory claimableShares) {
		uint256 highestRound = _userHighestDepositRound[vault][user];
		uint256 currentRound = currentDepositRound[vault];

		// open round is unprocessed — exclude it from the upper bound
		uint256 upperBound = highestRound < currentRound ? highestRound + 1 : currentRound;

		uint256 count;
		for (uint256 i = 0; i < upperBound; i++) {
			DepositRound storage dr = depositRounds[vault][i];
			if (dr.processed && userDepositAmounts[vault][user][i] > 0) {
				count++;
			}
		}

		rounds = new uint256[](count);
		claimableShares = new uint256[](count);

		uint256 idx;
		for (uint256 i = 0; i < upperBound; i++) {
			DepositRound storage dr = depositRounds[vault][i];
			uint256 userAssets = userDepositAmounts[vault][user][i];
			if (dr.processed && userAssets > 0) {
				rounds[idx] = i;
				claimableShares[idx] = (userAssets * dr.totalShares) / dr.totalAssets;
				idx++;
			}
		}
	}

	/// @inheritdoc IRfyVaultManager
	function getUnclaimedWithdrawalRounds(
		address vault,
		address user
	) external view returns (uint256[] memory rounds, uint256[] memory claimableAssets) {
		uint256 highestRound = _userHighestWithdrawalRound[vault][user];
		uint256 currentRound = currentWithdrawalRound[vault];

		uint256 upperBound = highestRound < currentRound ? highestRound + 1 : currentRound;

		uint256 count;
		for (uint256 i = 0; i < upperBound; i++) {
			WithdrawalRound storage wr = withdrawalRounds[vault][i];
			if (wr.processed && userWithdrawalShares[vault][user][i] > 0) {
				count++;
			}
		}

		rounds = new uint256[](count);
		claimableAssets = new uint256[](count);

		uint256 idx;
		for (uint256 i = 0; i < upperBound; i++) {
			WithdrawalRound storage wr = withdrawalRounds[vault][i];
			uint256 userShares = userWithdrawalShares[vault][user][i];
			if (wr.processed && userShares > 0) {
				rounds[idx] = i;
				claimableAssets[idx] = (userShares * wr.totalAssets) / wr.totalShares;
				idx++;
			}
		}
	}

	/// @inheritdoc IRfyVaultManager
	function getPendingDeposit(
		address vault,
		address user
	) external view returns (uint256 assets, uint256 round) {
		round = currentDepositRound[vault];
		assets = userDepositAmounts[vault][user][round];
	}

	/// @inheritdoc IRfyVaultManager
	function getPendingWithdrawal(
		address vault,
		address user
	) external view returns (uint256 shares, uint256 round) {
		round = currentWithdrawalRound[vault];
		shares = userWithdrawalShares[vault][user][round];
	}
}
