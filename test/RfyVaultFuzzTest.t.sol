// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { RfyVaultBase } from "./setup/RfyVaultBase.t.sol";
import { console } from "forge-std/Test.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";

contract RfyVaultFuzzTest is RfyVaultBase {
	function testFuzz_Deposits(uint256 amount) public {
		uint256 maxAvailable = vault.maxDeposit(address(0));
		amount = bound(amount, MIN_DEPOSIT, maxAvailable > 0 ? maxAvailable : MIN_DEPOSIT);

		address testUser = makeAddr("testUser");
		deal(USDC, testUser, amount);

		vm.startPrank(testUser);
		usdc.approve(address(vault), amount);

		uint256 preBalance = usdc.balanceOf(testUser);
		uint256 preVaultAssets = vault.totalAssets();

		uint256 shares = vault.deposit(amount, testUser);

		assertEq(usdc.balanceOf(testUser), preBalance - amount);
		assertEq(vault.totalAssets(), preVaultAssets + amount);
		assertGt(shares, 0);
		assertEq(vault.balanceOf(testUser), shares);

		vm.stopPrank();
	}

	function testFuzz_BorrowErrors(uint256 borrowAmount) public {
		vm.prank(admin);
		vault.startNewEpoch();

		// Test zero amount
		if (borrowAmount == 0) {
			vm.prank(trader);
			vm.expectRevert(IRfyVault.SV_InvalidAmount.selector);
			vault.borrow(borrowAmount);
			return;
		}
		// Valid borrow should succeed
		vm.prank(trader);
		vault.borrow(borrowAmount);
	}

	function testFuzz_Borrow(uint256 borrowAmount) public {
		vm.prank(admin);
		vault.startNewEpoch();
		uint256 initialVaultAssets = vault.totalAssets();

		IRfyVault.EpochData memory preEpochData = vault.getEpochData(vault.currentEpoch());

		if (borrowAmount == 0) {
			vm.expectRevert(IRfyVault.SV_InvalidAmount.selector);
			vm.prank(trader);
			vault.borrow(borrowAmount);
			return;
		}

		vm.prank(trader);
		vault.borrow(borrowAmount);

		// Get post-borrow state
		IRfyVault.EpochData memory postEpochData = vault.getEpochData(vault.currentEpoch());

		if (borrowAmount > preEpochData.currentUnutilizedAsset) {
			assertLt(
				postEpochData.currentExternalVaultDeposits,
				preEpochData.currentExternalVaultDeposits,
				"External Vault deposits should decrease"
			);
		}
		assertTrue(
			postEpochData.currentExternalVaultDeposits <= preEpochData.currentExternalVaultDeposits,
			"External Vault deposit should not increase"
		);
		assertTrue(postEpochData.fundsBorrowed <= initialVaultAssets, "Cannot borrow more than total assets");
	}

	function testFuzz_Settle(int96 pnl) public {
		vm.prank(admin);
		vault.startNewEpoch();

		uint256 borrowAmount = vault.totalAssets() / 2;
		vm.prank(trader);
		vault.borrow(borrowAmount);

		// Try settling before epoch ends
		vm.prank(trader);
		vm.expectRevert(IRfyVault.SV_EpochNotEnded.selector);
		vault.settle(int256(pnl));

		vm.warp(block.timestamp + vault.epochDuration() + 1);

		// Calculate expected funds to transfer
		uint256 fundsToTransfer;
		if (pnl > 0) {
			fundsToTransfer = borrowAmount + uint256(int256(pnl));
		} else {
			if (uint256(-int256(pnl)) > borrowAmount) {
				vm.prank(trader);
				vm.expectRevert(IRfyVault.SV_LossExceedsBorrowAmount.selector);
				vault.settle(int256(pnl));
				return;
			} else {
				fundsToTransfer = borrowAmount - uint256(-int256(pnl));
			}
		}
		deal(USDC, trader, fundsToTransfer);

		IRfyVault.EpochData memory preEpochData = vault.getEpochData(vault.currentEpoch());

		vm.startPrank(trader);
		usdc.approve(address(vault), fundsToTransfer);
		vault.settle(int256(pnl));
		vm.stopPrank();

		IRfyVault.EpochData memory postEpochData = vault.getEpochData(vault.currentEpoch());

		assertEq(postEpochData.initialVaultAssets, preEpochData.initialVaultAssets, "Initial assets should not change");
		assertEq(postEpochData.fundsBorrowed, preEpochData.fundsBorrowed, "Borrowed amount should not change");
		assertEq(postEpochData.tradingPnl, pnl, "Trading PnL not recorded correctly");

		assertEq(postEpochData.currentExternalVaultDeposits, 0, "All External Vault deposits should be withdrawn");

		assertTrue(vault.depositsPaused(), "Deposits should be paused");
		assertFalse(vault.withdrawalsPaused(), "Withdrawals should be unpaused");

		assertTrue(postEpochData.finalVaultAssets > 0, "Final assets should be positive");
		if (pnl > 0) {
			assertGt(
				postEpochData.finalVaultAssets,
				preEpochData.initialVaultAssets,
				"Assets should increase with profit"
			);
		} else if (pnl < 0 && postEpochData.externalVaultPnl < pnl) {
			assertLt(
				postEpochData.finalVaultAssets,
				preEpochData.initialVaultAssets,
				"Assets should decrease with loss"
			);
		}
	}

	function testFuzz_WithdrawAndRedeem(uint256 depositAmount, uint256 withdrawAmount) public {
		uint256 maxAvailable = vault.maxDeposit(address(0));
		depositAmount = bound(depositAmount, MIN_DEPOSIT, maxAvailable > 0 ? maxAvailable : MIN_DEPOSIT);
		withdrawAmount = bound(withdrawAmount, 0, depositAmount);

		address testUser = makeAddr("testUser");
		deal(USDC, testUser, depositAmount);

		vm.startPrank(testUser);
		usdc.approve(address(vault), depositAmount);
		uint256 shares = vault.deposit(depositAmount, testUser);
		vm.stopPrank();

		vm.prank(admin);
		vault.startNewEpoch();

		vm.startPrank(testUser);
		vm.expectRevert(IRfyVault.SV_WithdrawalsArePaused.selector);
		vault.withdraw(withdrawAmount, testUser, testUser);

		vm.expectRevert(IRfyVault.SV_WithdrawalsArePaused.selector);
		vault.redeem(shares, testUser, testUser);
		vm.stopPrank();

		vm.warp(block.timestamp + vault.epochDuration() + 1);
		vm.startPrank(trader);
		deal(USDC, trader, depositAmount); // Ensure trader has enough to settle
		usdc.approve(address(vault), depositAmount);
		vault.settle(0);
		vm.stopPrank();

		vm.startPrank(testUser);
		uint256 preBalance = usdc.balanceOf(testUser);
		uint256 withdrawShares = vault.withdraw(withdrawAmount, testUser, testUser);

		assertEq(usdc.balanceOf(testUser), preBalance + withdrawAmount);
		assertEq(vault.balanceOf(testUser), shares - withdrawShares);

		vm.stopPrank();
	}

	function testFuzz_EpochStateChanges(uint256 amount) public {
		uint256 maxAvailable = vault.maxDeposit(address(0));
		amount = bound(amount, MIN_DEPOSIT, maxAvailable > 0 ? maxAvailable : MIN_DEPOSIT);

		// Setup initial state
		address depositor = makeAddr("depositor");
		deal(USDC, depositor, amount);

		vm.startPrank(depositor);
		usdc.approve(address(vault), amount);
		vault.deposit(amount, depositor);
		vm.stopPrank();

		// Start epoch
		vm.startPrank(admin);
		vault.startNewEpoch();
		uint256 preinitialVaultAssets = vault.totalAssets();

		// Verify epoch started state
		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertTrue(epochData.startTime > 0, "Start time should be set");
		assertEq(epochData.endTime, 0, "End time should not be set yet");
		assertFalse(epochData.isSettled, "Should not be settled");
		assertEq(epochData.initialVaultAssets, preinitialVaultAssets, "Initial assets incorrect");
		assertEq(epochData.fundsBorrowed, 0, "Should have no borrowed funds");
		assertTrue(epochData.isEpochActive, "Epoch should be active");
		assertTrue(vault.depositsPaused(), "Deposits should be paused");
		assertTrue(vault.withdrawalsPaused(), "Withdrawals should be paused");

		uint256 borrowAmount = amount / 2;
		vm.startPrank(trader);
		vault.borrow(borrowAmount);

		IRfyVault.EpochData memory postBorrowEpochData = vault.getEpochData(vault.currentEpoch());

		assertEq(postBorrowEpochData.fundsBorrowed, borrowAmount, "Borrowed amount not tracked");
		assertTrue(
			postBorrowEpochData.currentExternalVaultDeposits < epochData.initialExternalVaultDeposits,
			"External Vault deposits should decrease"
		);

		vm.warp(block.timestamp + vault.epochDuration() + 1);
		deal(USDC, trader, borrowAmount);
		usdc.approve(address(vault), borrowAmount);
		vault.settle(0);

		IRfyVault.EpochData memory finalEpochData = vault.getEpochData(vault.currentEpoch());

		assertTrue(finalEpochData.isSettled, "Epoch should be settled");
		assertEq(finalEpochData.currentExternalVaultDeposits, 0, "Should have no External Vault deposits");
		assertFalse(finalEpochData.isEpochActive, "Epoch should be inactive");
		assertTrue(vault.depositsPaused(), "Deposits should be paused");
		assertFalse(vault.withdrawalsPaused(), "Withdrawals should be unpaused");

		vm.stopPrank();
	}

	function testFuzz_DepositAndMint(uint256 amount) public {
		uint256 maxAvailable = vault.maxDeposit(address(0));
		amount = bound(amount, MIN_DEPOSIT, maxAvailable > 0 ? maxAvailable : MIN_DEPOSIT);
		
		address testUser = makeAddr("testUser");
		deal(USDC, testUser, amount);

		vm.prank(admin);
		vault.setDepositsPaused(true);

		vm.startPrank(testUser);
		usdc.approve(address(vault), amount);
		vm.expectRevert(IRfyVault.SV_DepositsArePaused.selector);
		vault.deposit(amount, testUser);
		vm.stopPrank();

		vm.prank(admin);
		vault.setDepositsPaused(false);

		uint256 preBalance = usdc.balanceOf(testUser);
		uint256 preVaultAssets = vault.totalAssets();

		vm.startPrank(testUser);
		uint256 shares = vault.deposit(amount, testUser);

		assertEq(usdc.balanceOf(testUser), preBalance - amount);
		assertEq(vault.totalAssets(), preVaultAssets + amount);
		assertGt(shares, 0);
		assertEq(vault.balanceOf(testUser), shares);
		vm.stopPrank();

		vm.startPrank(testUser);
		uint256 mintShares = amount / 2;
		uint256 expectedAssets = vault.previewMint(mintShares);
		
		// Check if there's enough capacity for the mint operation
		uint256 maxAvailableAfterDeposit = vault.maxDeposit(address(0));
		if (expectedAssets > maxAvailableAfterDeposit) {
			// If not enough capacity, skip the mint test
			vm.stopPrank();
			return;
		}
		
		deal(USDC, testUser, expectedAssets);
		usdc.approve(address(vault), expectedAssets);

		uint256 preBalanceBeforeMint = usdc.balanceOf(testUser);
		uint256 actualAssets = vault.mint(mintShares, testUser);

		assertEq(actualAssets, expectedAssets, "Mint assets calculation incorrect");
		assertEq(usdc.balanceOf(testUser), preBalanceBeforeMint - actualAssets);
		assertEq(vault.balanceOf(testUser), shares + mintShares);
		vm.stopPrank();
	}

	function testFuzz_AdminControls(uint256 duration) public {
		vm.assume(duration > 0 && duration < 365 days);

		vm.prank(admin);
		vault.setEpochDuration(duration);
		assertEq(vault.epochDuration(), duration, "Epoch duration not set correctly");

		vm.startPrank(admin);
		vault.pauseAll();
		assertTrue(vault.depositsPaused(), "Deposits not paused");
		assertTrue(vault.withdrawalsPaused(), "Withdrawals not paused");

		vault.unpauseAll();
		assertFalse(vault.depositsPaused(), "Deposits still paused");
		assertFalse(vault.withdrawalsPaused(), "Withdrawals still paused");

		vault.setDepositsPaused(true);
		assertTrue(vault.depositsPaused(), "Deposits not paused");
		assertFalse(vault.withdrawalsPaused(), "Withdrawals incorrectly paused");

		vault.setWithdrawalsPaused(true);
		assertTrue(vault.depositsPaused(), "Deposits not paused");
		assertTrue(vault.withdrawalsPaused(), "Withdrawals not paused");
		vm.stopPrank();

		address nonAdmin = makeAddr("nonAdmin");
		vm.startPrank(nonAdmin);
		vm.expectRevert();
		vault.setEpochDuration(duration);

		vm.expectRevert();
		vault.pauseAll();

		vm.expectRevert();
		vault.unpauseAll();

		vm.expectRevert();
		vault.setDepositsPaused(false);

		vm.expectRevert();
		vault.setWithdrawalsPaused(false);
		vm.stopPrank();
	}

	function testFuzz_ExternalVaultIntegration(uint256 amount) public {
		uint256 maxAvailable = vault.maxDeposit(address(0));
		amount = bound(amount, MIN_DEPOSIT, maxAvailable > 0 ? maxAvailable : MIN_DEPOSIT);

		address depositor = makeAddr("depositor");
		deal(USDC, depositor, amount);

		vm.startPrank(depositor);
		usdc.approve(address(vault), amount);
		vault.deposit(amount, depositor);
		vm.stopPrank();

		vm.startPrank(admin);
		vault.startNewEpoch();

		IRfyVault.EpochData memory initialEpochData = vault.getEpochData(vault.currentEpoch());

		assertEq(
			initialEpochData.initialExternalVaultDeposits,
			initialEpochData.currentExternalVaultDeposits,
			"Initial and current External Vault deposits should match"
		);

		vm.stopPrank();
		vm.startPrank(trader);
		uint256 borrowAmount = amount / 2;
		vault.borrow(borrowAmount);

		IRfyVault.EpochData memory postBorrowEpochData = vault.getEpochData(vault.currentEpoch());

		assertLt(
			postBorrowEpochData.currentExternalVaultDeposits,
			initialEpochData.initialExternalVaultDeposits,
			"External Vault deposits should decrease after borrow"
		);

		vm.warp(block.timestamp + vault.epochDuration() + 1);
		deal(USDC, trader, borrowAmount);
		usdc.approve(address(vault), borrowAmount);
		vault.settle(0);

		IRfyVault.EpochData memory finalEpochData = vault.getEpochData(vault.currentEpoch());
		uint256 finalAsset = vault.totalAssets();

		assertEq(finalEpochData.currentExternalVaultDeposits, 0, "Should have no External Vault deposits after settlement");
		assertGe(finalEpochData.externalVaultPnl, 0, "External Vault yield should be non-negative");
		assertEq(finalEpochData.finalVaultAssets, finalAsset, "All assets should be unutilized after settlement");

		vm.stopPrank();
	}

	function testFuzz_SettleWithLoss(uint256 lossPercentage) public {
		lossPercentage = bound(lossPercentage, 0, 100);

		vm.prank(admin);
		vault.startNewEpoch();

		uint256 borrowAmount = 4000e6;

		vm.startPrank(trader);
		vault.borrow(borrowAmount);
		borrowAmount -= 1;

		uint256 loss = (borrowAmount * lossPercentage) / 100;
		int256 pnl = -int256(loss);

		uint256 returnAmount = borrowAmount - loss;
		deal(USDC, trader, returnAmount);

		vm.warp(block.timestamp + vault.epochDuration() + 1);
		vault.settle(pnl);

		uint256 finalAssets = vault.totalAssets();
		assertGe(finalAssets, 0, "Vault assets should never be negative");
		vm.stopPrank();
	}

	function testFuzz_MaxDepositEnforcement(uint256 amount) public {
		// Test that deposits exceeding maxTotalDeposits are rejected
		uint256 currentAssets = vault.totalAssets();
		uint256 maxTotalDeposits = vault.maxTotalDeposits();
		
		// If vault is already at capacity, test should show maxDeposit returns 0
		if (currentAssets >= maxTotalDeposits) {
			assertEq(vault.maxDeposit(address(0)), 0, "maxDeposit should return 0 when at capacity");
			return;
		}
		
		uint256 remainingCapacity = maxTotalDeposits - currentAssets;
		amount = bound(amount, remainingCapacity + 1, remainingCapacity + 1_000_000e6);
		
		address testUser = makeAddr("testUser");
		deal(USDC, testUser, amount);
		
		vm.startPrank(testUser);
		usdc.approve(address(vault), amount);
		
		// Should revert when trying to deposit more than remaining capacity
		vm.expectRevert();
		vault.deposit(amount, testUser);
		vm.stopPrank();
	}

	function testFuzz_MaxDepositReturnsCorrectValue(uint256 depositAmount) public {
		uint256 maxTotalDeposits = vault.maxTotalDeposits();
		uint256 currentAssets = vault.totalAssets();
		
		if (currentAssets >= maxTotalDeposits) {
			assertEq(vault.maxDeposit(address(0)), 0, "maxDeposit should return 0 when at capacity");
			return;
		}
		
		uint256 expectedMaxDeposit = maxTotalDeposits - currentAssets;
		uint256 actualMaxDeposit = vault.maxDeposit(address(0));
		
		assertEq(actualMaxDeposit, expectedMaxDeposit, "maxDeposit should return remaining capacity");
		
		// Test with a valid deposit amount
		depositAmount = bound(depositAmount, MIN_DEPOSIT, actualMaxDeposit);
		
		address testUser = makeAddr("testUser");
		deal(USDC, testUser, depositAmount);
		
		vm.startPrank(testUser);
		usdc.approve(address(vault), depositAmount);
		vault.deposit(depositAmount, testUser);
		vm.stopPrank();
		
		// Check that maxDeposit value decreased correctly
		uint256 newMaxDeposit = vault.maxDeposit(address(0));
		assertEq(newMaxDeposit, actualMaxDeposit - depositAmount, "maxDeposit should decrease by deposit amount");
	}

	function testFuzz_MaxMintEnforcement(uint256 shares) public {
		uint256 maxTotalDeposits = vault.maxTotalDeposits();
		uint256 currentAssets = vault.totalAssets();
		
		if (currentAssets >= maxTotalDeposits) {
			assertEq(vault.maxMint(address(0)), 0, "maxMint should return 0 when at capacity");
			return;
		}
		
		uint256 remainingCapacity = maxTotalDeposits - currentAssets;
		uint256 maxShares = vault.previewDeposit(remainingCapacity);
		
		// Test with shares that would exceed capacity
		shares = bound(shares, maxShares + 1, maxShares + 1_000_000e6);
		
		address testUser = makeAddr("testUser");
		uint256 assetsNeeded = vault.previewMint(shares);
		deal(USDC, testUser, assetsNeeded);
		
		vm.startPrank(testUser);
		usdc.approve(address(vault), assetsNeeded);
		
		// Should revert when trying to mint more shares than capacity allows
		vm.expectRevert();
		vault.mint(shares, testUser);
		vm.stopPrank();
	}
}
