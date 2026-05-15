// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { RfyVault } from "../src/RfyVault.sol";
import { RfyVaultManager } from "../src/RfyVaultManager.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";
import { IRfyVaultManager } from "../src/interfaces/IRfyVaultManager.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/**
 * @title RfyVaultManagerTest
 * @notice Comprehensive test suite for RfyVaultManager covering:
 *   - Vault registration
 *   - Queue deposit / cancel deposit / processDeposits / claimShares
 *   - Queue withdrawal / cancel withdrawal / processWithdrawals / claimAssets
 *   - Pro-rata accounting with multiple users
 *   - Multi-round lifecycle
 *   - Full end-to-end epoch flow
 *   - View helpers
 *   - Fuzz tests
 *   - All revert conditions
 *
 * Uses a local vanilla RfyVault (no fork, no external vault) for speed.
 */
contract RfyVaultManagerTest is Test {
    /*//////////////////////////////////////////////////////////////
                            TEST SETUP
    //////////////////////////////////////////////////////////////*/

    MockERC20 public asset;
    RfyVault public vault;
    RfyVaultManager public manager;

    address public owner = makeAddr("owner");   // manager owner
    address public admin = makeAddr("admin");   // vault admin
    address public trader = makeAddr("trader"); // vault trader

    address public alice = makeAddr("alice");
    address public bob   = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public dan   = makeAddr("dan");
    address public random = makeAddr("random"); // for trustless-call tests

    uint256 public constant INITIAL_BALANCE = 1_000_000e6; // 1M tokens (6 decimals)
    uint256 public constant DEPOSIT_AMOUNT  = 1_000e6;     // 1,000 tokens
    uint256 public constant EPOCH_DURATION  = 30 days;
    uint256 public constant MAX_DEPOSITS    = 10_000_000e6;

    function setUp() public {
        // Deploy mock asset (6 decimals like USDC)
        asset = new MockERC20("Mock USDC", "mUSDC", 6);

        // Deploy vault (no external vault)
        vault = new RfyVault();
        vault.initialize(
            "RFY Vault Token",
            "RFY",
            "",
            address(asset),
            admin,
            trader,
            address(0), // no external vault
            EPOCH_DURATION,
            MAX_DEPOSITS
        );

        // Deploy manager
        manager = new RfyVaultManager(owner);

        // Register vault
        vm.prank(owner);
        manager.registerVault(address(vault));

        // Mint assets to users and give infinite approval to manager
        address[4] memory users = [alice, bob, carol, dan];
        for (uint256 i = 0; i < users.length; i++) {
            asset.mint(users[i], INITIAL_BALANCE);
            vm.prank(users[i]);
            asset.approve(address(manager), type(uint256).max);
        }
    }

    /*//////////////////////////////////////////////////////////////
                       HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Run a full epoch cycle so vault is in a post-settle state
    ///      (withdrawalsPaused=false, depositsPaused=true)
    function _runFullEpoch() internal {
        // Need assets in vault first; deposit directly from admin
        asset.mint(admin, 1e6);
        vm.startPrank(admin);
        asset.approve(address(vault), 1e6);
        vault.deposit(1e6, admin);
        vault.startNewEpoch(0);
        vm.stopPrank();

        // Warp past epoch
        vm.warp(block.timestamp + EPOCH_DURATION + 1);

        // Trader settles with zero PnL
        asset.mint(trader, 1e6);
        vm.startPrank(trader);
        asset.approve(address(vault), type(uint256).max);
        vault.settle(0);
        vm.stopPrank();
    }

    /// @dev Open vault deposits: requires no active epoch.
    function _openDeposits() internal {
        vm.prank(admin);
        vault.setDepositsPaused(false);
    }

    /// @dev Open vault withdrawals for direct testing without a full epoch.
    function _openWithdrawals() internal {
        vm.prank(admin);
        vault.setWithdrawalsPaused(false);
    }

    /*//////////////////////////////////////////////////////////////
                      VAULT REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_registerVault_success() public view {
        assertTrue(manager.registeredVaults(address(vault)));
    }

    function test_registerVault_emitsEvent() public {
        RfyVault vault2 = new RfyVault();
        vault2.initialize("V2", "V2", "", address(asset), admin, trader, address(0), 7 days, MAX_DEPOSITS);

        vm.expectEmit(true, false, false, false);
        emit IRfyVaultManager.VaultRegistered(address(vault2));
        vm.prank(owner);
        manager.registerVault(address(vault2));
    }

    function test_registerVault_revert_notOwner() public {
        RfyVault vault2 = new RfyVault();
        vault2.initialize("V2", "V2", "", address(asset), admin, trader, address(0), 7 days, MAX_DEPOSITS);

        vm.prank(alice);
        vm.expectRevert();
        manager.registerVault(address(vault2));
    }

    function test_registerVault_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAddress.selector);
        manager.registerVault(address(0));
    }

    function test_registerVault_revert_alreadyRegistered() public {
        vm.prank(owner);
        vm.expectRevert(IRfyVaultManager.VM_VaultAlreadyRegistered.selector);
        manager.registerVault(address(vault));
    }

    /*//////////////////////////////////////////////////////////////
                         QUEUE DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_queueDeposit_pullsAssets() public {
        uint256 amount = 500e6;
        uint256 aliceBefore = asset.balanceOf(alice);

        vm.prank(alice);
        manager.queueDeposit(address(vault), amount);

        assertEq(asset.balanceOf(alice), aliceBefore - amount, "Assets not pulled from user");
        assertEq(asset.balanceOf(address(manager)), amount, "Assets not held in manager");
    }

    function test_queueDeposit_storesRoundData() public {
        uint256 amount = 500e6;

        vm.prank(alice);
        manager.queueDeposit(address(vault), amount);

        (IRfyVaultManager.DepositRound memory dr) = _getDepositRound(0);
        assertEq(dr.totalAssets, amount);
        assertFalse(dr.processed);
        assertEq(manager.userDepositAmounts(address(vault), alice, 0), amount);
    }

    function test_queueDeposit_accumulates() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 300e6);

        vm.prank(alice);
        manager.queueDeposit(address(vault), 200e6);

        assertEq(manager.userDepositAmounts(address(vault), alice, 0), 500e6);
        (IRfyVaultManager.DepositRound memory dr) = _getDepositRound(0);
        assertEq(dr.totalAssets, 500e6);
    }

    function test_queueDeposit_multipleUsers_sameRound() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 300e6);
        vm.prank(bob);
        manager.queueDeposit(address(vault), 700e6);

        (IRfyVaultManager.DepositRound memory dr) = _getDepositRound(0);
        assertEq(dr.totalAssets, 1_000e6);
        assertEq(manager.userDepositAmounts(address(vault), alice, 0), 300e6);
        assertEq(manager.userDepositAmounts(address(vault), bob, 0), 700e6);
    }

    function test_queueDeposit_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IRfyVaultManager.DepositQueued(address(vault), alice, 0, 500e6);
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);
    }

    function test_queueDeposit_worksWhileVaultPaused() public {
        // Queue BEFORE pausing (epoch not yet started)
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        // Now start epoch (pauses deposits in vault)
        asset.mint(admin, 1e6);
        vm.startPrank(admin);
        asset.approve(address(vault), 1e6);
        vault.deposit(1e6, admin);
        vault.startNewEpoch(0);
        vm.stopPrank();

        assertTrue(vault.depositsPaused(), "Vault deposits should be paused");

        // Additional queue AFTER vault paused — still works (assets sit in manager now)
        vm.prank(bob);
        manager.queueDeposit(address(vault), 200e6);

        assertEq(manager.userDepositAmounts(address(vault), bob, 0), 200e6);
    }

    function test_queueDeposit_revert_zero() public {
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAmount.selector);
        manager.queueDeposit(address(vault), 0);
    }

    function test_queueDeposit_revert_unregisteredVault() public {
        address fakeVault = makeAddr("fakeVault");
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_VaultNotRegistered.selector);
        manager.queueDeposit(fakeVault, 500e6);
    }

    /*//////////////////////////////////////////////////////////////
                        CANCEL DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_cancelDeposit_full() public {
        uint256 amount = 500e6;
        vm.prank(alice);
        manager.queueDeposit(address(vault), amount);

        uint256 balanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        manager.cancelDeposit(address(vault), 0, amount);

        assertEq(asset.balanceOf(alice), balanceBefore + amount, "Assets not returned");
        assertEq(manager.userDepositAmounts(address(vault), alice, 0), 0);
        (IRfyVaultManager.DepositRound memory dr) = _getDepositRound(0);
        assertEq(dr.totalAssets, 0);
    }

    function test_cancelDeposit_partial() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        uint256 balanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        manager.cancelDeposit(address(vault), 0, 200e6);

        assertEq(asset.balanceOf(alice), balanceBefore + 200e6, "Partial assets not returned");
        assertEq(manager.userDepositAmounts(address(vault), alice, 0), 300e6);
        (IRfyVaultManager.DepositRound memory dr) = _getDepositRound(0);
        assertEq(dr.totalAssets, 300e6);
    }

    function test_cancelDeposit_emitsEvent() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        vm.expectEmit(true, true, true, true);
        emit IRfyVaultManager.DepositCancelled(address(vault), alice, 0, 200e6);
        vm.prank(alice);
        manager.cancelDeposit(address(vault), 0, 200e6);
    }

    function test_cancelDeposit_revert_zero() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAmount.selector);
        manager.cancelDeposit(address(vault), 0, 0);
    }

    function test_cancelDeposit_revert_insufficientBalance() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InsufficientBalance.selector);
        manager.cancelDeposit(address(vault), 0, 600e6); // more than queued
    }

    function test_cancelDeposit_revert_roundAlreadyProcessed() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        // process the round
        manager.processDeposits(address(vault));

        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_RoundAlreadyProcessed.selector);
        manager.cancelDeposit(address(vault), 0, 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                       PROCESS DEPOSITS
    //////////////////////////////////////////////////////////////*/

    function test_processDeposits_success() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 1_000e6);

        uint256 expectedShares = vault.previewDeposit(1_000e6);
        manager.processDeposits(address(vault));

        (IRfyVaultManager.DepositRound memory dr) = _getDepositRound(0);
        assertTrue(dr.processed);
        assertEq(dr.totalAssets, 1_000e6);
        assertEq(dr.totalShares, expectedShares);
        // Vault shares now held by manager
        assertEq(IERC20(address(vault)).balanceOf(address(manager)), expectedShares);
    }

    function test_processDeposits_advancesRound() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        assertEq(manager.currentDepositRound(address(vault)), 0);
        manager.processDeposits(address(vault));
        assertEq(manager.currentDepositRound(address(vault)), 1);
    }

    function test_processDeposits_anyoneCanCall() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        // random non-owner calls it
        vm.prank(random);
        manager.processDeposits(address(vault));

        (IRfyVaultManager.DepositRound memory dr) = _getDepositRound(0);
        assertTrue(dr.processed);
    }

    function test_processDeposits_newRoundOpenImmediately() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        manager.processDeposits(address(vault));

        // Bob can queue into round 1 immediately after round 0 closes
        vm.prank(bob);
        manager.queueDeposit(address(vault), 300e6);

        assertEq(manager.userDepositAmounts(address(vault), bob, 1), 300e6);
        assertEq(manager.currentDepositRound(address(vault)), 1);
    }

    function test_processDeposits_emitsEvent() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 1_000e6);

        uint256 expectedShares = vault.previewDeposit(1_000e6);
        vm.expectEmit(true, true, false, true);
        emit IRfyVaultManager.DepositsProcessed(address(vault), 0, 1_000e6, expectedShares);
        manager.processDeposits(address(vault));
    }

    function test_processDeposits_revert_depositsPaused() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        // Start epoch to pause deposits
        asset.mint(admin, 1e6);
        vm.startPrank(admin);
        asset.approve(address(vault), 1e6);
        vault.deposit(1e6, admin);
        vault.startNewEpoch(0);
        vm.stopPrank();

        vm.expectRevert(IRfyVaultManager.VM_DepositsArePaused.selector);
        manager.processDeposits(address(vault));
    }

    function test_processDeposits_revert_nothingToProcess() public {
        vm.expectRevert(IRfyVaultManager.VM_NothingToProcess.selector);
        manager.processDeposits(address(vault));
    }

    /*//////////////////////////////////////////////////////////////
            DEPOSIT-CAP GRIEFING / PARTIAL-FILL HANDLING
            (regression: finding #56379)
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploy a small-cap vault for cap-grief tests so we don't need millions of tokens.
    function _deployCappedVault(uint256 cap) internal returns (RfyVault v) {
        v = new RfyVault();
        v.initialize(
            "Capped Vault",
            "CAP",
            "",
            address(asset),
            admin,
            trader,
            address(0),
            EPOCH_DURATION,
            cap
        );
        vm.prank(owner);
        manager.registerVault(address(v));

        // Re-approve manager from the standard test users for this new vault's asset (same asset).
        // (already approved in setUp; no-op here.)
    }

    function test_processDeposits_partialFill_whenCapInsufficient() public {
        uint256 cap = 1_000e6;
        RfyVault v = _deployCappedVault(cap);

        // Alice + Bob queue 800e6 total
        vm.prank(alice); manager.queueDeposit(address(v), 400e6);
        vm.prank(bob);   manager.queueDeposit(address(v), 400e6);

        // Attacker burns 500e6 of the cap by depositing directly (locks themselves in for the epoch)
        asset.mint(random, 500e6);
        vm.prank(random); asset.approve(address(v), type(uint256).max);
        vm.prank(random); v.deposit(500e6, random);

        assertEq(v.maxDeposit(address(manager)), 500e6, "headroom should be 500e6");

        // Process the round — must NOT revert; should partially fill.
        manager.processDeposits(address(v));

        IRfyVaultManager.DepositRound memory dr = _getDepositRoundFor(address(v), 0);
        assertTrue(dr.processed, "round must be processed");
        assertEq(dr.totalAssets, 800e6, "totalAssets unchanged");
        assertEq(dr.refundAssets, 300e6, "refundAssets = queued - headroom");
        assertGt(dr.totalShares, 0, "shares should be received for the filled portion");
        assertEq(manager.currentDepositRound(address(v)), 1, "round counter must advance");
    }

    function test_processDeposits_zeroFill_whenNoHeadroom() public {
        uint256 cap = 1_000e6;
        RfyVault v = _deployCappedVault(cap);

        // Alice + Bob queue 800e6
        vm.prank(alice); manager.queueDeposit(address(v), 400e6);
        vm.prank(bob);   manager.queueDeposit(address(v), 400e6);

        // Attacker fills the entire cap directly
        asset.mint(random, cap);
        vm.prank(random); asset.approve(address(v), type(uint256).max);
        vm.prank(random); v.deposit(cap, random);

        assertEq(v.maxDeposit(address(manager)), 0, "no headroom");

        // Process — zero shares received, full refund booked.
        manager.processDeposits(address(v));

        IRfyVaultManager.DepositRound memory dr = _getDepositRoundFor(address(v), 0);
        assertTrue(dr.processed, "round processed even with zero fill");
        assertEq(dr.totalShares, 0, "no shares received");
        assertEq(dr.refundAssets, 800e6, "everything refunded");
        assertEq(manager.currentDepositRound(address(v)), 1, "round counter advances");
    }

    function test_processDeposits_advancesRound_evenOnPartialFill() public {
        uint256 cap = 1_000e6;
        RfyVault v = _deployCappedVault(cap);

        vm.prank(alice); manager.queueDeposit(address(v), 800e6);

        asset.mint(random, 500e6);
        vm.prank(random); asset.approve(address(v), type(uint256).max);
        vm.prank(random); v.deposit(500e6, random);

        manager.processDeposits(address(v));

        // New round 1 must be open and accept fresh queues immediately.
        vm.prank(carol); manager.queueDeposit(address(v), 100e6);
        assertEq(manager.userDepositAmounts(address(v), carol, 1), 100e6);
        assertEq(manager.currentDepositRound(address(v)), 1);
    }

    function test_claimShares_partialFill_userGetsSharesAndRefund_proRata() public {
        uint256 cap = 1_000e6;
        RfyVault v = _deployCappedVault(cap);

        // Three awkward amounts to stress rounding.
        vm.prank(alice); manager.queueDeposit(address(v), 333e6);
        vm.prank(bob);   manager.queueDeposit(address(v), 334e6);
        vm.prank(carol); manager.queueDeposit(address(v), 333e6);

        // Attacker leaves only 600e6 of headroom — round (1000e6) overflows by 400e6.
        asset.mint(random, 400e6);
        vm.prank(random); asset.approve(address(v), type(uint256).max);
        vm.prank(random); v.deposit(400e6, random);
        assertEq(v.maxDeposit(address(manager)), 600e6);

        manager.processDeposits(address(v));

        IRfyVaultManager.DepositRound memory dr = _getDepositRoundFor(address(v), 0);
        assertEq(dr.refundAssets, 400e6, "refund == queued - headroom");
        assertGt(dr.totalShares, 0);

        // Snapshot per-user expected math.
        uint256 aliceExpShares = (333e6 * dr.totalShares) / dr.totalAssets;
        uint256 aliceExpRefund = (333e6 * dr.refundAssets) / dr.totalAssets;
        uint256 bobExpShares   = (334e6 * dr.totalShares) / dr.totalAssets;
        uint256 bobExpRefund   = (334e6 * dr.refundAssets) / dr.totalAssets;
        uint256 carolExpShares = (333e6 * dr.totalShares) / dr.totalAssets;
        uint256 carolExpRefund = (333e6 * dr.refundAssets) / dr.totalAssets;

        uint256 aliceAssetBefore = asset.balanceOf(alice);
        uint256 bobAssetBefore   = asset.balanceOf(bob);
        uint256 carolAssetBefore = asset.balanceOf(carol);

        vm.prank(alice); manager.claimShares(address(v), 0);
        vm.prank(bob);   manager.claimShares(address(v), 0);
        vm.prank(carol); manager.claimShares(address(v), 0);

        // Each user receives their pro-rata shares AND their pro-rata asset refund.
        assertEq(IERC20(address(v)).balanceOf(alice), aliceExpShares, "alice shares");
        assertEq(IERC20(address(v)).balanceOf(bob),   bobExpShares,   "bob shares");
        assertEq(IERC20(address(v)).balanceOf(carol), carolExpShares, "carol shares");

        assertEq(asset.balanceOf(alice) - aliceAssetBefore, aliceExpRefund, "alice refund");
        assertEq(asset.balanceOf(bob)   - bobAssetBefore,   bobExpRefund,   "bob refund");
        assertEq(asset.balanceOf(carol) - carolAssetBefore, carolExpRefund, "carol refund");

        // Sums never exceed pool totals (no over-distribution).
        uint256 sharesDistributed = IERC20(address(v)).balanceOf(alice)
            + IERC20(address(v)).balanceOf(bob)
            + IERC20(address(v)).balanceOf(carol);
        uint256 refundDistributed = (asset.balanceOf(alice) - aliceAssetBefore)
            + (asset.balanceOf(bob)   - bobAssetBefore)
            + (asset.balanceOf(carol) - carolAssetBefore);
        assertLe(sharesDistributed, dr.totalShares,  "no over-distribution of shares");
        assertLe(refundDistributed, dr.refundAssets, "no over-distribution of refund");
        assertApproxEqAbs(sharesDistributed, dr.totalShares,  3, "shares rounding bound");
        assertApproxEqAbs(refundDistributed, dr.refundAssets, 3, "refund rounding bound");
    }

    function test_griefing_attacker_cannotFreezeRound_anymore() public {
        // Direct replay of finding #56379's PoC: the round must process despite
        // the attacker shrinking headroom below the queued total.
        uint256 cap = 1_000e6;
        RfyVault v = _deployCappedVault(cap);

        vm.prank(alice); manager.queueDeposit(address(v), 400e6);
        vm.prank(bob);   manager.queueDeposit(address(v), 400e6);

        asset.mint(random, 300e6);
        vm.prank(random); asset.approve(address(v), type(uint256).max);
        vm.prank(random); v.deposit(300e6, random);
        assertEq(v.maxDeposit(address(manager)), 700e6);

        // Pre-fix this would revert. Post-fix it MUST succeed.
        manager.processDeposits(address(v));

        IRfyVaultManager.DepositRound memory dr = _getDepositRoundFor(address(v), 0);
        assertTrue(dr.processed, "round MUST process despite cap grief");
        assertEq(dr.refundAssets, 100e6, "100e6 (= 800 - 700) refunded");
        assertEq(manager.currentDepositRound(address(v)), 1, "round advanced");

        // Both victims can claim immediately — no cancel dance required.
        vm.prank(alice); manager.claimShares(address(v), 0);
        vm.prank(bob);   manager.claimShares(address(v), 0);
        assertGt(IERC20(address(v)).balanceOf(alice), 0);
        assertGt(IERC20(address(v)).balanceOf(bob),   0);
    }

    /*//////////////////////////////////////////////////////////////
                          CLAIM SHARES
    //////////////////////////////////////////////////////////////*/

    function test_claimShares_singleUser() public {
        uint256 amount = 1_000e6;
        vm.prank(alice);
        manager.queueDeposit(address(vault), amount);

        manager.processDeposits(address(vault));

        uint256 totalShares = _getDepositRound(0).totalShares;

        vm.prank(alice);
        manager.claimShares(address(vault), 0);

        assertEq(IERC20(address(vault)).balanceOf(alice), totalShares, "Alice should hold all shares");
        assertEq(manager.userDepositAmounts(address(vault), alice, 0), 0, "User deposit should be zeroed");
    }

    function test_claimShares_proRata_twoUsers() public {
        // Alice deposits 300, Bob deposits 700 → total 1000
        vm.prank(alice);
        manager.queueDeposit(address(vault), 300e6);
        vm.prank(bob);
        manager.queueDeposit(address(vault), 700e6);

        manager.processDeposits(address(vault));

        IRfyVaultManager.DepositRound memory dr = _getDepositRound(0);
        uint256 totalAssets = dr.totalAssets;
        uint256 totalShares = dr.totalShares;

        uint256 aliceExpected = (300e6 * totalShares) / totalAssets;
        uint256 bobExpected   = (700e6 * totalShares) / totalAssets;

        vm.prank(alice);
        manager.claimShares(address(vault), 0);
        vm.prank(bob);
        manager.claimShares(address(vault), 0);

        assertEq(IERC20(address(vault)).balanceOf(alice), aliceExpected, "Alice pro-rata incorrect");
        assertEq(IERC20(address(vault)).balanceOf(bob),   bobExpected,   "Bob pro-rata incorrect");
    }

    function test_claimShares_proRata_sumDoesNotExceedTotal() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 333e6);
        vm.prank(bob);
        manager.queueDeposit(address(vault), 334e6);
        vm.prank(carol);
        manager.queueDeposit(address(vault), 333e6);

        manager.processDeposits(address(vault));

        IRfyVaultManager.DepositRound memory dr = _getDepositRound(0);

        vm.prank(alice);  manager.claimShares(address(vault), 0);
        vm.prank(bob);    manager.claimShares(address(vault), 0);
        vm.prank(carol);  manager.claimShares(address(vault), 0);

        uint256 distributed = IERC20(address(vault)).balanceOf(alice)
            + IERC20(address(vault)).balanceOf(bob)
            + IERC20(address(vault)).balanceOf(carol);

        // No over-distribution (rounding down is safe)
        assertLe(distributed, dr.totalShares, "Cannot distribute more shares than received");
        // Should not lose more than 1 wei per user due to rounding
        assertApproxEqAbs(distributed, dr.totalShares, 3, "Rounding loss too large");
    }

    function test_claimShares_revert_roundNotProcessed() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_RoundNotProcessed.selector);
        manager.claimShares(address(vault), 0);
    }

    function test_claimShares_revert_nothingToClaim() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        manager.processDeposits(address(vault));

        // Bob never queued anything
        vm.prank(bob);
        vm.expectRevert(IRfyVaultManager.VM_NothingToClaim.selector);
        manager.claimShares(address(vault), 0);
    }

    function test_claimShares_revert_doubleClaim() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);
        manager.processDeposits(address(vault));

        vm.prank(alice);
        manager.claimShares(address(vault), 0);

        // Second claim should revert
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_NothingToClaim.selector);
        manager.claimShares(address(vault), 0);
    }

    function test_claimShares_emitsEvent() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 1_000e6);
        manager.processDeposits(address(vault));

        IRfyVaultManager.DepositRound memory dr = _getDepositRound(0);
        uint256 expectedShares = dr.totalShares; // 100% to alice

        vm.expectEmit(true, true, true, true);
        emit IRfyVaultManager.SharesClaimed(address(vault), alice, 0, expectedShares);
        vm.prank(alice);
        manager.claimShares(address(vault), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       QUEUE WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    function _setupAliceWithShares(uint256 depositAmount) internal returns (uint256 shares) {
        vm.prank(alice);
        manager.queueDeposit(address(vault), depositAmount);
        manager.processDeposits(address(vault));
        shares = _getDepositRound(0).totalShares;

        // Alice claims her shares
        vm.prank(alice);
        manager.claimShares(address(vault), 0);

        // Alice approves manager to pull vault shares
        vm.prank(alice);
        IERC20(address(vault)).approve(address(manager), type(uint256).max);

        // Open withdrawals so later tests with processWithdrawals can work
        _openWithdrawals();
    }

    function test_queueWithdrawal_pullsShares() public {
        uint256 shares = _setupAliceWithShares(1_000e6);

        uint256 sharesBefore = IERC20(address(vault)).balanceOf(alice);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        assertEq(IERC20(address(vault)).balanceOf(alice), sharesBefore - shares, "Shares not pulled");
        assertEq(IERC20(address(vault)).balanceOf(address(manager)), shares, "Shares not held by manager");
    }

    function test_queueWithdrawal_storesRoundData() public {
        uint256 shares = _setupAliceWithShares(1_000e6);

        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        IRfyVaultManager.WithdrawalRound memory wr = _getWithdrawalRound(0);
        assertEq(wr.totalShares, shares);
        assertFalse(wr.processed);
        assertEq(manager.userWithdrawalShares(address(vault), alice, 0), shares);
    }

    function test_queueWithdrawal_emitsEvent() public {
        uint256 shares = _setupAliceWithShares(1_000e6);

        vm.expectEmit(true, true, true, true);
        emit IRfyVaultManager.WithdrawalQueued(address(vault), alice, 0, shares);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);
    }

    function test_queueWithdrawal_revert_zero() public {
        _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAmount.selector);
        manager.queueWithdrawal(address(vault), 0);
    }

    function test_queueWithdrawal_revert_unregisteredVault() public {
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_VaultNotRegistered.selector);
        manager.queueWithdrawal(makeAddr("fake"), 1e6);
    }

    /*//////////////////////////////////////////////////////////////
                      CANCEL WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    function test_cancelWithdrawal_full() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        uint256 beforeShares = IERC20(address(vault)).balanceOf(alice);
        vm.prank(alice);
        manager.cancelWithdrawal(address(vault), 0, shares);

        assertEq(IERC20(address(vault)).balanceOf(alice), beforeShares + shares, "Shares not returned");
        assertEq(manager.userWithdrawalShares(address(vault), alice, 0), 0);
        assertEq(_getWithdrawalRound(0).totalShares, 0);
    }

    function test_cancelWithdrawal_partial() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        uint256 halfShares = shares / 2;
        vm.prank(alice);
        manager.cancelWithdrawal(address(vault), 0, halfShares);

        assertEq(manager.userWithdrawalShares(address(vault), alice, 0), shares - halfShares);
        assertEq(_getWithdrawalRound(0).totalShares, shares - halfShares);
    }

    function test_cancelWithdrawal_emitsEvent() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        vm.expectEmit(true, true, true, true);
        emit IRfyVaultManager.WithdrawalCancelled(address(vault), alice, 0, shares);
        vm.prank(alice);
        manager.cancelWithdrawal(address(vault), 0, shares);
    }

    function test_cancelWithdrawal_revert_zero() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAmount.selector);
        manager.cancelWithdrawal(address(vault), 0, 0);
    }

    function test_cancelWithdrawal_revert_insufficientBalance() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InsufficientBalance.selector);
        manager.cancelWithdrawal(address(vault), 0, shares + 1);
    }

    function test_cancelWithdrawal_revert_roundAlreadyProcessed() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        manager.processWithdrawals(address(vault));

        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_RoundAlreadyProcessed.selector);
        manager.cancelWithdrawal(address(vault), 0, 1e6);
    }

    /*//////////////////////////////////////////////////////////////
                      PROCESS WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    function test_processWithdrawals_success() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        uint256 expectedAssets = vault.previewRedeem(shares);
        manager.processWithdrawals(address(vault));

        IRfyVaultManager.WithdrawalRound memory wr = _getWithdrawalRound(0);
        assertTrue(wr.processed);
        assertEq(wr.totalShares, shares);
        assertApproxEqAbs(wr.totalAssets, expectedAssets, 1, "Assets not matching preview");
        assertEq(asset.balanceOf(address(manager)), wr.totalAssets, "Assets not held by manager");
    }

    function test_processWithdrawals_advancesRound() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        assertEq(manager.currentWithdrawalRound(address(vault)), 0);
        manager.processWithdrawals(address(vault));
        assertEq(manager.currentWithdrawalRound(address(vault)), 1);
    }

    function test_processWithdrawals_anyoneCanCall() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        vm.prank(random);
        manager.processWithdrawals(address(vault));

        assertTrue(_getWithdrawalRound(0).processed);
    }

    function test_processWithdrawals_emitsEvent() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        uint256 expectedAssets = vault.previewRedeem(shares);
        vm.expectEmit(true, true, false, true);
        emit IRfyVaultManager.WithdrawalsProcessed(address(vault), 0, shares, expectedAssets);
        manager.processWithdrawals(address(vault));
    }

    function test_processWithdrawals_revert_withdrawalsPaused() public {
        // vault.withdrawalsPaused is true by default
        uint256 shares = _setupAliceWithShares(1_000e6);
        // close withdrawals again
        vm.prank(admin);
        vault.setWithdrawalsPaused(true);

        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        vm.expectRevert(IRfyVaultManager.VM_WithdrawalsArePaused.selector);
        manager.processWithdrawals(address(vault));
    }

    function test_processWithdrawals_revert_nothingToProcess() public {
        _openWithdrawals();
        vm.expectRevert(IRfyVaultManager.VM_NothingToProcess.selector);
        manager.processWithdrawals(address(vault));
    }

    /*//////////////////////////////////////////////////////////////
                         CLAIM ASSETS
    //////////////////////////////////////////////////////////////*/

    function test_claimAssets_singleUser() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);
        manager.processWithdrawals(address(vault));

        uint256 totalAssets = _getWithdrawalRound(0).totalAssets;

        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        manager.claimAssets(address(vault), 0);

        assertEq(asset.balanceOf(alice), aliceBefore + totalAssets, "Alice should receive all assets");
        assertEq(manager.userWithdrawalShares(address(vault), alice, 0), 0, "User shares should be zeroed");
    }

    function test_claimAssets_proRata_twoUsers() public {
        // Alice and Bob both get vault shares, queue different amounts for withdrawal
        vm.prank(alice);
        manager.queueDeposit(address(vault), 300e6);
        vm.prank(bob);
        manager.queueDeposit(address(vault), 700e6);
        manager.processDeposits(address(vault));

        IRfyVaultManager.DepositRound memory dr = _getDepositRound(0);
        uint256 aliceShares = (300e6 * dr.totalShares) / dr.totalAssets;
        uint256 bobShares   = (700e6 * dr.totalShares) / dr.totalAssets;

        vm.prank(alice); manager.claimShares(address(vault), 0);
        vm.prank(bob);   manager.claimShares(address(vault), 0);

        vm.prank(alice);
        IERC20(address(vault)).approve(address(manager), type(uint256).max);
        vm.prank(bob);
        IERC20(address(vault)).approve(address(manager), type(uint256).max);

        _openWithdrawals();

        vm.prank(alice);
        manager.queueWithdrawal(address(vault), aliceShares);
        vm.prank(bob);
        manager.queueWithdrawal(address(vault), bobShares);
        manager.processWithdrawals(address(vault));

        IRfyVaultManager.WithdrawalRound memory wr = _getWithdrawalRound(0);
        uint256 aliceExpectedAssets = (aliceShares * wr.totalAssets) / wr.totalShares;
        uint256 bobExpectedAssets   = (bobShares   * wr.totalAssets) / wr.totalShares;

        uint256 aliceBefore = asset.balanceOf(alice);
        uint256 bobBefore   = asset.balanceOf(bob);

        vm.prank(alice); manager.claimAssets(address(vault), 0);
        vm.prank(bob);   manager.claimAssets(address(vault), 0);

        assertApproxEqAbs(asset.balanceOf(alice) - aliceBefore, aliceExpectedAssets, 1, "Alice assets incorrect");
        assertApproxEqAbs(asset.balanceOf(bob)   - bobBefore,   bobExpectedAssets,   1, "Bob assets incorrect");
    }

    function test_claimAssets_sumDoesNotExceedTotal() public {
        // Three users, awkward amounts to stress rounding
        vm.prank(alice);  manager.queueDeposit(address(vault), 333e6);
        vm.prank(bob);    manager.queueDeposit(address(vault), 334e6);
        vm.prank(carol);  manager.queueDeposit(address(vault), 333e6);
        manager.processDeposits(address(vault));

        IRfyVaultManager.DepositRound memory dr = _getDepositRound(0);
        uint256 aliceShares = (333e6 * dr.totalShares) / dr.totalAssets;
        uint256 bobShares   = (334e6 * dr.totalShares) / dr.totalAssets;
        uint256 carolShares = (333e6 * dr.totalShares) / dr.totalAssets;

        vm.prank(alice);  manager.claimShares(address(vault), 0);
        vm.prank(bob);    manager.claimShares(address(vault), 0);
        vm.prank(carol);  manager.claimShares(address(vault), 0);

        vm.prank(alice);  IERC20(address(vault)).approve(address(manager), type(uint256).max);
        vm.prank(bob);    IERC20(address(vault)).approve(address(manager), type(uint256).max);
        vm.prank(carol);  IERC20(address(vault)).approve(address(manager), type(uint256).max);

        _openWithdrawals();

        vm.prank(alice);  manager.queueWithdrawal(address(vault), aliceShares);
        vm.prank(bob);    manager.queueWithdrawal(address(vault), bobShares);
        vm.prank(carol);  manager.queueWithdrawal(address(vault), carolShares);
        manager.processWithdrawals(address(vault));

        IRfyVaultManager.WithdrawalRound memory wr = _getWithdrawalRound(0);
        uint256 aliceBefore = asset.balanceOf(alice);
        uint256 bobBefore   = asset.balanceOf(bob);
        uint256 carolBefore = asset.balanceOf(carol);

        vm.prank(alice);  manager.claimAssets(address(vault), 0);
        vm.prank(bob);    manager.claimAssets(address(vault), 0);
        vm.prank(carol);  manager.claimAssets(address(vault), 0);

        uint256 distributed = (asset.balanceOf(alice) - aliceBefore)
            + (asset.balanceOf(bob)   - bobBefore)
            + (asset.balanceOf(carol) - carolBefore);
        assertLe(distributed, wr.totalAssets, "Cannot distribute more assets than received");
        assertApproxEqAbs(distributed, wr.totalAssets, 3, "Rounding loss too large");
    }

    function test_claimAssets_revert_roundNotProcessed() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_RoundNotProcessed.selector);
        manager.claimAssets(address(vault), 0);
    }

    function test_claimAssets_revert_nothingToClaim() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);
        manager.processWithdrawals(address(vault));

        vm.prank(bob);
        vm.expectRevert(IRfyVaultManager.VM_NothingToClaim.selector);
        manager.claimAssets(address(vault), 0);
    }

    function test_claimAssets_revert_doubleClaim() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);
        manager.processWithdrawals(address(vault));

        vm.prank(alice);
        manager.claimAssets(address(vault), 0);

        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_NothingToClaim.selector);
        manager.claimAssets(address(vault), 0);
    }

    function test_claimAssets_emitsEvent() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);
        manager.processWithdrawals(address(vault));

        uint256 expectedAssets = _getWithdrawalRound(0).totalAssets;
        vm.expectEmit(true, true, true, true);
        emit IRfyVaultManager.AssetsClaimed(address(vault), alice, 0, expectedAssets);
        vm.prank(alice);
        manager.claimAssets(address(vault), 0);
    }

    /*//////////////////////////////////////////////////////////////
                      MULTI-ROUND LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_multiRound_depositsAcrossRounds() public {
        // Round 0
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);
        manager.processDeposits(address(vault));

        uint256 sharesRound0 = _getDepositRound(0).totalShares;

        // Round 1 (vault deposits still open)
        vm.prank(bob);
        manager.queueDeposit(address(vault), 300e6);
        manager.processDeposits(address(vault));

        uint256 sharesRound1 = _getDepositRound(1).totalShares;

        // Both rounds processed
        assertTrue(_getDepositRound(0).processed);
        assertTrue(_getDepositRound(1).processed);

        // Alice claims round 0
        vm.prank(alice);
        manager.claimShares(address(vault), 0);
        assertEq(IERC20(address(vault)).balanceOf(alice), sharesRound0);

        // Bob claims round 1
        vm.prank(bob);
        manager.claimShares(address(vault), 1);
        assertEq(IERC20(address(vault)).balanceOf(bob), sharesRound1);
    }

    function test_multiRound_userInMultipleRounds() public {
        // Alice queues in round 0
        vm.prank(alice);
        manager.queueDeposit(address(vault), 400e6);
        manager.processDeposits(address(vault));
        uint256 sharesR0 = _getDepositRound(0).totalShares;

        // Alice also queues in round 1
        vm.prank(alice);
        manager.queueDeposit(address(vault), 600e6);
        manager.processDeposits(address(vault));
        uint256 sharesR1 = _getDepositRound(1).totalShares;

        vm.prank(alice);
        manager.claimShares(address(vault), 0);
        vm.prank(alice);
        manager.claimShares(address(vault), 1);

        assertEq(IERC20(address(vault)).balanceOf(alice), sharesR0 + sharesR1);
    }

    /*//////////////////////////////////////////////////////////////
               FULL END-TO-END EPOCH FLOW
    //////////////////////////////////////////////////////////////*/

    /**
     * Full lifecycle test covering the intended usage:
     *  1. Users queue deposits while vault is open
     *  2. processDeposits → manager holds shares
     *  3. Admin starts epoch (both paused)
     *  4. Users queue more deposits (queued for next round, will be deposited after epoch)
     *  5. Epoch ends, trader settles
     *  6. withdrawalsPaused=false; users can queue withdrawals
     *  7. processWithdrawals → manager holds assets
     *  8. Admin re-opens deposits
     *  9. processDeposits for round 1 (the new queued deposits)
     * 10. Users claim everything
     */
    function test_fullEpochFlow() public {
        // ── Round 0: queue deposits before epoch ──
        vm.prank(alice);
        manager.queueDeposit(address(vault), 1_000e6);
        vm.prank(bob);
        manager.queueDeposit(address(vault), 2_000e6);

        // Process round 0 deposits (vault open)
        manager.processDeposits(address(vault));
        IRfyVaultManager.DepositRound memory dr0 = _getDepositRound(0);
        assertTrue(dr0.processed, "Round 0 should be processed");

        // Users claim their round-0 shares
        vm.prank(alice);
        manager.claimShares(address(vault), 0);
        vm.prank(bob);
        manager.claimShares(address(vault), 0);

        uint256 aliceShares = IERC20(address(vault)).balanceOf(alice);
        uint256 bobShares   = IERC20(address(vault)).balanceOf(bob);

        // ── Start epoch ──
        vm.prank(admin);
        vault.startNewEpoch(0);
        assertTrue(vault.depositsPaused(),    "Deposits should be paused");
        assertTrue(vault.withdrawalsPaused(), "Withdrawals should be paused");

        // ── Carol queues deposit for round 1 while epoch is live ──
        vm.prank(carol);
        manager.queueDeposit(address(vault), 1_500e6);
        // processDeposits should revert right now
        vm.expectRevert(IRfyVaultManager.VM_DepositsArePaused.selector);
        manager.processDeposits(address(vault));

        // ── Alice and Bob queue withdrawals (queued mid-epoch) ──
        vm.prank(alice);
        IERC20(address(vault)).approve(address(manager), type(uint256).max);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), aliceShares);

        vm.prank(bob);
        IERC20(address(vault)).approve(address(manager), type(uint256).max);
        vm.prank(bob);
        manager.queueWithdrawal(address(vault), bobShares);

        // processWithdrawals should revert while epoch active
        vm.expectRevert(IRfyVaultManager.VM_WithdrawalsArePaused.selector);
        manager.processWithdrawals(address(vault));

        // ── Epoch ends: trader settles ──
        vm.warp(block.timestamp + EPOCH_DURATION + 1);
        // Trader settles with zero PnL — fundsBorrowed is 0 so fundsToTransfer is 0
        vm.prank(trader);
        vault.settle(0);

        assertFalse(vault.withdrawalsPaused(), "Withdrawals should be open after settle");
        assertTrue(vault.depositsPaused(),     "Deposits should remain paused after settle");

        // ── Process withdrawals (epoch settled, withdrawals open) ──
        manager.processWithdrawals(address(vault));
        assertTrue(_getWithdrawalRound(0).processed);

        // ── Admin re-opens deposits ──
        vm.prank(admin);
        vault.setDepositsPaused(false);

        // ── Process Carol's queued deposit (round 1) ──
        manager.processDeposits(address(vault));
        assertTrue(_getDepositRound(1).processed);

        // ── All users claim ──
        vm.prank(alice);
        manager.claimAssets(address(vault), 0);
        vm.prank(bob);
        manager.claimAssets(address(vault), 0);
        vm.prank(carol);
        manager.claimShares(address(vault), 1);

        // Verify Alice and Bob got their assets back (epoch had 0 pnl).
        // Final balance should be ≈ INITIAL_BALANCE (deposited then got back the same amount).
        assertApproxEqAbs(
            asset.balanceOf(alice),
            INITIAL_BALANCE,
            1e6, // small tolerance for 1:1 vault
            "Alice should recover deposit"
        );
        assertApproxEqAbs(
            asset.balanceOf(bob),
            INITIAL_BALANCE,
            1e6,
            "Bob should recover deposit"
        );
        // Carol should hold vault shares
        assertGt(IERC20(address(vault)).balanceOf(carol), 0, "Carol should hold vault shares");
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_view_getClaimableShares() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 1_000e6);

        assertEq(manager.getClaimableShares(address(vault), alice, 0), 0, "Not yet processed");

        manager.processDeposits(address(vault));

        IRfyVaultManager.DepositRound memory dr = _getDepositRound(0);
        uint256 expected = dr.totalShares; // 100% alice
        assertEq(manager.getClaimableShares(address(vault), alice, 0), expected);
        assertEq(manager.getClaimableShares(address(vault), bob, 0),   0, "Bob has nothing");
    }

    function test_view_getClaimableAssets() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        assertEq(manager.getClaimableAssets(address(vault), alice, 0), 0, "Not yet processed");

        manager.processWithdrawals(address(vault));

        uint256 expected = _getWithdrawalRound(0).totalAssets;
        assertEq(manager.getClaimableAssets(address(vault), alice, 0), expected);
        assertEq(manager.getClaimableAssets(address(vault), bob, 0),   0);
    }

    function test_view_getClaimableShares_zeroAfterClaim() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 1_000e6);
        manager.processDeposits(address(vault));

        vm.prank(alice);
        manager.claimShares(address(vault), 0);

        assertEq(manager.getClaimableShares(address(vault), alice, 0), 0, "Should be 0 after claim");
    }

    function test_view_getPendingDeposit() public {
        (uint256 assets, uint256 round) = manager.getPendingDeposit(address(vault), alice);
        assertEq(assets, 0);
        assertEq(round, 0);

        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);

        (assets, round) = manager.getPendingDeposit(address(vault), alice);
        assertEq(assets, 500e6);
        assertEq(round, 0);
    }

    function test_view_getPendingWithdrawal() public {
        uint256 shares = _setupAliceWithShares(1_000e6);

        (uint256 queued, uint256 round) = manager.getPendingWithdrawal(address(vault), alice);
        assertEq(queued, 0);
        assertEq(round, 0);

        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        (queued, round) = manager.getPendingWithdrawal(address(vault), alice);
        assertEq(queued, shares);
        assertEq(round, 0);
    }

    function test_view_getUnclaimedDepositRounds_single() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);
        manager.processDeposits(address(vault));

        (uint256[] memory rounds, uint256[] memory claimable) =
            manager.getUnclaimedDepositRounds(address(vault), alice);

        assertEq(rounds.length, 1);
        assertEq(rounds[0], 0);
        assertEq(claimable[0], _getDepositRound(0).totalShares);
    }

    function test_view_getUnclaimedDepositRounds_multiRound() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 400e6);
        manager.processDeposits(address(vault));

        vm.prank(alice);
        manager.queueDeposit(address(vault), 600e6);
        manager.processDeposits(address(vault));

        (uint256[] memory rounds, uint256[] memory claimable) =
            manager.getUnclaimedDepositRounds(address(vault), alice);

        assertEq(rounds.length, 2);
        assertEq(rounds[0], 0);
        assertEq(rounds[1], 1);
        assertGt(claimable[0], 0);
        assertGt(claimable[1], 0);
    }

    function test_view_getUnclaimedDepositRounds_emptyAfterClaim() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);
        manager.processDeposits(address(vault));

        vm.prank(alice);
        manager.claimShares(address(vault), 0);

        (uint256[] memory rounds,) = manager.getUnclaimedDepositRounds(address(vault), alice);
        assertEq(rounds.length, 0);
    }

    function test_view_getUnclaimedWithdrawalRounds_single() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);
        manager.processWithdrawals(address(vault));

        (uint256[] memory rounds, uint256[] memory claimable) =
            manager.getUnclaimedWithdrawalRounds(address(vault), alice);

        assertEq(rounds.length, 1);
        assertEq(rounds[0], 0);
        assertGt(claimable[0], 0);
    }

    function test_view_getUnclaimedWithdrawalRounds_emptyAfterClaim() public {
        uint256 shares = _setupAliceWithShares(1_000e6);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);
        manager.processWithdrawals(address(vault));

        vm.prank(alice);
        manager.claimAssets(address(vault), 0);

        (uint256[] memory rounds,) = manager.getUnclaimedWithdrawalRounds(address(vault), alice);
        assertEq(rounds.length, 0);
    }

    /*//////////////////////////////////////////////////////////////
                   MULTI-VAULT ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_multiVault_isolation() public {
        // Deploy a second vault with a different asset
        MockERC20 asset2 = new MockERC20("Mock BTC", "mBTC", 8);
        RfyVault vault2 = new RfyVault();
        vault2.initialize("V2", "V2", "", address(asset2), admin, trader, address(0), 7 days, MAX_DEPOSITS);

        vm.prank(owner);
        manager.registerVault(address(vault2));

        // Fund alice with asset2
        asset2.mint(alice, 1_000e8);
        vm.prank(alice);
        asset2.approve(address(manager), type(uint256).max);

        // Queue on both vaults
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);
        vm.prank(alice);
        manager.queueDeposit(address(vault2), 100e8);

        // Rounds are independent
        assertEq(manager.currentDepositRound(address(vault)),  0);
        assertEq(manager.currentDepositRound(address(vault2)), 0);

        // Process vault1 only
        manager.processDeposits(address(vault));

        assertTrue(_getDepositRoundFor(address(vault), 0).processed,  "vault1 round 0 processed");
        assertFalse(_getDepositRoundFor(address(vault2), 0).processed, "vault2 round 0 not yet processed");

        // vault2's queue is untouched
        assertEq(manager.userDepositAmounts(address(vault2), alice, 0), 100e8);
    }

    /*//////////////////////////////////////////////////////////////
                         FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Two users deposit arbitrary amounts; verify pro-rata shares are correct and
    ///      the sum of claimed shares never exceeds the batch total.
    function testFuzz_proRataDeposit(uint128 amount1, uint128 amount2) public {
        amount1 = uint128(bound(uint256(amount1), 1e6, 500_000e6));
        amount2 = uint128(bound(uint256(amount2), 1e6, 500_000e6));

        asset.mint(alice, amount1);
        asset.mint(bob,   amount2);
        vm.prank(alice); asset.approve(address(manager), type(uint256).max);
        vm.prank(bob);   asset.approve(address(manager), type(uint256).max);

        vm.prank(alice); manager.queueDeposit(address(vault), amount1);
        vm.prank(bob);   manager.queueDeposit(address(vault), amount2);

        manager.processDeposits(address(vault));

        IRfyVaultManager.DepositRound memory dr = _getDepositRound(0);

        vm.prank(alice); manager.claimShares(address(vault), 0);
        vm.prank(bob);   manager.claimShares(address(vault), 0);

        uint256 distributed = IERC20(address(vault)).balanceOf(alice)
            + IERC20(address(vault)).balanceOf(bob);

        assertLe(distributed, dr.totalShares, "Over-distribution");
        // At most 2 wei lost due to integer division (one per user)
        assertApproxEqAbs(distributed, dr.totalShares, 2);
    }

    /// @dev Four users deposit and withdraw with arbitrary amounts; all accounting consistent.
    function testFuzz_fullRoundTrip(
        uint96 a1, uint96 a2, uint96 a3, uint96 a4
    ) public {
        a1 = uint96(bound(uint256(a1), 1e6, 100_000e6));
        a2 = uint96(bound(uint256(a2), 1e6, 100_000e6));
        a3 = uint96(bound(uint256(a3), 1e6, 100_000e6));
        a4 = uint96(bound(uint256(a4), 1e6, 100_000e6));

        address[4] memory users = [alice, bob, carol, dan];
        uint256[4] memory amounts = [uint256(a1), uint256(a2), uint256(a3), uint256(a4)];

        // Queue all deposits
        for (uint256 i = 0; i < 4; i++) {
            asset.mint(users[i], amounts[i]);
            vm.prank(users[i]);
            asset.approve(address(manager), type(uint256).max);
            vm.prank(users[i]);
            manager.queueDeposit(address(vault), amounts[i]);
        }
        manager.processDeposits(address(vault));

        IRfyVaultManager.DepositRound memory dr = _getDepositRound(0);

        // All users claim shares and approve manager for withdrawal
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(users[i]);
            manager.claimShares(address(vault), 0);
            vm.prank(users[i]);
            IERC20(address(vault)).approve(address(manager), type(uint256).max);
        }

        _openWithdrawals();

        // Queue all withdrawals
        for (uint256 i = 0; i < 4; i++) {
            uint256 sharesHeld = IERC20(address(vault)).balanceOf(users[i]);
            vm.prank(users[i]);
            manager.queueWithdrawal(address(vault), sharesHeld);
        }
        manager.processWithdrawals(address(vault));

        IRfyVaultManager.WithdrawalRound memory wr = _getWithdrawalRound(0);

        // All users claim assets
        uint256 totalReceived;
        for (uint256 i = 0; i < 4; i++) {
            uint256 before = asset.balanceOf(users[i]);
            vm.prank(users[i]);
            manager.claimAssets(address(vault), 0);
            totalReceived += asset.balanceOf(users[i]) - before;
        }

        // Total distributed ≤ totalAssets (no over-distribution)
        assertLe(totalReceived, wr.totalAssets, "Over-distribution of assets");
        // At most 4 wei lost (one per user) due to integer division
        assertApproxEqAbs(totalReceived, wr.totalAssets, 4);

        // Shares → assets round-trip is roughly lossless for a 0-pnl vault
        // Total input was sum of amounts; total output should be approx the same
        uint256 totalDeposited = uint256(a1) + uint256(a2) + uint256(a3) + uint256(a4);
        assertApproxEqAbs(totalReceived, totalDeposited, 10, "Round-trip value not preserved");
    }

    /// @dev Partial cancel accounting stays consistent under arbitrary amounts.
    function testFuzz_partialCancelAccounting(
        uint128 queueAmount,
        uint128 cancelAmount
    ) public {
        queueAmount  = uint128(bound(uint256(queueAmount),  2,    500_000e6));
        cancelAmount = uint128(bound(uint256(cancelAmount), 1, uint256(queueAmount)));

        asset.mint(alice, queueAmount);
        vm.prank(alice); asset.approve(address(manager), type(uint256).max);
        vm.prank(alice); manager.queueDeposit(address(vault), queueAmount);

        uint256 balanceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        manager.cancelDeposit(address(vault), 0, cancelAmount);

        assertEq(asset.balanceOf(alice), balanceBefore + cancelAmount, "Cancel returned wrong amount");
        assertEq(
            manager.userDepositAmounts(address(vault), alice, 0),
            uint256(queueAmount) - uint256(cancelAmount),
            "User balance after cancel incorrect"
        );
        assertEq(
            _getDepositRound(0).totalAssets,
            uint256(queueAmount) - uint256(cancelAmount),
            "Round totalAssets after cancel incorrect"
        );
    }

    /*//////////////////////////////////////////////////////////////
              INTERNAL SHARE BALANCE: claim-internal,
              consume-on-queue, and explicit withdraw
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper: get alice into a state where she has `shares` worth of vault shares
    ///      held by the manager via claimSharesInternal (post-settle, withdrawals open).
    function _aliceClaimsInternally(uint256 depositAmount) internal returns (uint256 shares) {
        vm.prank(alice);
        manager.queueDeposit(address(vault), depositAmount);
        manager.processDeposits(address(vault));
        shares = _getDepositRound(0).totalShares;

        vm.prank(alice);
        manager.claimSharesInternal(address(vault), 0);
    }

    function test_claimSharesInternal_creditsBalance_doesNotTransfer() public {
        uint256 expected = _aliceClaimsInternally(1_000e6);

        // Alice's wallet balance unchanged; manager-internal balance credited.
        assertEq(IERC20(address(vault)).balanceOf(alice), 0, "no shares in wallet");
        assertEq(manager.internalShareBalance(address(vault), alice), expected, "internal credited");
        // Manager still holds the actual ERC20 shares.
        assertEq(IERC20(address(vault)).balanceOf(address(manager)), expected, "manager holds shares");
    }

    function test_claimSharesInternal_revert_alreadyClaimed() public {
        _aliceClaimsInternally(1_000e6);
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_NothingToClaim.selector);
        manager.claimSharesInternal(address(vault), 0);
    }

    function test_claimSharesInternal_revert_roundNotProcessed() public {
        vm.prank(alice);
        manager.queueDeposit(address(vault), 1_000e6);
        // Don't process.
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_RoundNotProcessed.selector);
        manager.claimSharesInternal(address(vault), 0);
    }

    function test_claimSharesInternal_refundStillSentToWallet() public {
        // Spin up a low-cap vault so processing produces a refund.
        RfyVault v = new RfyVault();
        v.initialize("Cap", "C", "", address(asset), admin, trader, address(0), EPOCH_DURATION, 1_000e6);
        vm.prank(owner); manager.registerVault(address(v));

        // Queue 800; pre-fill 500 of cap so refund = 300.
        vm.prank(alice); manager.queueDeposit(address(v), 800e6);
        asset.mint(random, 500e6);
        vm.prank(random); asset.approve(address(v), type(uint256).max);
        vm.prank(random); v.deposit(500e6, random);
        manager.processDeposits(address(v));

        uint256 walletBefore = asset.balanceOf(alice);
        vm.prank(alice);
        manager.claimSharesInternal(address(v), 0);

        // Shares parked internally; refund (300e6) sent to wallet.
        assertGt(manager.internalShareBalance(address(v), alice), 0, "shares credited internally");
        assertEq(asset.balanceOf(alice) - walletBefore, 300e6, "refund hit wallet");
    }

    function test_withdrawInternalShares_pullsToWallet() public {
        uint256 shares = _aliceClaimsInternally(1_000e6);

        vm.prank(alice);
        manager.withdrawInternalShares(address(vault), shares);

        assertEq(IERC20(address(vault)).balanceOf(alice), shares, "wallet credited");
        assertEq(manager.internalShareBalance(address(vault), alice), 0, "internal drained");
    }

    function test_withdrawInternalShares_partial() public {
        uint256 shares = _aliceClaimsInternally(1_000e6);
        uint256 half = shares / 2;

        vm.prank(alice);
        manager.withdrawInternalShares(address(vault), half);

        assertEq(IERC20(address(vault)).balanceOf(alice), half, "half in wallet");
        assertEq(manager.internalShareBalance(address(vault), alice), shares - half, "rest still internal");
    }

    function test_withdrawInternalShares_revert_zero() public {
        _aliceClaimsInternally(1_000e6);
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAmount.selector);
        manager.withdrawInternalShares(address(vault), 0);
    }

    function test_withdrawInternalShares_revert_insufficient() public {
        uint256 shares = _aliceClaimsInternally(1_000e6);
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InsufficientInternalBalance.selector);
        manager.withdrawInternalShares(address(vault), shares + 1);
    }

    function test_queueWithdrawal_consumesInternalBalance_first_noTransferFrom() public {
        uint256 shares = _aliceClaimsInternally(1_000e6);

        // Need an active epoch open for withdraw queueing — actually queueWithdrawal works
        // anytime. Open it under post-settle conditions to keep the test simple.
        // Crucially: alice has set NO approval to manager. The transferFrom path would
        // revert; the internal-consumption path must succeed.
        assertEq(IERC20(address(vault)).allowance(alice, address(manager)), 0, "no approval");

        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        assertEq(manager.internalShareBalance(address(vault), alice), 0, "internal consumed");
        assertEq(manager.userWithdrawalShares(address(vault), alice, 0), shares, "queued");
    }

    function test_queueWithdrawal_internalShortfall_pullsFromWallet() public {
        uint256 internalShares = _aliceClaimsInternally(600e6);

        // Mint extra shares directly to alice so she has a wallet balance too.
        // Easiest: have her queue+claim a second deposit normally.
        vm.prank(alice);
        manager.queueDeposit(address(vault), 400e6);
        manager.processDeposits(address(vault));
        vm.prank(alice);
        manager.claimShares(address(vault), 1);
        uint256 walletShares = IERC20(address(vault)).balanceOf(alice);
        assertGt(walletShares, 0, "alice has wallet shares");

        // Total she wants to queue = internal + walletShares (full exit).
        uint256 want = internalShares + walletShares;

        vm.prank(alice); IERC20(address(vault)).approve(address(manager), type(uint256).max);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), want);

        assertEq(manager.internalShareBalance(address(vault), alice), 0, "internal fully consumed");
        assertEq(IERC20(address(vault)).balanceOf(alice), 0, "wallet fully drained");
        assertEq(manager.userWithdrawalShares(address(vault), alice, 0), want, "full amount queued");
    }

    function test_queueWithdrawal_walletOnly_unchangedBehaviour() public {
        // No internal balance at all — must behave exactly as before (pulls full amount).
        vm.prank(alice);
        manager.queueDeposit(address(vault), 1_000e6);
        manager.processDeposits(address(vault));
        vm.prank(alice);
        manager.claimShares(address(vault), 0);

        uint256 shares = IERC20(address(vault)).balanceOf(alice);
        vm.prank(alice); IERC20(address(vault)).approve(address(manager), type(uint256).max);
        vm.prank(alice);
        manager.queueWithdrawal(address(vault), shares);

        assertEq(IERC20(address(vault)).balanceOf(alice), 0);
        assertEq(manager.userWithdrawalShares(address(vault), alice, 0), shares);
    }

    function test_internalBalance_isolated_perVault_perUser() public {
        _aliceClaimsInternally(1_000e6);
        // Bob has no internal balance for this vault.
        assertEq(manager.internalShareBalance(address(vault), bob), 0, "bob isolated");

        // Spin up a second vault and confirm alice's balance there is also 0.
        RfyVault v2 = new RfyVault();
        v2.initialize("V2", "V2", "", address(asset), admin, trader, address(0), EPOCH_DURATION, MAX_DEPOSITS);
        vm.prank(owner); manager.registerVault(address(v2));
        assertEq(manager.internalShareBalance(address(v2), alice), 0, "vault-isolated");
    }

    /*//////////////////////////////////////////////////////////////
              DIRECT (UNPAUSED) DEPOSIT / WITHDRAW
              + emergency rescue + vault registry
    //////////////////////////////////////////////////////////////*/

    function _ensureUnpaused() internal {
        // Vaults are deployed with deposits unpaused but withdrawals paused. Open both.
        vm.prank(admin);
        vault.unpauseAll();
    }

    function test_registry_pushesAndExposesAllVaults() public {
        // setUp registered `vault` already.
        assertEq(manager.vaultsLength(), 1, "len after setup");
        assertEq(manager.allVaults(0), address(vault), "first slot");

        RfyVault v2 = new RfyVault();
        v2.initialize("V2", "V2", "", address(asset), admin, trader, address(0), EPOCH_DURATION, MAX_DEPOSITS);
        vm.prank(owner); manager.registerVault(address(v2));
        assertEq(manager.vaultsLength(), 2, "len after second");
        assertEq(manager.allVaults(1), address(v2), "second slot");
    }

    function test_emergencyWithdraw_pullsTokens() public {
        // Park some asset in the manager via a queued (unprocessed) deposit.
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);
        assertEq(asset.balanceOf(address(manager)), 500e6, "manager has assets");

        address rescue = makeAddr("rescue");
        vm.prank(owner);
        manager.emergencyWithdraw(address(asset), rescue, 200e6);

        assertEq(asset.balanceOf(rescue), 200e6, "rescue received");
        assertEq(asset.balanceOf(address(manager)), 300e6, "remainder still in manager");
    }

    function test_emergencyWithdraw_revert_notOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        manager.emergencyWithdraw(address(asset), alice, 1);
    }

    function test_emergencyWithdraw_revert_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAddress.selector);
        manager.emergencyWithdraw(address(0), owner, 1);

        vm.prank(owner);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAddress.selector);
        manager.emergencyWithdraw(address(asset), address(0), 1);
    }

    function test_emergencyWithdraw_revert_zeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAmount.selector);
        manager.emergencyWithdraw(address(asset), owner, 0);
    }

    function test_depositToVault_creditsInternalShareBalance() public {
        _ensureUnpaused();
        uint256 amount = 1_000e6;

        vm.prank(alice);
        manager.depositToVault(address(vault), amount);

        // Shares parked internally; alice wallet untouched (apart from asset spent).
        uint256 internalBal = manager.internalShareBalance(address(vault), alice);
        assertGt(internalBal, 0, "shares credited");
        assertEq(IERC20(address(vault)).balanceOf(alice), 0, "no shares in wallet");
        assertEq(IERC20(address(vault)).balanceOf(address(manager)), internalBal, "manager holds shares");
    }

    function test_depositToVault_revert_paused() public {
        // Default state: deposits paused (vault constructor sets depositsPaused = false but
        // withdrawalsPaused = true — so we have to explicitly pause deposits).
        vm.prank(admin); vault.setDepositsPaused(true);
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_DepositsArePaused.selector);
        manager.depositToVault(address(vault), 100e6);
    }

    function test_depositToVault_revert_unregistered() public {
        address fake = makeAddr("fake");
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_VaultNotRegistered.selector);
        manager.depositToVault(fake, 100e6);
    }

    function test_depositToVault_revert_zero() public {
        _ensureUnpaused();
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAmount.selector);
        manager.depositToVault(address(vault), 0);
    }

    function test_deposit_multiVault_routesEachAmount() public {
        _ensureUnpaused();
        // Register a second vault and unpause it.
        RfyVault v2 = new RfyVault();
        v2.initialize("V2", "V2", "", address(asset), admin, trader, address(0), EPOCH_DURATION, MAX_DEPOSITS);
        vm.prank(owner); manager.registerVault(address(v2));
        vm.prank(admin); v2.unpauseAll();

        address[] memory vaults = new address[](2);
        vaults[0] = address(vault); vaults[1] = address(v2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 600e6; amounts[1] = 400e6;

        vm.prank(alice);
        manager.deposit(vaults, amounts);

        assertGt(manager.internalShareBalance(address(vault), alice), 0, "v1 credited");
        assertGt(manager.internalShareBalance(address(v2), alice), 0, "v2 credited");
    }

    function test_deposit_multiVault_revert_lengthMismatch() public {
        _ensureUnpaused();
        address[] memory vaults = new address[](2);
        vaults[0] = address(vault); vaults[1] = address(vault);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_LengthMismatch.selector);
        manager.deposit(vaults, amounts);
    }

    function test_deposit_multiVault_revert_emptyInput() public {
        address[] memory vaults = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_EmptyInput.selector);
        manager.deposit(vaults, amounts);
    }

    function test_deposit_multiVault_revert_anyPaused() public {
        // First vault unpaused, second deliberately paused.
        _ensureUnpaused();
        RfyVault v2 = new RfyVault();
        v2.initialize("V2", "V2", "", address(asset), admin, trader, address(0), EPOCH_DURATION, MAX_DEPOSITS);
        vm.prank(owner); manager.registerVault(address(v2));
        vm.prank(admin); v2.setDepositsPaused(true);

        address[] memory vaults = new address[](2);
        vaults[0] = address(vault); vaults[1] = address(v2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e6; amounts[1] = 100e6;

        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_DepositsArePaused.selector);
        manager.deposit(vaults, amounts);
    }

    function test_withdrawFromVault_consumesInternalFirst_creditsAssetBalance() public {
        _ensureUnpaused();
        // Deposit so alice has internal shares.
        vm.prank(alice);
        manager.depositToVault(address(vault), 1_000e6);
        uint256 shares = manager.internalShareBalance(address(vault), alice);
        assertGt(shares, 0);

        // No approval needed since shares come from internal.
        vm.prank(alice);
        manager.withdrawFromVault(address(vault), shares);

        assertEq(manager.internalShareBalance(address(vault), alice), 0, "internal shares drained");
        uint256 internalAssets = manager.internalAssetBalance(address(asset), alice);
        assertGt(internalAssets, 0, "assets credited");
        // Assets remain in the manager (parked); user's wallet NOT credited.
        assertEq(asset.balanceOf(address(manager)), internalAssets, "manager holds assets");
    }

    function test_withdrawFromVault_pullsShortfallFromWallet() public {
        _ensureUnpaused();
        // 1) Get internal shares for alice (300e6 worth).
        vm.prank(alice);
        manager.depositToVault(address(vault), 300e6);
        uint256 internalShares = manager.internalShareBalance(address(vault), alice);

        // 2) Give alice wallet shares too (direct vault deposit).
        vm.prank(alice); asset.approve(address(vault), type(uint256).max);
        vm.prank(alice); vault.deposit(700e6, alice);
        uint256 walletShares = IERC20(address(vault)).balanceOf(alice);
        assertGt(walletShares, 0);

        uint256 want = internalShares + walletShares;
        vm.prank(alice); IERC20(address(vault)).approve(address(manager), type(uint256).max);

        vm.prank(alice);
        manager.withdrawFromVault(address(vault), want);

        assertEq(manager.internalShareBalance(address(vault), alice), 0, "internal drained");
        assertEq(IERC20(address(vault)).balanceOf(alice), 0, "wallet drained");
        assertGt(manager.internalAssetBalance(address(asset), alice), 0, "asset credited");
    }

    function test_withdrawFromVault_revert_paused() public {
        // Withdrawals paused by default after init.
        assertTrue(vault.withdrawalsPaused(), "precondition");
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_WithdrawalsArePaused.selector);
        manager.withdrawFromVault(address(vault), 1);
    }

    function test_withdraw_multiVault_routesEachShares() public {
        _ensureUnpaused();
        RfyVault v2 = new RfyVault();
        v2.initialize("V2", "V2", "", address(asset), admin, trader, address(0), EPOCH_DURATION, MAX_DEPOSITS);
        vm.prank(owner); manager.registerVault(address(v2));
        vm.prank(admin); v2.unpauseAll();

        // Build internal balances on both.
        vm.prank(alice); manager.depositToVault(address(vault), 500e6);
        vm.prank(alice); manager.depositToVault(address(v2),    500e6);
        uint256 s1 = manager.internalShareBalance(address(vault), alice);
        uint256 s2 = manager.internalShareBalance(address(v2),    alice);

        address[] memory vaults = new address[](2);
        vaults[0] = address(vault); vaults[1] = address(v2);
        uint256[] memory shares = new uint256[](2);
        shares[0] = s1; shares[1] = s2;

        vm.prank(alice);
        manager.withdraw(vaults, shares);

        // Internal-asset balance is keyed by asset, and both vaults share `asset` →
        // alice's single consolidated balance reflects both redeems.
        assertEq(manager.internalShareBalance(address(vault), alice), 0);
        assertEq(manager.internalShareBalance(address(v2), alice), 0);
        assertGt(manager.internalAssetBalance(address(asset), alice), 0);
    }

    function test_withdrawInternalAssets_pullsToWallet() public {
        _ensureUnpaused();
        vm.prank(alice); manager.depositToVault(address(vault), 1_000e6);
        uint256 shares = manager.internalShareBalance(address(vault), alice);
        vm.prank(alice); manager.withdrawFromVault(address(vault), shares);
        uint256 owed = manager.internalAssetBalance(address(asset), alice);
        assertGt(owed, 0);

        uint256 walletBefore = asset.balanceOf(alice);
        vm.prank(alice);
        manager.withdrawInternalAssets(address(asset), owed);

        assertEq(asset.balanceOf(alice) - walletBefore, owed, "wallet credited");
        assertEq(manager.internalAssetBalance(address(asset), alice), 0, "internal drained");
    }

    function test_withdrawInternalAssets_revert_zero() public {
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAmount.selector);
        manager.withdrawInternalAssets(address(asset), 0);
    }

    function test_withdrawInternalAssets_revert_insufficient() public {
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InsufficientInternalAssetBalance.selector);
        manager.withdrawInternalAssets(address(asset), 1);
    }

    function test_withdrawInternalAssets_revert_zeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(IRfyVaultManager.VM_InvalidAddress.selector);
        manager.withdrawInternalAssets(address(0), 1);
    }

    /*//////////////////////////////////////////////////////////////
              DEPOSIT PATHS CONSUME internalAssetBalance FIRST
    //////////////////////////////////////////////////////////////*/

    /// @dev Helper: get alice an internal-asset balance of `amount` by routing a
    ///      direct deposit + immediate direct withdraw through the manager.
    function _aliceParkAssetsInternally(uint256 amount) internal returns (uint256 parked) {
        _ensureUnpaused();
        vm.prank(alice);
        manager.depositToVault(address(vault), amount);
        uint256 shares = manager.internalShareBalance(address(vault), alice);
        vm.prank(alice);
        manager.withdrawFromVault(address(vault), shares);
        parked = manager.internalAssetBalance(address(asset), alice);
        assertGt(parked, 0, "precondition: alice has parked assets");
    }

    function test_queueDeposit_consumesInternalAssets_first_noTransferFrom() public {
        uint256 parked = _aliceParkAssetsInternally(1_000e6);

        // Drop alice's wallet allowance to ZERO and her wallet balance to ZERO.
        // The transferFrom path would revert; the internal-consumption path must succeed.
        uint256 aliceWalletBefore = asset.balanceOf(alice);
        vm.prank(alice); asset.transfer(makeAddr("sink"), aliceWalletBefore);
        assertEq(asset.balanceOf(alice), 0, "wallet drained");
        vm.prank(alice); asset.approve(address(manager), 0);
        // Pause deposits via vault state to test queueDeposit specifically.
        vm.prank(admin); vault.setDepositsPaused(true);

        vm.prank(alice);
        manager.queueDeposit(address(vault), parked);

        assertEq(manager.internalAssetBalance(address(asset), alice), 0, "internal asset drained");
        assertEq(manager.userDepositAmounts(address(vault), alice, 0), parked, "queued");
    }

    function test_queueDeposit_partialInternal_pullsShortfall() public {
        // Park 400e6 internally; queue 1_000e6 → must consume 400e6 internal + 600e6 wallet.
        uint256 parked = _aliceParkAssetsInternally(400e6);
        uint256 want   = 1_000e6;
        uint256 shortfall = want - parked;

        vm.prank(admin); vault.setDepositsPaused(true);

        uint256 walletBefore = asset.balanceOf(alice);
        vm.prank(alice);
        manager.queueDeposit(address(vault), want);

        assertEq(manager.internalAssetBalance(address(asset), alice), 0, "internal drained");
        assertEq(walletBefore - asset.balanceOf(alice), shortfall, "wallet charged shortfall only");
        assertEq(manager.userDepositAmounts(address(vault), alice, 0), want, "full amount queued");
    }

    function test_depositToVault_consumesInternalAssets_first() public {
        uint256 parked = _aliceParkAssetsInternally(1_000e6);

        // Drop wallet allowance + balance.
        uint256 walletBal = asset.balanceOf(alice);
        vm.prank(alice); asset.transfer(makeAddr("sink"), walletBal);
        vm.prank(alice); asset.approve(address(manager), 0);

        // Direct deposit using only the parked balance.
        vm.prank(alice);
        manager.depositToVault(address(vault), parked);

        assertEq(manager.internalAssetBalance(address(asset), alice), 0, "internal drained");
        assertGt(manager.internalShareBalance(address(vault), alice), 0, "shares credited");
    }

    function test_depositToVault_partialInternal_pullsShortfall() public {
        uint256 parked = _aliceParkAssetsInternally(300e6);
        uint256 want   = 1_000e6;
        uint256 shortfall = want - parked;

        uint256 walletBefore = asset.balanceOf(alice);
        vm.prank(alice);
        manager.depositToVault(address(vault), want);

        assertEq(manager.internalAssetBalance(address(asset), alice), 0, "internal drained");
        assertEq(walletBefore - asset.balanceOf(alice), shortfall, "wallet charged shortfall only");
    }

    function test_queueDeposit_zeroInternal_fullTransferFrom_unchanged() public {
        // Regression: with no internal balance, behavior is exactly as before.
        uint256 walletBefore = asset.balanceOf(alice);
        vm.prank(alice);
        manager.queueDeposit(address(vault), 500e6);
        assertEq(walletBefore - asset.balanceOf(alice), 500e6, "full pull from wallet");
        assertEq(manager.userDepositAmounts(address(vault), alice, 0), 500e6);
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    function _getDepositRound(uint256 round) internal view returns (IRfyVaultManager.DepositRound memory) {
        return _getDepositRoundFor(address(vault), round);
    }

    function _getDepositRoundFor(
        address v,
        uint256 round
    ) internal view returns (IRfyVaultManager.DepositRound memory dr) {
        (dr.totalAssets, dr.totalShares, dr.refundAssets, dr.processed) = manager.depositRounds(v, round);
    }

    function _getWithdrawalRound(uint256 round) internal view returns (IRfyVaultManager.WithdrawalRound memory) {
        return _getWithdrawalRoundFor(address(vault), round);
    }

    function _getWithdrawalRoundFor(
        address v,
        uint256 round
    ) internal view returns (IRfyVaultManager.WithdrawalRound memory wr) {
        (wr.totalShares, wr.totalAssets, wr.processed) = manager.withdrawalRounds(v, round);
    }
}
