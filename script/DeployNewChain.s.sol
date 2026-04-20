// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { RfyVault } from "../src/RfyVault.sol";
import { RfyVaultFactory } from "../src/RfyVaultFactory.sol";

/**
 * @title DeployNewChain
 * @dev Deployment script for a new chain that:
 *      1. Deploys mock BTC token
 *      2. Deploys vault implementation (RfyVault)
 *      3. Deploys vault factory (RfyVaultFactory)
 * 
 * Usage:
 *   forge script script/DeployNewChain.s.sol:DeployNewChain --private-key <key> [--broadcast]
 * 
 * Environment Variables:
 *   PRIVATE_KEY - Private key for deployment
 */
contract DeployNewChain is Script {
    // Deployed contracts
    RfyVault public vaultImplementation;
    RfyVaultFactory public vaultFactory;
    
    // Addresses
    address public deployer;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Deploy vault implementation
        _deployVaultImplementation();
        
        // Step 2: Deploy vault factory
        _deployVaultFactory();
        
        vm.stopBroadcast();
        
        // Log deployment summary
        _logDeploymentSummary();
    }
    
    function _deployVaultImplementation() internal {
        console.log("\n=== Deploying Vault Implementation ===");
        
        // Deploy vault implementation
        vaultImplementation = new RfyVault();
        console.log("Vault Implementation deployed at:", address(vaultImplementation));
    }
    
    function _deployVaultFactory() internal {
        console.log("\n=== Deploying Vault Factory ===");
        
        // Deploy vault factory with the implementation address
        vaultFactory = new RfyVaultFactory(address(vaultImplementation));
        console.log("Vault Factory deployed at:", address(vaultFactory));
    }
    
    function _logDeploymentSummary() internal view {
        console.log("\n================================================================");
        console.log("                    DEPLOYMENT SUMMARY");
        console.log("================================================================");
        
        console.log("\n=== VAULT ADDRESSES ===");
        console.log("Vault Implementation:", address(vaultImplementation));
        console.log("Vault Factory:", address(vaultFactory));
        
        console.log("\n=== ROLE ADDRESSES ===");
        console.log("Deployer:", deployer);
        console.log("Factory Owner:", vaultFactory.owner());
        
        console.log("\n================================================================");
        console.log("Deployment completed successfully!");
        console.log("================================================================");
    }
}
