// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { RfyVault } from "../src/RfyVault.sol";
import { RfyVaultFactory } from "../src/RfyVaultFactory.sol";
import { CustomUniswapV2Factory } from "../src/dex/CustomUniswapV2Factory.sol";
import { CustomUniswapV2Router } from "../src/dex/CustomUniswapV2Router.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";

/**
 * @title DeployVaultAndDex
 * @dev Comprehensive deployment script that:
 *      1. Deploys mock tokens (USDC, WETH, external vault token)
 *      2. Deploys DEX components (Factory, Router)
 *      3. Deploys Vault components (Implementation, Factory, Vault instance)
 *      4. Sets up initial liquidity and deposits into vault
 *      5. Creates a DEX pool between vault shares and asset tokens
 *      6. Logs all addresses and deployment summary
 * 
 * Usage:
 *   forge script script/DeployVaultAndDex.s.sol:DeployVaultAndDex --private-key <key> [--broadcast]
 * 
 * Environment Variables (optional):
 *   PRIVATE_KEY - Private key for deployment (default: anvil key)
 *   INITIAL_DEPOSIT - Initial deposit amount (default: 10,000 USDC)
 */

contract DeployVaultAndDex is Script {
    // Deployed contracts
    RfyVault public vaultImplementation;
    RfyVaultFactory public vaultFactory;
    IRfyVault public vault;
    CustomUniswapV2Factory public dexFactory;
    CustomUniswapV2Router public dexRouter;
    MockERC20 public asset;
    MockERC20 public weth;
    
    // Constants
    uint256 public constant INITIAL_DEPOSIT = 10_000e6; // 10,000 USDC
    uint256 public constant POOL_LIQUIDITY_ASSET = 5_000e6; // 5,000 USDC for pool
    uint256 public constant POOL_LIQUIDITY_WETH = 2e18; // 2 ETH worth for pool
    uint256 public constant EPOCH_DURATION = 3 days;
    uint256 public constant MAX_TOTAL_DEPOSITS = 1_000_000e6; // 1M USDC
    
    // Addresses
    address public deployer;
    address public admin;
    address public trader;
    address public liquidityProvider;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        admin = deployer;
        trader = deployer;
        liquidityProvider = deployer;

        weth = MockERC20(vm.envAddress("WETH_ADDRESS"));
        
        vm.startBroadcast(deployerPrivateKey);
        
        _deployDex();
        
        vm.stopBroadcast();
    }
    
    function _deployTokens() internal {
        console.log("=== Deploying Tokens ===");
        
        asset = new MockERC20("USD Coin", "USDC", 6);
        console.log("Asset (USDC) deployed at:", address(asset));
        
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        console.log("WETH deployed at:", address(weth));
    }
    
    function _deployDex() internal {
        console.log("\n=== Deploying DEX ===");
        
        // Deploy DEX factory
        dexFactory = new CustomUniswapV2Factory(deployer);
        console.log("DEX Factory deployed at:", address(dexFactory));
        
        // Deploy DEX router
        dexRouter = new CustomUniswapV2Router(address(dexFactory), address(weth));
        console.log("DEX Router deployed at:", address(dexRouter));
    }
    
    function _deployVault() internal {
        console.log("\n=== Deploying Vault ===");
        
        // Deploy vault implementation
        vaultImplementation = new RfyVault();
        console.log("Vault Implementation deployed at:", address(vaultImplementation));
        
        // Deploy vault factory
        vaultFactory = new RfyVaultFactory(address(vaultImplementation));
        console.log("Vault Factory deployed at:", address(vaultFactory));
        
        // Create a new vault instance
        vault = IRfyVault(vaultFactory.createVault(
            "RFY Strategy Vault",           // tokenName
            "RFY",                          // tokenSymbol  
            "PEPE",                         // memeName
            address(asset),                 // asset
            admin,                          // owner/admin
            trader,                         // trader
            vm.envAddress("EXTERNAL_VAULT"),    // external vault
            EPOCH_DURATION,                 // epochDuration
            MAX_TOTAL_DEPOSITS              // maxTotalDeposits
        ));
        console.log("Vault deployed at:", address(vault));
    }
    
    function _setupLiquidity() internal {
        console.log("\n=== Setting up Initial Liquidity ===");
        asset.mint(deployer, INITIAL_DEPOSIT * 2);
        asset.mint(liquidityProvider, POOL_LIQUIDITY_ASSET);
        weth.mint(liquidityProvider, POOL_LIQUIDITY_WETH);
    }
    
    function _depositIntoVault() internal {
        console.log("\n=== Depositing into Vault ===");
        asset.approve(address(vault), INITIAL_DEPOSIT);
        uint256 sharesReceived = vault.deposit(INITIAL_DEPOSIT, deployer);
        uint256 sharesAfter = vault.balanceOf(deployer);
        
        console.log("Deposited", INITIAL_DEPOSIT, "USDC into vault");
        console.log("Received", sharesReceived, "vault shares");
        console.log("Total vault shares:", sharesAfter);
        console.log("Vault total assets:", vault.totalAssets());
    }
    
    function _createDexPool() internal {
        address pairAddress = dexFactory.createPair(address(vault), address(asset));
        console.log("Created pair at:", pairAddress);
        
        vault.approve(address(dexRouter), vault.balanceOf(deployer));
        asset.approve(address(dexRouter), asset.balanceOf(deployer));
        
        uint256 vaultSharesForPool = vault.balanceOf(deployer) / 2;
        uint256 assetForPool = asset.balanceOf(deployer);
        
        (uint256 amountA, uint256 amountB, uint256 liquidity) = dexRouter.addLiquidity(
            address(vault),
            address(asset),
            vaultSharesForPool,
            assetForPool,
            0,
            0,
            deployer,
            block.timestamp + 1 hours
        );
        
        console.log("Liquidity added:");
        console.log("- Amount A (vault shares):", amountA);
        console.log("- Amount B (asset):", amountB);
        console.log("- LP tokens received:", liquidity);
        console.log("- Pair address:", pairAddress);
    }
}
