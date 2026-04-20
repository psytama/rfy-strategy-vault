// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
    uint256 public constant DEFAULT_MINIMUM_DEPOSITS = 0;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        uint256 minimumDeposits = DEFAULT_MINIMUM_DEPOSITS;
        
        IRfyVault pbtcVault = IRfyVault(vm.envAddress("PBTC_VAULT"));
        IRfyVault stbtcVault = IRfyVault(vm.envAddress("STBTC_VAULT"));
        IRfyVault usdcVault = IRfyVault(vm.envAddress("USDC_VAULT"));
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Start epoch for pBTC Vault
        console.log("Starting epoch for pBTC Vault...");
        pbtcVault.startNewEpoch(minimumDeposits);
        
        // Start epoch for stBTC Vault
        console.log("Starting epoch for stBTC Vault...");
        stbtcVault.startNewEpoch(minimumDeposits);
        
        // Start epoch for USDC Vault
        console.log("Starting epoch for USDC Vault...");
        usdcVault.startNewEpoch(minimumDeposits);
        
        vm.stopBroadcast();
        
        // Post-epoch summary
        _logEpochSummary(pbtcVault, "pBTC");
        _logEpochSummary(stbtcVault, "stBTC");
        _logEpochSummary(usdcVault, "USDC");
    }
    
    function _logEpochSummary(IRfyVault vault, string memory vaultName) internal view {
        console.log("\n================================================================");
        console.log("           ", vaultName, "VAULT - EPOCH STARTED SUCCESSFULLY");
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
