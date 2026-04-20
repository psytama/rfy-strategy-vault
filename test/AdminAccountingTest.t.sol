// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { RfyVault } from "../src/RfyVault.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract AdminAccountingTest is Test {
    RfyVault vault;
    MockERC20 usdc;
    
    address admin = address(0x1);
    address trader = address(0x2);
    address depositor = address(0x3);

    function setUp() public {
        // Deploy mock USDC
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy vault
        vault = new RfyVault();
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
        usdc.mint(depositor, 100000 * 10**6);
        usdc.mint(admin, 50000 * 10**6);
        
        // Depositor deposits funds
        vm.startPrank(depositor);
        usdc.approve(address(vault), 50000 * 10**6);
        
        vm.stopPrank();
        vm.startPrank(admin);
        vault.setDepositsPaused(false);
        vm.stopPrank();
        
        vm.startPrank(depositor);
        vault.deposit(50000 * 10**6, depositor);
        vm.stopPrank();
    }

    function testAdminBorrowUpdatesAccountingCorrectly() public {
        vm.startPrank(admin);
        vault.startNewEpoch(0);

        // Check initial state
        uint256 initialTotalAssets = vault.totalAssets();
        uint256 initialVaultBalance = usdc.balanceOf(address(vault));
        uint256 initialAdminBalance = usdc.balanceOf(admin);
        
        assertEq(initialTotalAssets, 50000 * 10**6, "Initial total assets should be 50k");
        assertEq(initialVaultBalance, 50000 * 10**6, "Initial vault balance should be 50k");
        assertEq(initialAdminBalance, 50000 * 10**6, "Initial admin balance should be 50k");

        // Admin borrows 20k USDC
        uint256 borrowAmount = 20000 * 10**6;
        vault.adminBorrow(borrowAmount);

        // Check state after borrow
        uint256 totalAssetsAfterBorrow = vault.totalAssets();
        uint256 vaultBalanceAfterBorrow = usdc.balanceOf(address(vault));
        uint256 adminBalanceAfterBorrow = usdc.balanceOf(admin);

        assertEq(totalAssetsAfterBorrow, 50000 * 10**6, "Total assets should remain unchanged during borrow");
        assertEq(vaultBalanceAfterBorrow, 30000 * 10**6, "Vault balance should decrease by borrow amount");
        assertEq(adminBalanceAfterBorrow, 70000 * 10**6, "Admin balance should increase by borrow amount");

        // Admin returns 25k USDC (5k profit)
        uint256 returnAmount = 25000 * 10**6;
        usdc.approve(address(vault), returnAmount);
        vault.adminSettle(returnAmount);

        // Check final state
        uint256 finalTotalAssets = vault.totalAssets();
        uint256 finalVaultBalance = usdc.balanceOf(address(vault));
        uint256 finalAdminBalance = usdc.balanceOf(admin);

        // Expected: Initial 50k + 5k profit = 55k
        assertEq(finalTotalAssets, 55000 * 10**6, "Total assets should reflect 5k profit");
        assertEq(finalVaultBalance, 55000 * 10**6, "Vault balance should reflect 5k profit");
        assertEq(finalAdminBalance, 45000 * 10**6, "Admin balance should be initial - returned");

        // Verify PnL tracking
        IRfyVault.EpochData memory epochData = vault.getEpochData(1);
        assertEq(epochData.adminPnl, 5000 * 10**6, "Admin PnL should be 5k profit");

        vm.stopPrank();
    }

    function testAdminBorrowWithLossUpdatesAccountingCorrectly() public {
        vm.startPrank(admin);
        vault.startNewEpoch(0);

        // Admin borrows 30k USDC
        uint256 borrowAmount = 30000 * 10**6;
        vault.adminBorrow(borrowAmount);

        // Check state after borrow
        uint256 totalAssetsAfterBorrow = vault.totalAssets();
        assertEq(totalAssetsAfterBorrow, 50000 * 10**6, "Total assets should remain unchanged during borrow");

        // Admin returns only 25k USDC (5k loss)
        uint256 returnAmount = 25000 * 10**6;
        usdc.approve(address(vault), returnAmount);
        vault.adminSettle(returnAmount);

        // Check final state
        uint256 finalTotalAssets = vault.totalAssets();
        uint256 finalVaultBalance = usdc.balanceOf(address(vault));

        // Expected: 50k (unchanged during borrow) + (-5k PnL) = 45k (net 5k loss from initial 50k)
        assertEq(finalTotalAssets, 45000 * 10**6, "Total assets should reflect 5k loss");
        assertEq(finalVaultBalance, 45000 * 10**6, "Vault balance should reflect 5k loss");

        // Verify PnL tracking
        IRfyVault.EpochData memory epochData = vault.getEpochData(1);
        assertEq(epochData.adminPnl, -5000 * 10**6, "Admin PnL should be -5k loss");

        vm.stopPrank();
    }

    function testMultipleAdminOperationsAccounting() public {
        vm.startPrank(admin);
        vault.startNewEpoch(0);

        uint256 initialTotalAssets = vault.totalAssets();
        assertEq(initialTotalAssets, 50000 * 10**6, "Initial total assets should be 50k");

        // First operation: Borrow 15k, return 16k (1k profit)
        vault.adminBorrow(15000 * 10**6);
        uint256 assetsAfterFirstBorrow = vault.totalAssets();
        assertEq(assetsAfterFirstBorrow, 50000 * 10**6, "Assets should remain 50k after first borrow");

        usdc.approve(address(vault), 16000 * 10**6);
        vault.adminSettle(16000 * 10**6);
        uint256 assetsAfterFirstSettle = vault.totalAssets();
        assertEq(assetsAfterFirstSettle, 51000 * 10**6, "Assets should be 51k after first settle (1k profit)");

        // Second operation: Borrow 20k, return 18k (2k loss)
        vault.adminBorrow(20000 * 10**6);
        uint256 assetsAfterSecondBorrow = vault.totalAssets();
        assertEq(assetsAfterSecondBorrow, 51000 * 10**6, "Assets should remain 51k after second borrow");

        usdc.approve(address(vault), 18000 * 10**6);
        vault.adminSettle(18000 * 10**6);
        uint256 finalAssets = vault.totalAssets();
        assertEq(finalAssets, 49000 * 10**6, "Final assets should be 49k (net 1k loss)");

        // Verify cumulative PnL
        IRfyVault.EpochData memory epochData = vault.getEpochData(1);
        assertEq(epochData.adminPnl, -1000 * 10**6, "Cumulative admin PnL should be -1k");

        vm.stopPrank();
    }
}