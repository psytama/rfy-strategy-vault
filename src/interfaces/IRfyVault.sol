// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC4626 } from "openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/ERC4626Upgradeable.sol";

interface IRfyVault is IERC4626 {
	/*//////////////////////////////////////////////////////////////
                            STRUCTS
    //////////////////////////////////////////////////////////////*/

	struct EpochData {
		uint96 startTime; // Timestamp when epoch started
		uint96 endTime; // Timestamp when epoch should end
		bool isSettled; // Whether epoch has been settled
		bool isEpochActive; //Whether an epoch is currently active
		uint256 initialVaultAssets; // Total assets in the vault at the start of the epoch
		uint256 initialExternalVaultDeposits; // Amount of assets initially deposited into external vault
		uint256 initialUnutilizedAsset; // Amount of unutilized assets at the start of the epoch
		uint256 currentExternalVaultDeposits; // Current amount of assets deposited into external vault
		uint256 currentUnutilizedAsset; // Current amount of unutilized assets
		uint256 fundsBorrowed; // Amount currently borrowed by trader
		uint256 finalVaultAssets; // Total assets in the vault at the end of the epoch
		int256 externalVaultPnl; // Profit/loss from external vault investments after settlement
		int256 tradingPnl; // Trading profit/loss after settlement
	}

	/*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

	error SV_InvalidAddress();
	error SV_InvalidAmount();
	error SV_DepositsArePaused();
	error SV_WithdrawalsArePaused();
	error SV_EpochNotActive();
	error SV_EpochActive();
	error SV_InvalidDuration();
	error SV_EpochNotEnded();
	error SV_NoAvailableFunds();
	error SV_LossExceedsBorrowAmount();
	error SV_ExternalVaultSharesZero();

	/*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

	event EpochStarted(uint256 indexed epochId, uint256 timestamp);
	event EpochEnded(uint256 indexed epochId, uint256 timestamp);
	event FundsBorrowed(address indexed trader, uint256 amount);
	event FundsSettled(address indexed trader, uint256 amount, int256 pnl);
	event DepositsStatusUpdated(bool paused);
	event WithdrawalsStatusUpdated(bool paused);
	event DepositWithdrawalPaused();
	event DepositWithdrawalUnpaused();
	event EpochDurationUpdated(uint256 newDuration);

	/*//////////////////////////////////////////////////////////////
                            FUNCTIONS
    //////////////////////////////////////////////////////////////*/

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
	) external;

	function currentEpoch() external view returns (uint256);
	function epochDuration() external view returns (uint256);
	function depositsPaused() external view returns (bool);
	function withdrawalsPaused() external view returns (bool);
	function externalVault() external view returns (IERC4626);
	function maxBorrow() external view returns (uint256);
	function getEpochData(uint256 epochId) external view returns (EpochData memory);
	function memeName() external view returns (string memory);
	function maxTotalDeposits() external view returns (uint256);

	function startNewEpoch() external;
	function borrow(uint256 amount) external;
	function settle(int256 pnl) external;

	function setEpochDuration(uint256 newDuration) external;
	function setDepositsPaused(bool paused) external;
	function setWithdrawalsPaused(bool paused) external;
	function pauseAll() external;
	function unpauseAll() external;
}
