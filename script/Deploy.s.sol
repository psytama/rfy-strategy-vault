// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IRfyVaultFactory } from "../src/interfaces/IRfyVaultFactory.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";
import { CustomUniswapV2Factory } from "../src/dex/CustomUniswapV2Factory.sol";
import { CustomUniswapV2Router } from "../src/dex/CustomUniswapV2Router.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployVaultWithExistingDex
 * @dev Deployment script that uses existing deployed factories to:
 *      1. Deploy a new vault using existing RfyVaultFactory
 *      2. Deposit initial funds into the vault
 *      3. Create a Uniswap pool using existing DEX factory/router
 *      4. Add liquidity to the pool
 * 
 * Usage:
 *   forge script script/DeployVaultWithExistingDex.s.sol:DeployVaultWithExistingDex --private-key <key> [--broadcast]
 * 
 * Environment Variables:
 *   RFY_VAULT_FACTORY - Address of deployed RfyVaultFactory
 *   DEX_FACTORY - Address of deployed CustomUniswapV2Factory
 *   DEX_ROUTER - Address of deployed CustomUniswapV2Router
 *   ASSET_ADDRESS - Address of asset token (USDC)
 *   EXTERNAL_VAULT - Address of external vault token
 *   ADMIN_ADDRESS - Address for vault admin
 *   TRADER_ADDRESS - Address for vault trader
 *   PRIVATE_KEY - Private key for deployment
 */

