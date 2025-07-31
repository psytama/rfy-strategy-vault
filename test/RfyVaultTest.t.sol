// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { RfyVaultBase } from "./setup/RfyVaultBase.t.sol";
import { console } from "forge-std/Test.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";

contract RfyVaultTest is RfyVaultBase {
	function test_FirstEpochLoss() public {
		// Start first epoch
		vm.prank(admin);
		vault.startNewEpoch();

		// Trader borrows funds
		uint256 borrowAmount = 4000e6; // 4000 USDC
		vm.startPrank(trader);
		vault.borrow(borrowAmount);

		// Simulate loss of 400 USDC (10% loss)
		uint256 returnAmount = borrowAmount - 400e6;
		deal(USDC, trader, returnAmount);
		vm.warp(block.timestamp + vault.epochDuration() + 1);
		vault.settle(-400e6);
		vm.stopPrank();

		// Check user balances after loss
		uint256 expectedAssets = 900e6; // 1000 - (1000 * 0.1)
		uint256 maxDelta = 1e6;
		assertApproxEqAbs(vault.maxWithdraw(user1), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user2), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user3), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user4), expectedAssets, maxDelta);
	}

	function test_FirstEpochLoss_AfterFewDays() public {
		// Start first epoch
		vm.prank(admin);
		vault.startNewEpoch();

		// Trader borrows funds
		vm.warp(block.timestamp + 20 days + 1);
		uint256 borrowAmount = vault.externalVault().maxWithdraw(address(vault));

		vm.startPrank(trader);
		vault.borrow(borrowAmount);

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertGt(epochData.externalVaultPnl, 0, "There should be some yearn pnl");

		// Simulate loss of 400 USDC (10% loss)
		uint256 returnAmount = borrowAmount - 400e6;
		deal(USDC, trader, returnAmount);
		vm.warp(block.timestamp + vault.epochDuration() + 1);
		vault.settle(-400e6);
		vm.stopPrank();

		// Check user balances after loss
		uint256 expectedAssets = 900e6; // 1000 - (1000 * 0.1)
		uint256 maxDelta = 1e6;
		assertApproxEqAbs(vault.maxWithdraw(user1), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user2), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user3), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user4), expectedAssets, maxDelta);
	}

	function test_LossThenProfitExceedingLoss() public {
		// First epoch with loss
		vm.prank(admin);
		vault.startNewEpoch();

		uint256 borrowAmount = 3000e6;
		vm.startPrank(trader);
		vault.borrow(borrowAmount);

		// 100 USDC loss
		uint256 returnAmount = borrowAmount - 100e6;
		deal(USDC, trader, returnAmount);
		vm.warp(block.timestamp + vault.epochDuration() + 1);
		vault.settle(-100e6);
		vm.stopPrank();

		// Second epoch with profit
		vm.prank(admin);
		vault.startNewEpoch();

		vm.startPrank(trader);
		vault.borrow(borrowAmount);

		// 200 USDC profit
		deal(USDC, trader, borrowAmount + 200e6);
		vm.warp(block.timestamp + vault.epochDuration() + 1);
		vault.settle(200e6);

		// Check user balances after both epochs
		uint256 expectedAssets = 1025e6; // Original + net profit of 100 USDC distributed
		uint256 maxDelta = 1e6;
		assertApproxEqAbs(vault.maxWithdraw(user1), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user2), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user3), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user4), expectedAssets, maxDelta);
	}

	function test_LossThenInsufficientProfit() public {
		// First epoch with loss
		vm.prank(admin);
		vault.startNewEpoch();

		uint256 borrowAmount = 3000e6;
		vm.startPrank(trader);
		vault.borrow(borrowAmount);

		// 200 USDC loss
		uint256 returnAmount = borrowAmount - 200e6;
		deal(USDC, trader, returnAmount);
		vm.warp(block.timestamp + vault.epochDuration() + 1);
		vault.settle(-200e6);
		vm.stopPrank();

		// Second epoch with smaller profit
		vm.prank(admin);
		vault.startNewEpoch();

		vm.startPrank(trader);
		vault.borrow(borrowAmount);

		// 100 USDC profit
		deal(USDC, trader, borrowAmount + 100e6);

		vm.warp(block.timestamp + vault.epochDuration() + 1);
		vault.settle(100e6);
		vm.stopPrank();

		// Check user balances after both epochs
		uint256 expectedAssets = 975e6; // Original - net loss of 25 USDC distributed
		uint256 maxDelta = 1e6;
		assertApproxEqAbs(vault.maxWithdraw(user1), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user2), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user3), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user4), expectedAssets, maxDelta);
	}

	function test_TwoLossesThenProfitWithIntermediateWithdrawal() public {
		// First epoch with loss
		vm.prank(admin);
		vault.startNewEpoch();

		uint256 borrowAmount = 3000e6;
		vm.startPrank(trader);
		vault.borrow(borrowAmount);

		// 100 USDC loss
		uint256 returnAmount = borrowAmount - 100e6;
		deal(USDC, trader, returnAmount);
		vm.warp(block.timestamp + vault.epochDuration() + 1);
		vault.settle(-100e6);
		vm.stopPrank();

		// Second epoch with another loss
		vm.prank(admin);
		vault.startNewEpoch();

		vm.startPrank(trader);
		vault.borrow(borrowAmount);

		// 100 USDC loss
		deal(USDC, trader, borrowAmount - 100e6);
		vm.warp(block.timestamp + vault.epochDuration() + 1);
		vault.settle(-100e6);
		vm.stopPrank();

		// User1 withdraws after two losses
		vm.startPrank(user1);
		uint256 sharesToRedeem = vault.maxRedeem(user1);
		vault.redeem(sharesToRedeem, user1, user1);
		vm.stopPrank();

		// Third epoch with profit
		vm.prank(admin);
		vault.startNewEpoch();

		vm.startPrank(trader);
		vault.borrow(borrowAmount - 1000e6); // Reduce borrow amount since one user withdrew

		// 100 USDC profit
		deal(USDC, trader, (borrowAmount - 1000e6) + 100e6);
		vm.warp(block.timestamp + vault.epochDuration() + 1);
		vault.settle(100e6);
		vm.stopPrank();

		// Check remaining users' balances
		uint256 expectedAssets = 983333333; // (2950e6 / 3)
		uint256 maxDelta = 1e6;
		assertApproxEqAbs(vault.maxWithdraw(user2), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user3), expectedAssets, maxDelta);
		assertApproxEqAbs(vault.maxWithdraw(user4), expectedAssets, maxDelta);
	}

	function test_MaxLossScenario() public {
		vm.prank(admin);
		vault.startNewEpoch();

		uint256 initialVaultAssets = 4000e6;
		vm.startPrank(trader);
		vault.borrow(initialVaultAssets);

		vm.warp(block.timestamp + vault.epochDuration() + 1);

		deal(USDC, trader, 0);
		vault.settle(-int256(initialVaultAssets) + 1);

		assertEq(vault.totalAssets(), 0);
		vm.stopPrank();
	}

	function test_MaxDepositWithExternalVault() public {
		uint256 maxTotalDeposits = vault.maxTotalDeposits();
		uint256 currentAssets = vault.totalAssets();
		uint256 remainingCapacity = maxTotalDeposits - currentAssets;
		
		// Test that maxDeposit correctly reflects remaining capacity
		assertEq(vault.maxDeposit(address(0)), remainingCapacity, "maxDeposit should show remaining capacity");
		
		// Fill vault to exactly capacity
		address bigDepositor = makeAddr("bigDepositor");
		deal(USDC, bigDepositor, remainingCapacity);
		
		vm.startPrank(bigDepositor);
		usdc.approve(address(vault), remainingCapacity);
		vault.deposit(remainingCapacity, bigDepositor);
		vm.stopPrank();
		
		// Should now be at capacity
		assertEq(vault.maxDeposit(address(0)), 0, "maxDeposit should return 0 when at capacity");
		assertEq(vault.totalAssets(), maxTotalDeposits, "Should be at max capacity");
		
		// Try to deposit more should fail
		address testUser = makeAddr("testUser");
		deal(USDC, testUser, 1e6);
		
		vm.startPrank(testUser);
		usdc.approve(address(vault), 1e6);
		vm.expectRevert();
		vault.deposit(1e6, testUser);
		vm.stopPrank();
	}

	function test_MaxDepositAfterEpochAndSettle() public {
		uint256 initialMaxDeposit = vault.maxDeposit(address(0));
		
		// Start epoch and settle to ensure max deposit logic works after operations
		vm.prank(admin);
		vault.startNewEpoch();
		
		uint256 borrowAmount = vault.totalAssets() / 2;
		
		vm.startPrank(trader);
		vault.borrow(borrowAmount);
		
		vm.warp(block.timestamp + vault.epochDuration() + 1);
		deal(USDC, trader, borrowAmount + 100e6); // Some profit
		usdc.approve(address(vault), borrowAmount + 100e6);
		vault.settle(100e6); // 100 USDC profit
		vm.stopPrank();
		
		// After settlement, deposits are still paused, so maxDeposit should be 0
		uint256 maxDepositWhilePaused = vault.maxDeposit(address(0));
		assertEq(maxDepositWhilePaused, 0, "maxDeposit should return 0 when deposits are paused");
		assertTrue(vault.depositsPaused(), "Deposits should be paused after settlement");
		
		// Unpause deposits - only admin can do this
		vm.prank(admin);
		vault.unpauseAll();
		
		// Now max deposit should work correctly after unpause
		uint256 newMaxDeposit = vault.maxDeposit(address(0));
		uint256 totalAssetsAfterSettle = vault.totalAssets();
		uint256 maxTotalDeposits = vault.maxTotalDeposits();
		
		// After settlement with profit, calculate expected max deposit
		uint256 expectedMaxDeposit;
		if (totalAssetsAfterSettle >= maxTotalDeposits) {
			expectedMaxDeposit = 0;
		} else {
			expectedMaxDeposit = maxTotalDeposits - totalAssetsAfterSettle;
		}
		
		assertEq(newMaxDeposit, expectedMaxDeposit, "maxDeposit should work correctly after epoch settlement and unpause");
		assertLt(newMaxDeposit, initialMaxDeposit, "maxDeposit should be lower due to profit");
		assertFalse(vault.depositsPaused(), "Deposits should be unpaused after admin unpause");
	}
}
