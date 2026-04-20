// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { RfyVault } from "../src/RfyVault.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract AdminFunctionTest is Test {
    RfyVault vault;
    MockERC20 usdc;
    
    address admin = address(0x1);
    address trader = address(0x2);
    address depositor = address(0x3);

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy vault implementation
        RfyVault vaultImpl = new RfyVault();

        // Create proxy manually (simplified version)
        vault = RfyVault(address(vaultImpl));
        vault.initialize(
            "Test Vault Token",
            "TVT", 
            "TestMeme",
            address(usdc),
            admin,
            trader,
            address(0),
            86400,
            1000000 * 10**6
        );

        // Setup initial balances
        usdc.mint(depositor, 100000 * 10**6); // 100k USDC
        usdc.mint(admin, 50000 * 10**6); // 50k USDC for admin
        
        // Depositor deposits funds
        vm.startPrank(depositor);
        usdc.approve(address(vault), 50000 * 10**6);
        
        // Enable deposits first
        vm.stopPrank();
        vm.startPrank(admin);
        vault.setDepositsPaused(false);
        vm.stopPrank();
        
        vm.startPrank(depositor);
        vault.deposit(50000 * 10**6, depositor);
        vm.stopPrank();
    }

    function testAdminBorrowAndSettle() public {
        // Admin starts a new epoch
        vm.startPrank(admin);
        vault.startNewEpoch(0);

        // Check initial state
        uint256 maxBorrowable = vault.maxAdminBorrow();
        assertEq(maxBorrowable, 50000 * 10**6, "Max borrowable should be 50k USDC");

        // Admin borrows 20k USDC
        uint256 borrowAmount = 20000 * 10**6;
        uint256 actualBorrowed = vault.adminBorrow(borrowAmount);
        assertEq(actualBorrowed, borrowAmount, "Should borrow exact amount");
        assertEq(usdc.balanceOf(admin), 70000 * 10**6, "Admin should have 70k USDC");

        // Check epoch data
        IRfyVault.EpochData memory epochData = vault.getEpochData(1);
        assertEq(epochData.adminFundsBorrowed, borrowAmount, "Admin funds borrowed should be tracked");

        // Admin returns 25k USDC (5k profit)
        uint256 returnAmount = 25000 * 10**6;
        usdc.approve(address(vault), returnAmount);
        vault.adminSettle(returnAmount);

        // Check final state
        epochData = vault.getEpochData(1);
        assertEq(epochData.adminFundsBorrowed, 0, "Admin borrowed amount should be reset");
        assertEq(epochData.adminPnl, 5000 * 10**6, "Admin PnL should be 5k profit");
        
        // Check admin balance
        assertEq(usdc.balanceOf(admin), 45000 * 10**6, "Admin should have 45k USDC left");

        vm.stopPrank();
    }

    function testAdminBorrowWithLoss() public {
        // Admin starts a new epoch
        vm.startPrank(admin);
        vault.startNewEpoch(0);

        // Admin borrows 30k USDC
        uint256 borrowAmount = 30000 * 10**6;
        vault.adminBorrow(borrowAmount);

        // Admin returns only 25k USDC (5k loss)
        uint256 returnAmount = 25000 * 10**6;
        usdc.approve(address(vault), returnAmount);
        vault.adminSettle(returnAmount);

        // Check final state
        IRfyVault.EpochData memory epochData = vault.getEpochData(1);
        assertEq(epochData.adminFundsBorrowed, 0, "Admin borrowed amount should be reset");
        assertEq(epochData.adminPnl, -5000 * 10**6, "Admin PnL should be -5k loss");

        vm.stopPrank();
    }

    function testMultipleAdminBorrows() public {
        // Admin starts a new epoch
        vm.startPrank(admin);
        vault.startNewEpoch(0);

        // Admin borrows 15k USDC first time
        vault.adminBorrow(15000 * 10**6);
        
        // Admin settles first borrow with 16k return (1k profit)
        usdc.approve(address(vault), 16000 * 10**6);
        vault.adminSettle(16000 * 10**6);

        // Admin borrows 20k USDC second time
        vault.adminBorrow(20000 * 10**6);
        
        // Admin settles second borrow with 18k return (2k loss)  
        usdc.approve(address(vault), 18000 * 10**6);
        vault.adminSettle(18000 * 10**6);

        // Check cumulative admin PnL: 1k profit - 2k loss = -1k loss
        IRfyVault.EpochData memory epochData = vault.getEpochData(1);
        assertEq(epochData.adminPnl, -1000 * 10**6, "Cumulative admin PnL should be -1k loss");

        vm.stopPrank();
    }

    function testTraderSettleIncludesAdminPnl() public {
        // Admin starts a new epoch
        vm.startPrank(admin);
        vault.startNewEpoch(0);

        // Admin borrows and settles with profit
        vault.adminBorrow(10000 * 10**6);
        usdc.approve(address(vault), 12000 * 10**6);
        vault.adminSettle(12000 * 10**6); // 2k profit

        vm.stopPrank();

        // Trader borrows
        vm.startPrank(trader);
        
        // Fast forward past epoch duration
        vm.warp(block.timestamp + 86401);

        // Trader settles with profit
        usdc.mint(trader, 25000 * 10**6);
        usdc.approve(address(vault), 25000 * 10**6);
        vault.settle(5000 * 10**6); // 5k trading profit

        vm.stopPrank();

        // Check final vault assets include both trading and admin PnL
        uint256 finalAssets = vault.totalAssets();
        // Initial: 50k, Trading PnL: +5k, Admin PnL: +2k = 57k
        assertEq(finalAssets, 57000 * 10**6, "Final assets should include admin PnL");
    }
}