contract DeployVaultWithExistingDex is Script {
    // Existing deployed contracts (from environment)
    IRfyVaultFactory public vaultFactory;
    CustomUniswapV2Factory public dexFactory;
    CustomUniswapV2Router public dexRouter;
    IERC20 public asset;
    IERC20 public externalVault;
    
    // New vault instance
    IRfyVault public vault;
    
    // Configuration
    uint256 public constant INITIAL_DEPOSIT = 100e6; // 100 USDC
    uint256 public constant VAULT_SHARES_FOR_POOL = 50e6; // 50 vault shares
    uint256 public constant ASSET_FOR_POOL = 50e6; // 50 USDC
    uint256 public constant EPOCH_DURATION = 3 days;
    uint256 public constant MAX_TOTAL_DEPOSITS = 10000e6; // 10k USDC
    
    // Addresses
    address public deployer;
    address public admin;
    address public trader;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        // Load addresses from environment
        _loadExistingContracts();
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Step 1: Deploy new vault using existing factory
        _deployVault();
        
        // Step 2: Deposit into vault to get shares
        _depositIntoVault();
        
        // Step 3: Create DEX pool using existing factory/router
        _createDexPool();
        
        vm.stopBroadcast();
        
        // Step 4: Log deployment summary
        _logDeploymentSummary();
    }
    
    function _loadExistingContracts() internal {
        console.log("=== Loading Existing Contracts ===");
        
        // Load factory addresses from environment
        vaultFactory = IRfyVaultFactory(vm.envAddress("VAULT_FACTORY"));
        dexFactory = CustomUniswapV2Factory(vm.envAddress("DEX_FACTORY"));
        dexRouter = CustomUniswapV2Router(payable(vm.envAddress("DEX_ROUTER")));
        
        // Load token addresses
        asset = IERC20(vm.envAddress("USDC_ADDRESS"));
        externalVault = IERC20(vm.envAddress("EXTERNAL_VAULT"));
        
        // Load role addresses
        admin = vm.envAddress("ADMIN_ADDRESS");
        trader = vm.envAddress("TRADER_ADDRESS");
        
        console.log("Vault Factory:", address(vaultFactory));
        console.log("DEX Factory:", address(dexFactory));
        console.log("DEX Router:", address(dexRouter));
        console.log("Asset:", address(asset));
        console.log("External Vault:", address(externalVault));
        console.log("Admin:", admin);
        console.log("Trader:", trader);
        console.log("Deployer:", deployer);
    }
    
    function _deployVault() internal {
        console.log("\n=== Deploying New Vault ===");
        
        // Generate unique vault name and symbol based on timestamp
        string memory tokenName = "ETH BULLISH WEEKLY";
        string memory tokenSymbol = "GUNK";
        string memory memeName = "GUNK"; // Can be customized
        
        console.log("Creating vault with name:", tokenName);
        console.log("Symbol:", tokenSymbol);
        console.log("Meme name:", memeName);
        
        // Create vault using existing factory
        vault = IRfyVault(vaultFactory.createVault(
            tokenName,
            tokenSymbol,
            memeName,
            address(asset),
            admin,
            trader,
            address(externalVault),
            EPOCH_DURATION,
            MAX_TOTAL_DEPOSITS
        ));
        
        console.log("New vault deployed at:", address(vault));
        console.log("Vault name:", vault.name());
        console.log("Vault symbol:", vault.symbol());
    }
    
    function _depositIntoVault() internal {
        console.log("\n=== Depositing into Vault ===");
        
        // Check deployer's asset balance
        uint256 deployerBalance = asset.balanceOf(deployer);
        console.log("Deployer asset balance:", deployerBalance);
        
        require(deployerBalance >= INITIAL_DEPOSIT, "Insufficient asset balance for deposit");
        
        // Approve and deposit into vault
        asset.approve(address(vault), INITIAL_DEPOSIT);
        uint256 sharesReceived = vault.deposit(INITIAL_DEPOSIT, deployer);
        
        console.log("Deposited:", INITIAL_DEPOSIT, "assets");
        console.log("Received:", sharesReceived, "vault shares");
        console.log("Total vault assets:", vault.totalAssets());
        console.log("Total vault shares:", vault.totalSupply());
        console.log("Deployer vault shares:", vault.balanceOf(deployer));
    }
    
    function _createDexPool() internal {
        console.log("\n=== Creating DEX Pool ===");
        
        // Check if pair already exists
        address existingPair = dexFactory.getPair(address(vault), address(asset));
        if (existingPair != address(0)) {
            console.log("Pair already exists at:", existingPair);
            return;
        }
        
        // Create new pair
        address pairAddress = dexFactory.createPair(address(vault), address(asset));
        console.log("Created new pair at:", pairAddress);
        
        // Check balances before adding liquidity
        uint256 vaultShares = vault.balanceOf(deployer);
        uint256 assetBalance = asset.balanceOf(deployer);
        
        console.log("Available vault shares:", vaultShares);
        console.log("Available asset balance:", assetBalance);
        
        // Calculate amounts for pool (use portion of available balances)
        uint256 vaultSharesForPool = vaultShares / 2; // Use half of shares
        uint256 assetForPool = INITIAL_DEPOSIT / 2; // Use remaining assets
        
        require(vaultSharesForPool > 0, "No vault shares available for pool");
        require(assetForPool > 0, "No assets available for pool");
        
        console.log("Adding liquidity:");
        console.log("- Vault shares:", vaultSharesForPool);
        console.log("- Assets:", assetForPool);
        
        // Approve tokens for router
        vault.approve(address(dexRouter), vaultSharesForPool);
        asset.approve(address(dexRouter), assetForPool);
        
        // Add liquidity to the pool
        (uint256 amountA, uint256 amountB, uint256 liquidity) = dexRouter.addLiquidity(
            address(vault),      // tokenA (vault shares)
            address(asset),      // tokenB (asset)
            vaultSharesForPool,  // amountADesired
            assetForPool,        // amountBDesired
            vaultSharesForPool * 95 / 100, // amountAMin (5% slippage)
            assetForPool * 95 / 100,       // amountBMin (5% slippage)
            deployer,            // to
            block.timestamp + 1 hours      // deadline
        );
        
        console.log("Liquidity added successfully:");
        console.log("- Vault shares used:", amountA);
        console.log("- Assets used:", amountB);
        console.log("- LP tokens received:", liquidity);
    }
    
    function _logDeploymentSummary() internal view {
        console.log("\n" "================================================================");
        console.log("                    VAULT DEPLOYMENT SUMMARY");
        console.log("================================================================");
        
        console.log("\n=== EXISTING CONTRACTS ===");
        console.log("Vault Factory:", address(vaultFactory));
        console.log("DEX Factory:", address(dexFactory));
        console.log("DEX Router:", address(dexRouter));
        console.log("Asset Token:", address(asset));
        console.log("External Vault:", address(externalVault));
        
        console.log("\n=== NEW VAULT ===");
        console.log("Vault Address:", address(vault));
        console.log("Vault Name:", vault.name());
        console.log("Vault Symbol:", vault.symbol());
        console.log("Asset:", address(vault.asset()));
        
        console.log("\n=== VAULT STATE ===");
        console.log("Total Assets:", vault.totalAssets());
        console.log("Total Supply:", vault.totalSupply());
        console.log("Max Deposits:", vault.maxTotalDeposits());
        console.log("Epoch Duration:", vault.epochDuration());
        console.log("Current Epoch:", vault.currentEpoch());
        console.log("Deposits Paused:", vault.depositsPaused());
        console.log("Withdrawals Paused:", vault.withdrawalsPaused());
        
        console.log("\n=== BALANCES ===");
        console.log("Deployer Asset Balance:", asset.balanceOf(deployer));
        console.log("Deployer Vault Shares:", vault.balanceOf(deployer));
        console.log("Vault Asset Balance:", asset.balanceOf(address(vault)));
        
        console.log("\n=== DEX POOL ===");
        address pairAddress = dexFactory.getPair(address(vault), address(asset));
        if (pairAddress != address(0)) {
            console.log("Pair Address:", pairAddress);
            console.log("Pair Total Supply:", IERC20(pairAddress).totalSupply());
            console.log("Deployer LP Tokens:", IERC20(pairAddress).balanceOf(deployer));
            console.log("Pair Vault Balance:", vault.balanceOf(pairAddress));
            console.log("Pair Asset Balance:", asset.balanceOf(pairAddress));
        } else {
            console.log("No DEX pair created");
        }
        
        console.log("\n=== ROLE ADDRESSES ===");
        console.log("Deployer:", deployer);
        console.log("Admin:", admin);
        console.log("Trader:", trader);
        
        console.log("\n================================================================");
        console.log("Vault deployment and pool creation completed successfully!");
        console.log("================================================================");
    }
}