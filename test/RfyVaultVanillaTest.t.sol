// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/Test.sol";
import { RfyVault } from "../src/RfyVault.sol";

import { IRfyVault } from "../src/interfaces/IRfyVault.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract RfyVaultVanillaTest is Test {
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

		vault.initialize("Rfy Vault Token", "RFY", "TEST",address(usdc), admin, trader, address(0), 30 days, 1_000_000e6);

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

		uint256 borrowAmount = vault.maxBorrow();

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
		vault.settle(-int256(initialVaultAssets));

		assertEq(vault.totalAssets(), 0);
		vm.stopPrank();
	}

	function test_MaxDepositEnforcement() public {
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

	function test_MaxDepositReturnsCorrectValue() public {
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

	function test_MaxMintEnforcement() public {
		uint256 maxTotalDeposits = vault.maxTotalDeposits();
		uint256 currentAssets = vault.totalAssets();
		uint256 remainingCapacity = maxTotalDeposits - currentAssets;
		
		// Calculate shares that would exceed capacity
		uint256 maxValidShares = vault.previewDeposit(remainingCapacity);
		uint256 excessiveShares = maxValidShares + 1e6; // More shares than capacity allows
		
		address testUser = makeAddr("testUser");
		uint256 assetsNeeded = vault.previewMint(excessiveShares);
		deal(USDC, testUser, assetsNeeded);
		
		vm.startPrank(testUser);
		usdc.approve(address(vault), assetsNeeded);
		
		// Should revert when trying to mint more shares than capacity allows
		vm.expectRevert();
		vault.mint(excessiveShares, testUser);
		vm.stopPrank();
	}

	function test_MaxMintReturnsCorrectValue() public {
		uint256 maxTotalDeposits = vault.maxTotalDeposits();
		uint256 currentAssets = vault.totalAssets();
		uint256 remainingCapacity = maxTotalDeposits - currentAssets;
		uint256 expectedMaxShares = vault.previewDeposit(remainingCapacity);
		
		assertEq(vault.maxMint(address(0)), expectedMaxShares, "maxMint should return max shares for remaining capacity");
		
		// Test with exact max shares
		address testUser = makeAddr("testUser");
		uint256 assetsNeeded = vault.previewMint(expectedMaxShares);
		deal(USDC, testUser, assetsNeeded);
		
		vm.startPrank(testUser);
		usdc.approve(address(vault), assetsNeeded);
		vault.mint(expectedMaxShares, testUser);
		vm.stopPrank();
		
		// Should now be at capacity
		assertEq(vault.maxMint(address(0)), 0, "maxMint should return 0 when at capacity");
	}

	function test_SetMaxTotalDeposits() public {
		uint256 currentAssets = vault.totalAssets();
		uint256 newMaxDeposits = currentAssets + 500_000e6; // 500k USDC more than current
		
		vm.prank(admin);
		vault.setMaxTotalDeposits(newMaxDeposits);
		
		assertEq(vault.maxTotalDeposits(), newMaxDeposits, "maxTotalDeposits should be updated");
		assertEq(vault.maxDeposit(address(0)), 500_000e6, "maxDeposit should reflect new capacity");
		
		// Test that non-admin cannot set max deposits
		address nonAdmin = makeAddr("nonAdmin");
		vm.prank(nonAdmin);
		vm.expectRevert();
		vault.setMaxTotalDeposits(newMaxDeposits + 1);
		
		// Test that cannot set below current assets
		vm.prank(admin);
		vm.expectRevert(IRfyVault.SV_InvalidAmount.selector);
		vault.setMaxTotalDeposits(currentAssets - 1);
	}
}
