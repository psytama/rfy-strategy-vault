// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { MockERC20 } from "../../src/mocks/MockERC20.sol";

contract MockERC20Script is Script {
	MockERC20 public mockERC20;

	function run() external {
		uint256 deployerPrivateKey = vm.envUint("DEV_PRIVATE_KEY");

		string memory tokenName = "WBTC";
		string memory tokenSymbol = "WBTC";
		uint8 decimals = 18;

		vm.startBroadcast(deployerPrivateKey);

		mockERC20 = new MockERC20(tokenName, tokenSymbol, decimals);

		vm.stopBroadcast();

		_postDeployment();
	}

	function _postDeployment() internal view {
		console.log("Deployment Summary:");
		console.log("-------------------");
		console.log("MockERC20 deployed at: ", address(mockERC20));
	}
}
