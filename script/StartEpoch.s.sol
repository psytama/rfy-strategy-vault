// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title StartEpoch
 * @dev Script to start a new epoch for an existing RfyVault
 * 
 * Usage:
 *   forge script script/StartEpoch.s.sol:StartEpoch --rpc-url <RPC_URL> --broadcast
 * 
 * Environment Variables:
 *   PRIVATE_KEY - Private key for the admin/bootstrapper account
 *   VAULT_ADDRESS - Address of the vault to start epoch for
 *   MINIMUM_DEPOSITS - Minimum deposit amount required (optional, defaults to 0)
 */
contract StartEpoch is Script {
    // Default values
    uint256 public constant DEFAULT_MINIMUM_DEPOSITS = 1000000; // No minimum by default
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        
        // Get minimum deposits from env or use default
        uint256 minimumDeposits;
        try vm.envUint("MINIMUM_DEPOSITS") returns (uint256 minDeposits) {
            minimumDeposits = minDeposits;
        } catch {
            minimumDeposits = DEFAULT_MINIMUM_DEPOSITS;
        }
        
        IRfyVault vault = IRfyVault(vaultAddress);
        
        // Pre-flight checks
        _performPreflightChecks(vault, minimumDeposits);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Start the epoch
        vault.startNewEpoch(minimumDeposits);
        
        vm.stopBroadcast();
        
        // Post-epoch summary
        _logEpochSummary(vault);
    }
    
    function _performPreflightChecks(IRfyVault vault, uint256 minimumDeposits) internal view {
        console.log("=== Pre-flight Checks ===");
        
        // Check vault exists and is valid
        console.log("Vault Address:", address(vault));
        console.log("Vault Name:", vault.name());
        console.log("Vault Symbol:", vault.symbol());
        
        // Check current state
        uint256 currentEpoch = vault.currentEpoch();
        console.log("Current Epoch:", currentEpoch);
        
        // Check if previous epoch is active
        if (currentEpoch > 0) {
            IRfyVault.EpochData memory lastEpoch = vault.getEpochData(currentEpoch);
            if (lastEpoch.isEpochActive) {
                console.log("WARNING: Previous epoch is still active!");
                console.log("- Epoch ID:", currentEpoch);
                console.log("- Start Time:", lastEpoch.startTime);
                console.log("- Is Settled:", lastEpoch.isSettled);
                revert("Cannot start new epoch: previous epoch still active");
            } else {
                console.log("Previous epoch settled successfully");
            }
        }
        
        // Check vault assets
        uint256 totalAssets = vault.totalAssets();
        console.log("Total Assets:", totalAssets);
        console.log("Minimum Required:", minimumDeposits);
        
        if (totalAssets == 0) {
            revert("Cannot start epoch: vault has no assets");
        }
        
        if (minimumDeposits > 0 && totalAssets < minimumDeposits) {
            console.log("ERROR: Insufficient assets for minimum requirement");
            revert("Insufficient assets for minimum deposits requirement");
        }
        
        // Check pause status
        bool depositsPaused = vault.depositsPaused();
        bool withdrawalsPaused = vault.withdrawalsPaused();
        console.log("Deposits Paused:", depositsPaused);
        console.log("Withdrawals Paused:", withdrawalsPaused);
        
        // Check asset details
        address asset = vault.asset();
        console.log("Asset Address:", asset);
        
        // Try to get metadata if available
        try IERC20Metadata(asset).name() returns (string memory name) {
            console.log("Asset Name:", name);
        } catch {
            console.log("Asset Name: [Not available]");
        }
        
        try IERC20Metadata(asset).symbol() returns (string memory symbol) {
            console.log("Asset Symbol:", symbol);
        } catch {
            console.log("Asset Symbol: [Not available]");
        }
        
        console.log("All pre-flight checks passed");
        console.log("");
    }
    
    function _logEpochSummary(IRfyVault vault) internal view {
        console.log("\n================================================================");
        console.log("                    EPOCH STARTED SUCCESSFULLY");
        console.log("================================================================");
        
        uint256 currentEpoch = vault.currentEpoch();
        IRfyVault.EpochData memory epochData = vault.getEpochData(currentEpoch);
        
        console.log("\n=== EPOCH INFORMATION ===");
        console.log("Epoch ID:", currentEpoch);
        console.log("Start Time:", epochData.startTime);
        console.log("Is Active:", epochData.isEpochActive);
        console.log("Duration (seconds):", vault.epochDuration());
        console.log("Duration (days):", vault.epochDuration() / 86400);
        
        console.log("\n=== VAULT ASSETS ===");
        console.log("Initial Vault Assets:", epochData.initialVaultAssets);
        console.log("Initial External Vault Deposits:", epochData.initialExternalVaultDeposits);
        console.log("Initial Unutilized Assets:", epochData.initialUnutilizedAsset);
        
        console.log("\n=== CURRENT STATE ===");
        console.log("Current External Vault Deposits:", epochData.currentExternalVaultDeposits);
        console.log("Current Unutilized Assets:", epochData.currentUnutilizedAsset);
        console.log("Funds Borrowed:", epochData.fundsBorrowed);
        console.log("Max Borrow Available:", vault.maxBorrow());
        
        console.log("\n=== VAULT STATUS ===");
        console.log("Deposits Paused:", vault.depositsPaused());
        console.log("Withdrawals Paused:", vault.withdrawalsPaused());
        console.log("Total Assets:", vault.totalAssets());
        console.log("Total Supply:", vault.totalSupply());
        
        // External vault info if available
        address externalVault = address(vault.externalVault());
        if (externalVault != address(0)) {
            console.log("\n=== EXTERNAL VAULT ===");
            console.log("External Vault Address:", externalVault);
            console.log("External Vault Balance:", IERC20(externalVault).balanceOf(address(vault)));
        }
        
        console.log("\n================================================================");
        console.log("Epoch", currentEpoch, "is now active and ready for trading!");
        console.log("================================================================");
    }
}
