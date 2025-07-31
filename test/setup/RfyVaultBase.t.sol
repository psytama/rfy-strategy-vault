// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { RfyVaultStorage } from "./RfyVaultStorage.t.sol";
import { RfyVault } from "../../src/RfyVault.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

abstract contract RfyVaultBase is RfyVaultStorage {
	function setUp() public virtual {
		vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), 304945980);
		usdc = IERC20(USDC);
		vm.makePersistent(address(usdc));
		vm.makePersistent(YEARN_VAULT);

		// Deploy vault
		vault = new RfyVault();

		vault.initialize("Rfy Vault Token", "RFY", "TEST", address(usdc), admin, trader, YEARN_VAULT, 30 days, 1_000_000e6);

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
}
