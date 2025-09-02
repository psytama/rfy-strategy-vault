// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { RfyVaultBase } from "./setup/RfyVaultBase.t.sol";
import { console } from "forge-std/Test.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract RfyVaultUnitTest is RfyVaultBase {
	function test_initialization() public view {
		assertEq(address(vault.asset()), USDC);
		assertEq(vault.name(), "Rfy Vault Token");
		assertEq(vault.symbol(), "RFY");
		assertEq(vault.decimals(), 6);
		assertEq(vault.epochDuration(), 30 days);
		assertEq(address(vault.externalVault()), YEARN_VAULT);
		assertFalse(vault.depositsPaused());
		assertFalse(vault.withdrawalsPaused());
	}

	function test_deposit() public {
		uint256 initialBalance = usdc.balanceOf(address(vault));
		uint256 initialTotalAssets = vault.totalAssets();

		vm.startPrank(user1);
		uint256 depositAmount = 100e6;
		uint256 expectedShares = depositAmount; // 1:1 ratio initially
		uint256 shares = vault.deposit(depositAmount, user1);

		assertEq(shares, expectedShares, "Incorrect shares minted");
		assertEq(vault.balanceOf(user1), shares + DEPOSIT_AMOUNT, "Incorrect user share balance");
		assertEq(usdc.balanceOf(address(vault)), initialBalance + depositAmount, "Incorrect vault balance");
		assertEq(vault.totalAssets(), initialTotalAssets + depositAmount, "Incorrect total assets");
		vm.stopPrank();
	}

	function test_deposit_whenPaused() public {
		vm.prank(admin);
		vault.setDepositsPaused(true);

		vm.startPrank(user1);
		vm.expectRevert(IRfyVault.SV_DepositsArePaused.selector);
		vault.deposit(100e6, user1);
		vm.stopPrank();
		uint256 maxDeposit = vault.maxDeposit(user1);
		assertEq(maxDeposit, 0);
		uint256 maxMint = vault.maxMint(user1);
		assertEq(maxMint, 0);
	}

	function test_withdraw() public {
		vm.startPrank(user1);
		uint256 initialShares = vault.balanceOf(user1);
		uint256 initialBalance = usdc.balanceOf(user1);
		uint256 withdrawAmount = 100e6;

		uint256 sharesBurned = vault.withdraw(withdrawAmount, user1, user1);

		assertEq(vault.balanceOf(user1), initialShares - sharesBurned, "Incorrect shares burned");
		assertEq(usdc.balanceOf(user1), initialBalance + withdrawAmount, "Incorrect USDC returned");
		vm.stopPrank();
	}

	function test_withdraw_whenPaused() public {
		vm.prank(admin);
		vault.setWithdrawalsPaused(true);

		vm.startPrank(user1);
		vm.expectRevert(IRfyVault.SV_WithdrawalsArePaused.selector);
		vault.withdraw(100e6, user1, user1);
		vm.stopPrank();

		uint256 maxWithdraw = vault.maxWithdraw(user1);
		assertEq(maxWithdraw, 0);
		uint256 maxRedeem = vault.maxRedeem(user1);
		assertEq(maxRedeem, 0);
	}

	function test_startNewEpoch() public {
		uint256 initialTotalAssets = vault.totalAssets();

		vm.prank(admin);
		vm.expectEmit(true, false, false, true);
		emit EpochStarted(1, block.timestamp);
		vault.startNewEpoch(4e8);
		assertTrue(vault.depositsPaused(), "Deposits should be paused");
		assertTrue(vault.withdrawalsPaused(), "Withdrawals should be paused");
		assertEq(vault.currentEpoch(), 1, "Incorrect epoch number");

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertEq(uint256(epochData.startTime), block.timestamp, "Incorrect start time");
		assertEq(epochData.endTime, 0, "End time should be 0");
		assertFalse(epochData.isSettled, "Should not be settled");
		assertTrue(epochData.isEpochActive, "Epoch should be active");
		assertEq(epochData.initialVaultAssets, initialTotalAssets, "Incorrect initial assets");
		assertEq(epochData.initialExternalVaultDeposits, initialTotalAssets, "Incorrect initial Yearn deposits");
		assertEq(epochData.initialUnutilizedAsset, 0, "Should have no unutilized assets initially");
		assertEq(epochData.currentExternalVaultDeposits, initialTotalAssets, "Incorrect current Yearn deposits");
		assertEq(epochData.currentUnutilizedAsset, 0, "Should have no unutilized assets");
		assertEq(epochData.fundsBorrowed, 0, "Should have no borrowed funds");
		assertEq(epochData.finalVaultAssets, 0, "Should have no final assets");
		assertEq(epochData.externalVaultPnl, 0, "Should have no Yearn PnL");
		assertEq(epochData.tradingPnl, 0, "Should have no trading PnL");
	}

	function test_startNewEpoch_whenActive() public {
		vm.prank(admin);
		vault.startNewEpoch(4e8);

		vm.prank(admin);
		vm.expectRevert(IRfyVault.SV_EpochActive.selector);
		vault.startNewEpoch(4e8);
	}

	function test_deposit_whenEpochActive() public {
		vm.prank(admin);
		vault.startNewEpoch(4e8);

		vm.startPrank(user1);
		vm.expectRevert(IRfyVault.SV_DepositsArePaused.selector);
		vault.deposit(100e6, user1);
		vm.stopPrank();
	}

	function test_startNewEpoch_withHighDeposits() public {
		vm.startPrank(user1);
		uint256 totalAssetsBefore = vault.totalAssets();
		uint256 depositAmount = vault.externalVault().maxDeposit(address(vault));
		deal(USDC, user1, depositAmount);
		vault.deposit(depositAmount, user1);
		vm.stopPrank();

		uint256 initialTotalAssets = vault.totalAssets();

		vm.prank(admin);
		vm.expectEmit(true, false, false, true);
		emit EpochStarted(1, block.timestamp);
		vault.startNewEpoch(4e8);
		assertTrue(vault.depositsPaused(), "Deposits should be paused");
		assertTrue(vault.withdrawalsPaused(), "Withdrawals should be paused");
		assertEq(vault.currentEpoch(), 1, "Incorrect epoch number");

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertTrue(epochData.isEpochActive, "Epoch should be active");
		assertEq(epochData.initialVaultAssets, initialTotalAssets, "Incorrect initial assets");
		assertEq(epochData.initialExternalVaultDeposits, depositAmount, "Incorrect initial Yearn deposits");
		assertEq(epochData.initialUnutilizedAsset, totalAssetsBefore, "Should have greater unutilized assets");
		assertEq(epochData.currentExternalVaultDeposits, depositAmount, "Incorrect current Yearn deposits");

		assertEq(epochData.currentUnutilizedAsset, totalAssetsBefore, "Should have unutilized assets");
		assertEq(epochData.fundsBorrowed, 0, "Should have no borrowed funds");
		assertEq(epochData.finalVaultAssets, 0, "Should have no final assets");
		assertEq(epochData.externalVaultPnl, 0, "Should have no Yearn PnL");
		assertEq(epochData.tradingPnl, 0, "Should have no trading PnL");
	}

	function test_withdraw_whenEpochActive() public {
		vm.prank(admin);
		vault.startNewEpoch(4e8);

		vm.startPrank(user1);
		vm.expectRevert(IRfyVault.SV_WithdrawalsArePaused.selector);
		vault.withdraw(100e6, user1, user1);
		vm.stopPrank();
	}

	function test_startEpoch_withZeroFunds() public {
		vm.startPrank(user1);
		vault.withdraw(DEPOSIT_AMOUNT, user1, user1);
		vm.stopPrank();

		vm.startPrank(user2);
		vault.withdraw(DEPOSIT_AMOUNT, user2, user2);
		vm.stopPrank();

		vm.startPrank(user3);
		vault.withdraw(DEPOSIT_AMOUNT, user3, user3);
		vm.stopPrank();

		vm.startPrank(user4);
		vault.withdraw(DEPOSIT_AMOUNT, user4, user4);
		vm.stopPrank();

		vm.prank(admin);
		vm.expectRevert(IRfyVault.SV_NoAvailableFunds.selector);
		vault.startNewEpoch(4e8);
		vm.stopPrank();
	}

	function test_borrow() public {
		vm.prank(admin);
		vault.startNewEpoch(4e8);

		uint256 borrowAmount = 100e6;
		vm.prank(trader);
		vm.expectEmit(true, false, false, true);
		emit FundsBorrowed(trader, borrowAmount);
		vault.borrow(borrowAmount);

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertEq(epochData.fundsBorrowed, borrowAmount, "Incorrect borrowed amount");
		assertEq(epochData.currentUnutilizedAsset, 0, "Should have no unutilized assets");
		assertGt(epochData.currentExternalVaultDeposits, 0, "Should have remaining Yearn deposits");
	}

	function test_borrow_noEpoch() public {
		vm.prank(trader);
		vm.expectRevert(IRfyVault.SV_EpochNotActive.selector);
		vault.borrow(100e6);
	}

	function test_borrow_zeroAmount() public {
		vm.prank(admin);
		vault.startNewEpoch(4e8);

		vm.prank(trader);
		vm.expectRevert(IRfyVault.SV_InvalidAmount.selector);
		vault.borrow(0);
	}

	function test_settle() public {
		vm.prank(admin);
		vault.startNewEpoch(4e8);

		uint256 borrowAmount = 100e6;
		vm.prank(trader);
		vault.borrow(borrowAmount);

		vm.warp(block.timestamp + 31 days);

		int256 pnl = 10e6;
		vm.startPrank(trader);
		usdc.approve(address(vault), borrowAmount + uint256(pnl));
		vm.expectEmit(true, false, false, true);
		emit FundsSettled(trader, borrowAmount, pnl);
		emit EpochEnded(1, block.timestamp);
		vault.settle(pnl);
		vm.stopPrank();

		assertTrue(vault.depositsPaused(), "Deposits should be paused");
		assertFalse(vault.withdrawalsPaused(), "Withdrawals should be unpaused");

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertEq(epochData.endTime, uint96(block.timestamp), "Incorrect end time");
		assertFalse(epochData.isEpochActive, "Epoch should be inactive");
		assertTrue(epochData.isSettled, "Epoch should be settled");
		assertEq(epochData.tradingPnl, pnl, "Incorrect trading PnL");
		assertGt(epochData.externalVaultPnl, 0, "Should have Yearn PnL");
		assertEq(epochData.currentExternalVaultDeposits, 0, "Should have no Yearn deposits");
		assertEq(epochData.currentUnutilizedAsset, 0, "Should have zero unutilized assets");
		assertGt(
			epochData.finalVaultAssets,
			epochData.initialVaultAssets,
			"Final assets should be greater than initial"
		);
	}

	function test_setEpochDuration() public {
		uint256 newDuration = 14 days;

		vm.prank(admin);
		vm.expectEmit(false, false, false, true);
		emit EpochDurationUpdated(newDuration);
		vault.setEpochDuration(newDuration);

		assertEq(vault.epochDuration(), newDuration, "Incorrect epoch duration");
	}

	function test_pauseAll() public {
		vm.prank(admin);
		vm.expectEmit(false, false, false, true);
		emit DepositWithdrawalPaused();
		vault.pauseAll();

		assertTrue(vault.depositsPaused(), "Deposits should be paused");
		assertTrue(vault.withdrawalsPaused(), "Withdrawals should be paused");
	}

	function test_unpauseAll() public {
		vm.prank(admin);
		vault.pauseAll();

		vm.prank(admin);
		vm.expectEmit(false, false, false, true);
		emit DepositWithdrawalUnpaused();
		vault.unpauseAll();

		assertFalse(vault.depositsPaused(), "Deposits should be unpaused");
		assertFalse(vault.withdrawalsPaused(), "Withdrawals should be unpaused");
	}

	function test_onlyAdminFunctions() public {
		vm.startPrank(user1);

		vm.expectRevert();
		vault.startNewEpoch(4e8);

		vm.expectRevert();
		vault.setDepositsPaused(true);

		vm.expectRevert();
		vault.setWithdrawalsPaused(true);

		vm.expectRevert();
		vault.setEpochDuration(14 days);

		vm.expectRevert();
		vault.pauseAll();

		vm.expectRevert();
		vault.unpauseAll();

		vm.stopPrank();
	}

	function test_onlyTraderFunctions() public {
		vm.prank(admin);
		vault.startNewEpoch(4e8);

		vm.startPrank(user1);

		vm.expectRevert();
		vault.borrow(100e6);

		vm.expectRevert();
		vault.settle(10e6);

		vm.stopPrank();
	}

	function test_settle_withNegativePnL() public {
		vm.prank(admin);
		vault.startNewEpoch(4e8);

		uint256 borrowAmount = 100e6;
		vm.prank(trader);
		vault.borrow(borrowAmount);

		vm.warp(block.timestamp + 31 days);

		int256 pnl = -10e6;
		vm.startPrank(trader);
		uint256 returnAmount = borrowAmount - uint256(-pnl);
		usdc.approve(address(vault), returnAmount);
		vm.expectRevert(IRfyVault.SV_LossExceedsBorrowAmount.selector);
		vault.settle(-1000e6);

		vault.settle(pnl);
		vm.stopPrank();

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertEq(epochData.endTime, uint96(block.timestamp), "Incorrect end time");
		assertTrue(epochData.isSettled, "Epoch should be settled");
		assertEq(epochData.tradingPnl, pnl, "Incorrect trading PnL");
		assertGt(epochData.externalVaultPnl, 0, "Should have Yearn PnL");
		assertEq(epochData.currentExternalVaultDeposits, 0, "Should have no Yearn deposits");
		assertEq(epochData.currentUnutilizedAsset, 0, "Should have zero unutilized assets");
		assertLt(epochData.finalVaultAssets, epochData.initialVaultAssets, "Final assets should be less than initial");
	}

	function test_settle_ZeroBorrow() public {
		vm.prank(admin);
		vault.startNewEpoch(4e8);

		vm.warp(block.timestamp + 31 days);
		vm.startPrank(trader);
		vm.expectEmit(true, false, false, true);
		emit FundsSettled(trader, 0, 0);
		emit EpochEnded(1, block.timestamp);
		vault.settle(0);
		vm.stopPrank();

		assertTrue(vault.depositsPaused(), "Deposits should be paused");
		assertFalse(vault.withdrawalsPaused(), "Withdrawals should be unpaused");

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertEq(epochData.endTime, uint96(block.timestamp), "Incorrect end time");
		assertTrue(epochData.isSettled, "Epoch should be settled");
		assertFalse(epochData.isEpochActive, "Epoch should be inactive");
		assertEq(epochData.tradingPnl, 0, "Incorrect trading PnL");
		assertGt(epochData.externalVaultPnl, 0, "Should have Yearn PnL");
		assertEq(epochData.currentExternalVaultDeposits, 0, "Should have no Yearn deposits");
		assertEq(epochData.currentUnutilizedAsset, 0, "Should have zero unutilized assets");
		assertGt(
			epochData.finalVaultAssets,
			epochData.initialVaultAssets,
			"Final assets should be greater than initial"
		);
	}

	function test_settle_withZeroPnL() public {
		vm.prank(admin);
		vault.startNewEpoch(4e8);

		uint256 borrowAmount = 100e6;
		vm.prank(trader);
		vault.borrow(borrowAmount);

		vm.warp(block.timestamp + 31 days);

		int256 pnl;
		vm.startPrank(trader);
		uint256 returnAmount = borrowAmount + uint256(pnl);
		usdc.approve(address(vault), returnAmount);

		vault.settle(pnl);
		vm.stopPrank();

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertEq(epochData.endTime, uint96(block.timestamp), "Incorrect end time");
		assertTrue(epochData.isSettled, "Epoch should be settled");
		assertEq(epochData.tradingPnl, pnl, "Incorrect trading PnL");
		assertGt(epochData.externalVaultPnl, 0, "Should have Yearn PnL");
		assertEq(epochData.currentExternalVaultDeposits, 0, "Should have no Yearn deposits");
		assertEq(epochData.currentUnutilizedAsset, 0, "Should have zero unutilized assets");
		assertGt(
			epochData.finalVaultAssets,
			epochData.initialVaultAssets,
			"Final assets should be greater than initial"
		);
	}

	function test_borrow_withHighDeposits() public {
		vm.startPrank(user1);
		uint256 totalAssetsBefore = vault.totalAssets();
		uint256 depositAmount = vault.externalVault().maxDeposit(address(vault));
		deal(USDC, user1, depositAmount);
		vault.deposit(depositAmount, user1);
		vm.stopPrank();

		vm.prank(admin);
		vault.startNewEpoch(4e8);

		uint256 borrowAmount = 100e6;
		vm.prank(trader);
		vm.expectEmit(true, false, false, true);
		emit FundsBorrowed(trader, borrowAmount);
		vault.borrow(borrowAmount);

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertEq(epochData.fundsBorrowed, borrowAmount, "Incorrect borrowed amount");
		assertEq(
			epochData.currentUnutilizedAsset,
			totalAssetsBefore - borrowAmount,
			"Funds should be taken from unutilized first"
		);
		assertEq(epochData.currentExternalVaultDeposits, depositAmount, "Should not use yearn for borrow");

		borrowAmount = depositAmount;
		vm.prank(trader);
		vm.expectEmit(true, false, false, true);
		emit FundsBorrowed(trader, borrowAmount);
		vault.borrow(borrowAmount);

		IRfyVault.EpochData memory updatedEpochData = vault.getEpochData(vault.currentEpoch());

		assertEq(updatedEpochData.fundsBorrowed, borrowAmount + 100e6, "Incorrect borrowed amount");
		assertEq(updatedEpochData.currentUnutilizedAsset, 0, "Funds should be taken from unutilized first");
		assertLt(updatedEpochData.currentExternalVaultDeposits, depositAmount, "Should Use some amount from Yearn");
	}

	function test_withdrawRewards_success() public {
		// Deploy a mock reward token
		MockERC20 rewardToken = new MockERC20("Reward Token", "REWARD", 18);
		
		// Send some reward tokens to the vault (simulating external vault rewards)
		uint256 rewardAmount = 1000e18;
		rewardToken.mint(address(vault), rewardAmount);
		
		// Verify vault received the tokens
		assertEq(rewardToken.balanceOf(address(vault)), rewardAmount);
		
		// Admin should be able to withdraw reward tokens
		vm.startPrank(admin);
		
		// Expect the event to be emitted
		vm.expectEmit(true, true, false, true);
		emit RewardsWithdrawn(address(rewardToken), admin, rewardAmount);
		
		vault.withdrawRewards(address(rewardToken), admin);
		vm.stopPrank();
		
		// Verify tokens were transferred
		assertEq(rewardToken.balanceOf(address(vault)), 0);
		assertEq(rewardToken.balanceOf(admin), rewardAmount);
	}

	function test_withdrawRewards_onlyAdmin() public {
		// Deploy a mock reward token
		MockERC20 rewardToken = new MockERC20("Reward Token", "REWARD", 18);
		rewardToken.mint(address(vault), 1000e18);
		
		// Non-admin should not be able to withdraw rewards
		vm.startPrank(user1);
		vm.expectRevert();
		vault.withdrawRewards(address(rewardToken), user1);
		vm.stopPrank();
		
		// Trader should not be able to withdraw rewards
		vm.startPrank(trader);
		vm.expectRevert();
		vault.withdrawRewards(address(rewardToken), trader);
		vm.stopPrank();
	}

	function test_withdrawRewards_cannotWithdrawMainAsset() public {
		// Admin should not be able to withdraw the main vault asset (USDC)
		vm.startPrank(admin);
		vm.expectRevert(IRfyVault.SV_InvalidAddress.selector);
		vault.withdrawRewards(USDC, admin);
		vm.stopPrank();
	}

	function test_withdrawRewards_invalidAddress() public {
		MockERC20 rewardToken = new MockERC20("Reward Token", "REWARD", 18);
		rewardToken.mint(address(vault), 1000e18);
		
		// Should revert with zero address
		vm.startPrank(admin);
		vm.expectRevert(IRfyVault.SV_InvalidAddress.selector);
		vault.withdrawRewards(address(rewardToken), address(0));
		vm.stopPrank();
	}

	function test_withdrawRewards_noBalance() public {
		MockERC20 rewardToken = new MockERC20("Reward Token", "REWARD", 18);
		// Don't mint any tokens to the vault
		
		// Should revert when trying to withdraw with zero balance
		vm.startPrank(admin);
		vm.expectRevert(IRfyVault.SV_NoAvailableFunds.selector);
		vault.withdrawRewards(address(rewardToken), admin);
		vm.stopPrank();
	}

	// Add the event declaration for testing
	event RewardsWithdrawn(address indexed token, address indexed to, uint256 amount);
}
