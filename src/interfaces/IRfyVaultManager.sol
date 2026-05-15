// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IRfyVaultManager {
	/*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

	/// @notice Tracks a batch of queued deposits for one vault within one round.
	/// @dev Once processed, totalShares is set from the actual vault.deposit() return value.
	///      If the vault's `maxDeposit` headroom was smaller than `totalAssets` at process
	///      time, the unfilled portion is recorded in `refundAssets` and returned to users
	///      pro-rata when they call `claimShares`.
	struct DepositRound {
		uint256 totalAssets; // sum of all assets queued in this round
		uint256 totalShares; // vault shares received when the round was processed
		uint256 refundAssets; // queued assets that did not fit under the vault cap
		bool processed;
	}

	/// @notice Tracks a batch of queued withdrawal requests for one vault within one round.
	/// @dev Once processed, totalAssets is set from the actual vault.redeem() return value.
	struct WithdrawalRound {
		uint256 totalShares; // sum of all vault shares queued in this round
		uint256 totalAssets; // underlying assets received when the round was processed
		bool processed;
	}

	/*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

	error VM_VaultNotRegistered();
	error VM_VaultAlreadyRegistered();
	error VM_InvalidAddress();
	error VM_InvalidAmount();
	error VM_RoundAlreadyProcessed();
	error VM_RoundNotProcessed();
	error VM_NothingToProcess();
	error VM_DepositsArePaused();
	error VM_WithdrawalsArePaused();
	error VM_NothingToClaim();
	error VM_InsufficientBalance();
	error VM_InsufficientInternalBalance();
	error VM_InsufficientInternalAssetBalance();
	error VM_LengthMismatch();
	error VM_EmptyInput();

	/*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

	event VaultRegistered(address indexed vault);
	event DepositQueued(address indexed vault, address indexed user, uint256 indexed round, uint256 assets);
	event DepositCancelled(address indexed vault, address indexed user, uint256 indexed round, uint256 assets);
	event WithdrawalQueued(address indexed vault, address indexed user, uint256 indexed round, uint256 shares);
	event WithdrawalCancelled(address indexed vault, address indexed user, uint256 indexed round, uint256 shares);
	event DepositsProcessed(address indexed vault, uint256 indexed round, uint256 totalAssets, uint256 totalShares);
	event WithdrawalsProcessed(
		address indexed vault,
		uint256 indexed round,
		uint256 totalShares,
		uint256 totalAssets
	);
	event SharesClaimed(address indexed vault, address indexed user, uint256 indexed round, uint256 shares);
	event AssetsClaimed(address indexed vault, address indexed user, uint256 indexed round, uint256 assets);
	event SharesClaimedInternal(address indexed vault, address indexed user, uint256 indexed round, uint256 shares);
	event InternalSharesWithdrawn(address indexed vault, address indexed user, uint256 amount);
	event InternalSharesConsumed(address indexed vault, address indexed user, uint256 amount);

	event VaultDeposited(address indexed vault, address indexed user, uint256 assets, uint256 shares);
	event VaultWithdrawn(address indexed vault, address indexed user, uint256 shares, uint256 assets);
	event InternalAssetsWithdrawn(address indexed asset, address indexed user, uint256 amount);
	event InternalAssetsConsumed(address indexed asset, address indexed user, uint256 amount);
	event EmergencyWithdrawn(address indexed token, address indexed to, uint256 amount);

	/*//////////////////////////////////////////////////////////////
                              OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

	/// @notice Whitelist a vault so users can queue deposits/withdrawals against it.
	/// @dev Only callable by the contract owner. Also pushed to the public `allVaults` array.
	function registerVault(address vault) external;

	/// @notice Emergency rescue. Transfers `amount` of `token` from this contract to `to`.
	/// @dev Only callable by the contract owner. Bypasses all internal accounting.
	function emergencyWithdraw(address token, address to, uint256 amount) external;

	/// @notice Returns the address of the vault registered at index `i` in the public registry.
	function allVaults(uint256 i) external view returns (address);

	/// @notice Returns the total number of registered vaults.
	function vaultsLength() external view returns (uint256);

	/*//////////////////////////////////////////////////////////////
                              USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

	/// @notice Queue underlying asset tokens for deposit into `vault`.
	///         Tokens are pulled from msg.sender immediately and held in this contract.
	///         Can be called while the vault's deposits are paused (during an active epoch).
	/// @param vault  The RfyVault to deposit into
	/// @param assets Amount of underlying asset tokens to queue
	function queueDeposit(address vault, uint256 assets) external;

	/// @notice Cancel a partial or full queued deposit from an unprocessed round.
	/// @param vault  The RfyVault the deposit was queued against
	/// @param round  The deposit round ID (must be the current open round)
	/// @param amount Amount to cancel; must be <= user's queued amount for this round
	function cancelDeposit(address vault, uint256 round, uint256 amount) external;

	/// @notice Queue vault shares for batch withdrawal from `vault`.
	///         Vault shares (the rfyXXX ERC20) are pulled from msg.sender immediately.
	/// @param vault  The RfyVault to redeem shares from
	/// @param shares Amount of vault shares to queue for withdrawal
	function queueWithdrawal(address vault, uint256 shares) external;

	/// @notice Cancel a partial or full queued withdrawal from an unprocessed round.
	/// @param vault  The RfyVault the withdrawal was queued against
	/// @param round  The withdrawal round ID
	/// @param amount Amount of shares to cancel; must be <= user's queued shares for this round
	function cancelWithdrawal(address vault, uint256 round, uint256 amount) external;

	/*//////////////////////////////////////////////////////////////
                       DIRECT (UNPAUSED) FLOW
    //////////////////////////////////////////////////////////////*/

	/// @notice Deposit `amount` of underlying asset directly into `vault` and credit the
	///         received shares to the caller's internal share balance held in this contract.
	///         The vault must currently have deposits unpaused.
	function depositToVault(address vault, uint256 amount) external;

	/// @notice Multi-vault variant of {depositToVault}. Each (vault[i], amount[i]) is processed
	///         in sequence. Reverts if any vault is unregistered, paused, or the lengths mismatch.
	function deposit(address[] calldata vaults, uint256[] calldata amounts) external;

	/// @notice Redeem `shares` from `vault`. Shares are sourced from the caller's internal balance
	///         first, then pulled from their wallet for any shortfall. The received underlying assets
	///         are credited to the caller's internal asset balance (NOT transferred to wallet).
	///         The vault must currently have withdrawals unpaused.
	function withdrawFromVault(address vault, uint256 shares) external;

	/// @notice Multi-vault variant of {withdrawFromVault}.
	function withdraw(address[] calldata vaults, uint256[] calldata shares) external;

	/// @notice Withdraw underlying asset tokens previously credited via direct withdraw / claim flows.
	///         Internal-asset balance is keyed by asset token address (not vault).
	function withdrawInternalAssets(address asset, uint256 amount) external;

	/*//////////////////////////////////////////////////////////////
                         TRUSTLESS PROCESSING
    //////////////////////////////////////////////////////////////*/

	/// @notice Deposit all queued assets for the current round into the vault.
	///         Anyone can call this. Reverts if vault.depositsPaused() == true or nothing queued.
	///         Advances the deposit round counter immediately.
	/// @param vault The RfyVault to deposit into
	function processDeposits(address vault) external;

	/// @notice Redeem all queued vault shares for the current withdrawal round from the vault.
	///         Anyone can call this. Reverts if vault.withdrawalsPaused() == true or nothing queued.
	///         Advances the withdrawal round counter immediately.
	/// @param vault The RfyVault to redeem from
	function processWithdrawals(address vault) external;

	/// @notice Loop over every registered vault and run {processDeposits} on each one that has
	///         a non-empty current deposit round and is not paused. Vaults that are paused or
	///         have nothing queued are silently skipped (no revert), so one stuck vault cannot
	///         block the rest of the batch. Anyone can call this.
	/// @return processed Number of vaults that were actually processed.
	function processAllDeposits() external returns (uint256 processed);

	/// @notice Loop over every registered vault and run {processWithdrawals} on each one that has
	///         a non-empty current withdrawal round and is not paused. Vaults that are paused or
	///         have nothing queued are silently skipped (no revert). Anyone can call this.
	/// @return processed Number of vaults that were actually processed.
	function processAllWithdrawals() external returns (uint256 processed);

	/*//////////////////////////////////////////////////////////////
                              CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

	/// @notice Claim vault shares owed from a processed deposit round.
	///         Pro-rata formula: userShares = userAssets * round.totalShares / round.totalAssets
	/// @param vault The RfyVault the round belongs to
	/// @param round The deposit round ID
	function claimShares(address vault, uint256 round) external;

	/// @notice Same pro-rata claim as {claimShares}, but credits the user's internal share
	///         balance held inside this contract instead of transferring shares out.
	///         Useful for users who plan to queue a withdrawal next epoch — keeping shares
	///         here lets {queueWithdrawal} consume them without a fresh ERC20 transferFrom.
	///         The pro-rata asset refund (if the vault cap was exceeded) is still sent to
	///         the user's wallet because there is no internal-asset accounting path.
	/// @param vault The RfyVault the round belongs to
	/// @param round The deposit round ID
	function claimSharesInternal(address vault, uint256 round) external;

	/// @notice Withdraw vault shares previously credited via {claimSharesInternal} back to
	///         the user's wallet. Reverts if the user does not hold at least `amount`.
	/// @param vault  The RfyVault whose shares to withdraw
	/// @param amount Amount of shares to transfer to msg.sender
	function withdrawInternalShares(address vault, uint256 amount) external;

	/// @notice Claim underlying assets owed from a processed withdrawal round.
	///         Pro-rata formula: userAssets = userShares * round.totalAssets / round.totalShares
	/// @param vault The RfyVault the round belongs to
	/// @param round The withdrawal round ID
	function claimAssets(address vault, uint256 round) external;

	/*//////////////////////////////////////////////////////////////
                               VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

	/// @notice Preview how many vault shares msg.sender / user can claim from a processed deposit round.
	/// @return 0 if the round is not yet processed or user has nothing queued.
	function getClaimableShares(address vault, address user, uint256 round) external view returns (uint256);

	/// @notice Preview how many underlying assets msg.sender / user can claim from a processed withdrawal round.
	/// @return 0 if the round is not yet processed or user has nothing queued.
	function getClaimableAssets(address vault, address user, uint256 round) external view returns (uint256);

	/// @notice Returns all processed deposit rounds where a user has unclaimed vault shares.
	/// @return rounds          Array of round IDs with unclaimed shares
	/// @return claimableShares Corresponding claimable share amounts
	function getUnclaimedDepositRounds(
		address vault,
		address user
	) external view returns (uint256[] memory rounds, uint256[] memory claimableShares);

	/// @notice Returns all processed withdrawal rounds where a user has unclaimed assets.
	/// @return rounds          Array of round IDs with unclaimed assets
	/// @return claimableAssets Corresponding claimable asset amounts
	function getUnclaimedWithdrawalRounds(
		address vault,
		address user
	) external view returns (uint256[] memory rounds, uint256[] memory claimableAssets);

	/// @notice Returns the user's pending (unprocessed) queued deposit for the current open round.
	/// @return assets Amount of assets queued
	/// @return round  Current deposit round ID
	function getPendingDeposit(address vault, address user) external view returns (uint256 assets, uint256 round);

	/// @notice Returns the user's pending (unprocessed) queued withdrawal for the current open round.
	/// @return shares Amount of vault shares queued
	/// @return round  Current withdrawal round ID
	function getPendingWithdrawal(address vault, address user) external view returns (uint256 shares, uint256 round);
}
