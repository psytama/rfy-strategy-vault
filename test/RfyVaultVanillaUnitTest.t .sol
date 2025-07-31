// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/Test.sol";
import { RfyVault } from "../src/RfyVault.sol";

import { IRfyVault } from "../src/interfaces/IRfyVault.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract RfyVaultVanillaUnitTest is Test {
	address constant USDC = address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
	RfyVault public vault;
	IERC20 public usdc;

	address public admin = makeAddr("admin");
	address public trader = makeAddr("trader");
	address public user1 = makeAddr("user1");
	address public user2 = makeAddr("user2");
	address public user3 = makeAddr("user3");
	address public user4 = makeAddr("user4");

	uint256 public constant INITIAL_BALANCE = 1_000_000e6; // 1M USDC
	uint256 public constant DEPOSIT_AMOUNT = 1000e6; // 1000 USDC

	uint256 constant MAX_DEPOSIT = 1_000_000e6; // 1M USDC
	uint256 constant MIN_DEPOSIT = 1e6; // 1 USDC
	uint256 constant MAX_BORROW = 900_000e6; // 900k USDC
	int256 constant MAX_PNL = 100_000e6; // 100k USDC
	int256 constant MIN_PNL = -100_000e6; // -100k USDC

	event EpochStarted(uint256 indexed epochId, uint256 timestamp);
	event EpochEnded(uint256 indexed epochId, uint256 timestamp);
	event FundsBorrowed(address indexed trader, uint256 amount);
	event FundsSettled(address indexed trader, uint256 borrowed, int256 pnl);
	event DepositsStatusUpdated(bool paused);
	event WithdrawalsStatusUpdated(bool paused);
	event EpochDurationUpdated(uint256 newDuration);
	event DepositWithdrawalPaused();
	event DepositWithdrawalUnpaused();

	function setUp() public virtual {
		vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), 304945980);
		usdc = IERC20(USDC);
		vm.makePersistent(address(usdc));

		// Deploy vault
		vault = new RfyVault();

		vault.initialize("Rfy Vault Token", "RFY", "TEST", address(usdc), admin, trader, address(0), 30 days, 1_000_000e6);

		assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin));
		assertTrue(vault.hasRole(vault.TRADER_ROLE(), trader));

		// Deal USDC to users
		deal(USDC, user1, INITIAL_BALANCE);
		deal(USDC, user2, INITIAL_BALANCE);
		deal(USDC, user3, INITIAL_BALANCE);
		deal(USDC, user4, INITIAL_BALANCE);
		deal(USDC, trader, INITIAL_BALANCE);

		// Approve and deposit vault for all users
		vm.startPrank(user1);
		usdc.approve(address(vault), type(uint256).max);
		vault.deposit(DEPOSIT_AMOUNT, user1);
		vm.stopPrank();

		vm.startPrank(user2);
		usdc.approve(address(vault), type(uint256).max);
		vault.deposit(DEPOSIT_AMOUNT, user2);
		vm.stopPrank();

		vm.startPrank(user3);
		usdc.approve(address(vault), type(uint256).max);
		vault.deposit(DEPOSIT_AMOUNT, user3);
		vm.stopPrank();

		vm.startPrank(user4);
		usdc.approve(address(vault), type(uint256).max);
		vault.deposit(DEPOSIT_AMOUNT, user4);
		vm.stopPrank();

		vm.startPrank(trader);
		usdc.approve(address(vault), type(uint256).max);
		vm.stopPrank();
	}

	function test_initialization() public view {
		assertEq(address(vault.asset()), USDC);
		assertEq(vault.name(), "Rfy Vault Token");
		assertEq(vault.symbol(), "RFY");
		assertEq(vault.decimals(), 6);
		assertEq(vault.epochDuration(), 30 days);
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
		vault.startNewEpoch();
		assertTrue(vault.depositsPaused(), "Deposits should be paused");
		assertTrue(vault.withdrawalsPaused(), "Withdrawals should be paused");
		assertEq(vault.currentEpoch(), 1, "Incorrect epoch number");

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertEq(uint256(epochData.startTime), block.timestamp, "Incorrect start time");
		assertEq(epochData.endTime, 0, "End time should be 0");
		assertFalse(epochData.isSettled, "Should not be settled");
		assertTrue(epochData.isEpochActive, "Epoch should be active");
		assertEq(epochData.initialVaultAssets, initialTotalAssets, "Incorrect initial assets");
		assertEq(epochData.initialExternalVaultDeposits, 0, "Zero deposits into external vault (not set)");
		assertEq(
			epochData.initialUnutilizedAsset,
			initialTotalAssets,
			"Should have initial unutilized assets (no external vault)"
		);
		assertEq(epochData.currentExternalVaultDeposits, 0, "Zero deposits into external vault (not set)");
		assertEq(
			epochData.currentUnutilizedAsset,
			initialTotalAssets,
			"Should have unutilized assets (no external vault)"
		);
		assertEq(epochData.fundsBorrowed, 0, "Should have no borrowed funds");
		assertEq(epochData.finalVaultAssets, 0, "Should have no final assets");
		assertEq(epochData.externalVaultPnl, 0, "Should have no external vault PnL");
		assertEq(epochData.tradingPnl, 0, "Should have no trading PnL");
	}

	function test_startNewEpoch_whenActive() public {
		vm.prank(admin);
		vault.startNewEpoch();

		vm.prank(admin);
		vm.expectRevert(IRfyVault.SV_EpochActive.selector);
		vault.startNewEpoch();
	}

	function test_deposit_whenEpochActive() public {
		vm.prank(admin);
		vault.startNewEpoch();

		vm.startPrank(user1);
		vm.expectRevert(IRfyVault.SV_DepositsArePaused.selector);
		vault.deposit(100e6, user1);
		vm.stopPrank();
	}

	function test_startNewEpoch_withHighDeposits() public {
		vm.startPrank(user1);
		uint256 totalAssetsBefore = vault.totalAssets();
		uint256 depositAmount = 5000e6;

		deal(USDC, user1, depositAmount);
		vault.deposit(depositAmount, user1);
		vm.stopPrank();

		uint256 initialTotalAssets = vault.totalAssets();

		vm.prank(admin);
		vm.expectEmit(true, false, false, true);
		emit EpochStarted(1, block.timestamp);
		vault.startNewEpoch();
		assertTrue(vault.depositsPaused(), "Deposits should be paused");
		assertTrue(vault.withdrawalsPaused(), "Withdrawals should be paused");
		assertEq(vault.currentEpoch(), 1, "Incorrect epoch number");

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertTrue(epochData.isEpochActive, "Epoch should be active");
		assertEq(epochData.initialVaultAssets, initialTotalAssets, "Incorrect initial assets");
		assertEq(epochData.initialExternalVaultDeposits, 0, "External vault should not have initial deposits");
		assertEq(
			epochData.initialUnutilizedAsset,
			totalAssetsBefore + depositAmount,
			"Should update unutilized assets"
		);
		assertEq(epochData.currentExternalVaultDeposits, 0, "External vault should not have deposits");

		assertEq(epochData.currentUnutilizedAsset, totalAssetsBefore + depositAmount, "Should have unutilized assets");
		assertEq(epochData.fundsBorrowed, 0, "Should have no borrowed funds");
		assertEq(epochData.finalVaultAssets, 0, "Should have no final assets");
		assertEq(epochData.externalVaultPnl, 0, "Should have no external vault PnL");
		assertEq(epochData.tradingPnl, 0, "Should have no trading PnL");
	}

	function test_withdraw_whenEpochActive() public {
		vm.prank(admin);
		vault.startNewEpoch();

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
		vault.startNewEpoch();
		vm.stopPrank();
	}

	function test_borrow() public {
		vm.prank(admin);
		vault.startNewEpoch();

		uint256 borrowAmount = 100e6;
		vm.prank(trader);
		vm.expectEmit(true, false, false, true);
		emit FundsBorrowed(trader, borrowAmount);
		vault.borrow(borrowAmount);

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertEq(epochData.fundsBorrowed, borrowAmount, "Incorrect borrowed amount");
		assertEq(epochData.currentUnutilizedAsset, 3900e6, "Should have no unutilized assets");
		assertEq(epochData.currentExternalVaultDeposits, 0, "Should have no external vault deposits");
	}

	function test_borrow_noEpoch() public {
		vm.prank(trader);
		vm.expectRevert(IRfyVault.SV_EpochNotActive.selector);
		vault.borrow(100e6);
	}

	function test_borrow_zeroAmount() public {
		vm.prank(admin);
		vault.startNewEpoch();

		vm.prank(trader);
		vm.expectRevert(IRfyVault.SV_InvalidAmount.selector);
		vault.borrow(0);
	}

	function test_settle() public {
		vm.prank(admin);
		vault.startNewEpoch();

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
		assertEq(epochData.externalVaultPnl, 0, "Should not have external vault PnL");
		assertEq(epochData.currentExternalVaultDeposits, 0, "Should have no external vault deposits");
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
		vault.startNewEpoch();

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
		vault.startNewEpoch();

		vm.startPrank(user1);

		vm.expectRevert();
		vault.borrow(100e6);

		vm.expectRevert();
		vault.settle(10e6);

		vm.stopPrank();
	}

	function test_settle_withNegativePnL() public {
		vm.prank(admin);
		vault.startNewEpoch();

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
		assertEq(epochData.externalVaultPnl, 0, "Should not have external vault PnL");
		assertEq(epochData.currentExternalVaultDeposits, 0, "Should have no external vault deposits");
		assertEq(epochData.currentUnutilizedAsset, 0, "Should have zero unutilized assets");
		assertLt(epochData.finalVaultAssets, epochData.initialVaultAssets, "Final assets should be less than initial");
	}

	function test_settle_ZeroBorrow() public {
		vm.prank(admin);
		vault.startNewEpoch();

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
		assertEq(epochData.externalVaultPnl, 0, "Should not have external vault Pnl");
		assertEq(epochData.currentExternalVaultDeposits, 0, "Should have no external vault deposits");
		assertEq(epochData.currentUnutilizedAsset, 0, "Should have zero unutilized assets");
		assertEq(
			epochData.finalVaultAssets,
			epochData.initialVaultAssets,
			"Final assets should not change"
		);
	}

	function test_settle_withZeroPnL() public {
		vm.prank(admin);
		vault.startNewEpoch();

		uint256 borrowAmount = 100e6;
		vm.prank(trader);
		vault.borrow(borrowAmount);

		vm.warp(block.timestamp + 31 days);

		int256 pnl;
		vm.startPrank(trader);
		uint256 returnAmount = borrowAmount + uint256(pnl);
		usdc.approve(address(vault), returnAmount);

		emit log_int(pnl);

		vault.settle(pnl);
		vm.stopPrank();

		IRfyVault.EpochData memory epochData = vault.getEpochData(vault.currentEpoch());

		assertEq(epochData.endTime, uint96(block.timestamp), "Incorrect end time");
		assertTrue(epochData.isSettled, "Epoch should be settled");
		assertEq(epochData.tradingPnl, pnl, "Incorrect trading PnL");
		assertEq(epochData.externalVaultPnl, 0, "Should not have external vault PnL");
		assertEq(epochData.currentExternalVaultDeposits, 0, "Should have no external vault deposits");
		assertEq(epochData.currentUnutilizedAsset, 0, "Should have zero unutilized assets");
		assertEq(
			epochData.finalVaultAssets,
			epochData.initialVaultAssets,
			"Final assets should be same as initial (0 pnl)"
		);
	}

	function test_borrow_withHighDeposits() public {
		vm.startPrank(user1);
		uint256 depositAmount = 10_000e6;
		uint256 totalAssetsBefore = vault.totalAssets() + depositAmount;
		deal(USDC, user1, depositAmount);
		vault.deposit(depositAmount, user1);
		vm.stopPrank();

		vm.prank(admin);
		vault.startNewEpoch();

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
			"Funds should be taken from unutilized first before first borrow"
		);

		borrowAmount = depositAmount;
		vm.prank(trader);
		vm.expectEmit(true, false, false, true);
		emit FundsBorrowed(trader, borrowAmount);
		vault.borrow(borrowAmount);

		IRfyVault.EpochData memory updatedEpochData = vault.getEpochData(vault.currentEpoch());

		assertEq(updatedEpochData.fundsBorrowed, borrowAmount + 100e6, "Incorrect borrowed amount");
		assertEq(updatedEpochData.currentUnutilizedAsset, epochData.currentUnutilizedAsset - borrowAmount, "Funds should be taken from unutilized first after second borrow");
		assertLt(updatedEpochData.currentExternalVaultDeposits, depositAmount, "Should Use some amount from external vault");
	}

	function test_Unit_MaxDepositEnforcement() public {
		uint256 maxTotalDeposits = vault.maxTotalDeposits();
		uint256 currentAssets = vault.totalAssets();
		uint256 remainingCapacity = maxTotalDeposits - currentAssets;
		
		address testUser = makeAddr("testUser");
		uint256 excessiveAmount = remainingCapacity + 1e6; // 1 USDC more than capacity
		deal(USDC, testUser, excessiveAmount);
		
		vm.startPrank(testUser);
		usdc.approve(address(vault), excessiveAmount);
		
		// Should revert when trying to deposit more than remaining capacity
		vm.expectRevert();
		vault.deposit(excessiveAmount, testUser);
		vm.stopPrank();
	}

	function test_Unit_MaxDepositReturnsCorrectValue() public {
		uint256 maxTotalDeposits = vault.maxTotalDeposits();
		uint256 currentAssets = vault.totalAssets();
		uint256 expectedMaxDeposit = maxTotalDeposits - currentAssets;
		
		assertEq(vault.maxDeposit(address(0)), expectedMaxDeposit, "maxDeposit should return remaining capacity");
		
		// Test with exact remaining capacity
		address testUser = makeAddr("testUser");
		deal(USDC, testUser, expectedMaxDeposit);
		
		vm.startPrank(testUser);
		usdc.approve(address(vault), expectedMaxDeposit);
		vault.deposit(expectedMaxDeposit, testUser);
		vm.stopPrank();
		
		// Should now be at capacity
		assertEq(vault.maxDeposit(address(0)), 0, "maxDeposit should return 0 when at capacity");
		assertEq(vault.totalAssets(), maxTotalDeposits, "Should be at max capacity");
	}

	function test_Unit_MaxMintWhenAtCapacity() public {
		// Fill vault to capacity first
		uint256 maxTotalDeposits = vault.maxTotalDeposits();
		uint256 currentAssets = vault.totalAssets();
		uint256 remainingCapacity = maxTotalDeposits - currentAssets;
		
		address filler = makeAddr("filler");
		deal(USDC, filler, remainingCapacity);
		
		vm.startPrank(filler);
		usdc.approve(address(vault), remainingCapacity);
		vault.deposit(remainingCapacity, filler);
		vm.stopPrank();
		
		// Now test that maxMint returns 0
		assertEq(vault.maxMint(address(0)), 0, "maxMint should return 0 when at capacity");
		
		// Test that minting fails
		address testUser = makeAddr("testUser");
		deal(USDC, testUser, 1000e6);
		
		vm.startPrank(testUser);
		usdc.approve(address(vault), 1000e6);
		vm.expectRevert();
		vault.mint(1e6, testUser); // Try to mint 1 share
		vm.stopPrank();
	}

	function test_Unit_SetMaxTotalDepositsAuth() public {
		uint256 currentAssets = vault.totalAssets();
		uint256 newMaxDeposits = currentAssets + 100_000e6;
		
		// Test admin can set
		vm.prank(admin);
		vault.setMaxTotalDeposits(newMaxDeposits);
		assertEq(vault.maxTotalDeposits(), newMaxDeposits, "Admin should be able to set maxTotalDeposits");
		
		// Test non-admin cannot set
		address nonAdmin = makeAddr("nonAdmin");
		vm.prank(nonAdmin);
		vm.expectRevert();
		vault.setMaxTotalDeposits(newMaxDeposits + 1);
		
		// Test cannot set below current assets
		vm.prank(admin);
		vm.expectRevert(IRfyVault.SV_InvalidAmount.selector);
		vault.setMaxTotalDeposits(currentAssets - 1);
	}
}