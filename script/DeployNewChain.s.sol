// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { RfyVault } from "../src/RfyVault.sol";
import { RfyVaultFactory } from "../src/RfyVaultFactory.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { MockERC4626Vault } from "../src/mocks/MockERC4626Vault.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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
    MockERC20 public mockBTC;
    MockERC4626Vault public mockExternalVault;
    
    // Addresses
    address public deployer;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Deploy mock BTC token
        // _deployMockBTC();
        
        // Step 2: Deploy mock external vault (ERC4626)
        // _deployMockExternalVault();
        
        // Step 3: Deploy vault implementation
        _deployVaultImplementation();
        
        // Step 4: Deploy vault factory
        _deployVaultFactory();
        
        vm.stopBroadcast();
        
        // Log deployment summary
        _logDeploymentSummary();
    }
    
    function _deployMockBTC() internal {
        console.log("=== Deploying Mock BTC ===");
        
        // Deploy mock BTC with 8 decimals (like real BTC)
        mockBTC = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        console.log("Mock BTC deployed at:", address(mockBTC));
    }
    
    function _deployMockExternalVault() internal {
        console.log("\n=== Deploying Mock External Vault ===");
        
        // Deploy mock ERC4626 vault using mock BTC as underlying asset
        mockExternalVault = new MockERC4626Vault(
            IERC20(address(mockBTC)),
            "Mock BTC Vault",
            "mBTCv"
        );
        console.log("Mock External Vault deployed at:", address(mockExternalVault));
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
        
        console.log("\n=== TOKEN ADDRESSES ===");
        console.log("Mock BTC (WBTC):", address(mockBTC));
        // console.log("Mock External Vault:", address(mockExternalVault));
        
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
