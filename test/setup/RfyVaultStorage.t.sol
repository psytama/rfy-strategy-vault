// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { RfyVault } from "../../src/RfyVault.sol";

contract RfyVaultStorage is Test {
	address constant USDC = address(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
	address constant YEARN_VAULT = address(0x6FAF8b7fFeE3306EfcFc2BA9Fec912b4d49834C1);
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
}
