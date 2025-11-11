// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { RfyVault } from "../src/RfyVault.sol";
import { RfyVaultFactory } from "../src/RfyVaultFactory.sol";
import { CustomUniswapV2Factory } from "../src/dex/CustomUniswapV2Factory.sol";
import { CustomUniswapV2Router } from "../src/dex/CustomUniswapV2Router.sol";
import { MockERC20 } from "../test/mocks/MockERC20.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
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
    RfyVault public vaultImplementation = RfyVault(address(0x502751c59fEb16959526f1f8aa767D84b028bFbD)); // Pre-deployed address
    RfyVaultFactory public vaultFactory = RfyVaultFactory(address(0x8D64417C8702cE1F62f8a159277715b98d6c38BF));
    IRfyVault public vault = IRfyVault(address(0xA5aC2915522aE5A93e881bea5532B46621ECad69));
    CustomUniswapV2Factory public dexFactory = CustomUniswapV2Factory(address(0x849f74700b0714c6B87680f7af49B72677298d86));
    CustomUniswapV2Router public dexRouter = CustomUniswapV2Router(payable(address(0x27EC24393a1c6b26b39fB508E579d429EFfad49c)));
    MockERC20 public asset = MockERC20(0x20b2431557bB90954744a6D404f45aD1aD8719f4); // USDC-like token
    MockERC20 public weth = MockERC20(0x1Bfa26a0dc850B3a9B7586Cc6f8f868B5204a3F1); // WETH-like token
    MockERC20 public externalVaultToken; // Mock external vault
    
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
        
        // Create role addresses
        admin = deployer;
        trader = deployer;
        liquidityProvider = deployer;
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Deploy tokens
        // _deployTokens();
        
        // Step 2: Deploy DEX components
        _deployDex();
        
        // // Step 3: Deploy vault components
        // _deployVault();
        
        // Step 4: Setup initial liquidity and fund accounts
        // _setupLiquidity();
        
        // // Step 5: Deposit into vault and get shares
        // _depositIntoVault();
        
        // // Step 6: Create DEX pool with vault shares and asset
        // _createDexPool();
        
        vm.stopBroadcast();
        
        // Step 7: Log all addresses and summary
        // _logDeploymentSummary();
    }
    
    function _deployTokens() internal {
        console.log("=== Deploying Tokens ===");
        
        // Deploy USDC-like asset token
        asset = new MockERC20("USD Coin", "USDC", 6);
        console.log("Asset (USDC) deployed at:", address(asset));
        
        // Deploy WETH-like token
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        console.log("WETH deployed at:", address(weth));
        
        // // Deploy external vault token (ERC4626-like)
        // externalVaultToken = new MockERC20("External Vault Token", "EVT", 6);
        // console.log("External Vault Token deployed at:", address(externalVaultToken));
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
            address(externalVaultToken),    // external vault (mock)
            EPOCH_DURATION,                 // epochDuration
            MAX_TOTAL_DEPOSITS              // maxTotalDeposits
        ));
        console.log("Vault deployed at:", address(vault));
    }
    
    function _setupLiquidity() internal {
        console.log("\n=== Setting up Initial Liquidity ===");
        
        // Mint tokens to deployer and liquidity provider
        // asset.mint(deployer, INITIAL_DEPOSIT * 2);
        // asset.mint(liquidityProvider, POOL_LIQUIDITY_ASSET);
        // weth.mint(liquidityProvider, POOL_LIQUIDITY_WETH);
        
        console.log("Minted", INITIAL_DEPOSIT * 2, "USDC to deployer");
        console.log("Minted", POOL_LIQUIDITY_ASSET, "USDC to LP");
        console.log("Minted", POOL_LIQUIDITY_WETH, "WETH to LP");
    }
    
    function _depositIntoVault() internal {
        console.log("\n=== Depositing into Vault ===");
        // asset.mint(deployer, INITIAL_DEPOSIT * 2);
        // Approve and deposit into vault
        // asset.approve(address(vault), INITIAL_DEPOSIT);
        uint256 sharesReceived = vault.deposit(INITIAL_DEPOSIT, deployer);
        uint256 sharesAfter = vault.balanceOf(deployer);
        
        console.log("Deposited", INITIAL_DEPOSIT, "USDC into vault");
        console.log("Received", sharesReceived, "vault shares");
        console.log("Total vault shares:", sharesAfter);
        console.log("Vault total assets:", vault.totalAssets());
    }
    
    function _createDexPool() internal {
        // console.log("\n=== Creating DEX Pool ===");
        
        // // Create pool between vault shares and asset
        // address pairAddress = dexFactory.createPair(address(vault), address(asset));
        // console.log("Created pair at:", pairAddress);
        
        // // Approve tokens for router
        // vault.approve(address(dexRouter), vault.balanceOf(deployer));
        // asset.approve(address(dexRouter), asset.balanceOf(deployer));
        
        // Add liquidity to the pool
        uint256 vaultSharesForPool = vault.balanceOf(deployer) / 2; // Use half of shares
        uint256 assetForPool = asset.balanceOf(deployer); // Use remaining asset
        
        console.log("Adding liquidity:");
        console.log("- Vault shares:", vaultSharesForPool);
        console.log("- Asset amount:", assetForPool);
        
        (uint256 amountA, uint256 amountB, uint256 liquidity) = dexRouter.addLiquidity(
            address(vault),     // tokenA (vault shares)
            address(asset),     // tokenB (asset)
            vaultSharesForPool, // amountADesired
            assetForPool,       // amountBDesired
            0,                  // amountAMin
            0,                  // amountBMin
            deployer,           // to
            block.timestamp + 1 hours // deadline
        );
        
        console.log("Liquidity added successfully:");
        console.log("- Amount A (vault shares):", amountA);
        console.log("- Amount B (asset):", amountB);
        console.log("- LP tokens received:", liquidity);
        // console.log("- Pair address:", pairAddress);
    }
    
    // function _logDeploymentSummary() internal view {
    //     console.log("\n" "================================================================");
    //     console.log("                    DEPLOYMENT SUMMARY");
    //     console.log("================================================================");
        
    //     console.log("\n=== TOKEN ADDRESSES ===");
    //     console.log("Asset (USDC):", address(asset));
    //     console.log("WETH:", address(weth));
    //     // console.log("External Vault Token:", address(externalVaultToken));
        
    //     console.log("\n=== DEX ADDRESSES ===");
    //     console.log("DEX Factory:", address(dexFactory));
    //     console.log("DEX Router:", address(dexRouter));
    //     console.log("Vault-Asset Pair:", dexFactory.getPair(address(vault), address(asset)));
        
    //     console.log("\n=== VAULT ADDRESSES ===");
    //     console.log("Vault Implementation:", address(vaultImplementation));
    //     console.log("Vault Factory:", address(vaultFactory));
    //     console.log("Vault Instance:", address(vault));
        
    //     console.log("\n=== ROLE ADDRESSES ===");
    //     console.log("Deployer:", deployer);
    //     console.log("Admin:", admin);
    //     console.log("Trader:", trader);
    //     console.log("Liquidity Provider:", liquidityProvider);
        
    //     console.log("\n=== VAULT STATE ===");
    //     console.log("Vault Name:", vault.name());
    //     console.log("Vault Symbol:", vault.symbol());
    //     console.log("Total Assets:", vault.totalAssets());
    //     console.log("Total Supply:", vault.totalSupply());
    //     console.log("Deployer Shares:", vault.balanceOf(deployer));
    //     console.log("Max Total Deposits:", vault.maxTotalDeposits());
    //     console.log("Epoch Duration:", vault.epochDuration());
    //     console.log("Current Epoch:", vault.currentEpoch());
    //     console.log("Deposits Paused:", vault.depositsPaused());
    //     console.log("Withdrawals Paused:", vault.withdrawalsPaused());
        
    //     console.log("\n=== TOKEN BALANCES ===");
    //     console.log("Deployer Asset Balance:", asset.balanceOf(deployer));
    //     console.log("Deployer Vault Shares:", vault.balanceOf(deployer));
    //     console.log("Vault Asset Balance:", asset.balanceOf(address(vault)));
        
    //     console.log("\n=== DEX STATE ===");
    //     address pairAddress = dexFactory.getPair(address(vault), address(asset));
    //     if (pairAddress != address(0)) {
    //         console.log("Pair Total Supply:", IERC20(pairAddress).totalSupply());
    //         console.log("Deployer LP Tokens:", IERC20(pairAddress).balanceOf(deployer));
    //         console.log("Pair Vault Balance:", vault.balanceOf(pairAddress));
    //         console.log("Pair Asset Balance:", asset.balanceOf(pairAddress));
    //     }
        
    //     console.log("\n================================================================");
    //     console.log("Deployment completed successfully!");
    //     console.log("================================================================");
    // }
}
