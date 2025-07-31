// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { RfyVault } from "../src/RfyVault.sol";

contract RfyVaultScript is Script {
	RfyVault public rfyVault;

	function run() external {
		uint256 deployerPrivateKey = vm.envUint("DEV_PRIVATE_KEY");

		vm.startBroadcast(deployerPrivateKey);

		rfyVault = new RfyVault();

		vm.stopBroadcast();

		_postDeployment();
	}

	function _postDeployment() internal view {
		console.log("Deployment Summary:");
		console.log("-------------------");
		console.log("RfyVault deployed at: ", address(rfyVault));
	}
}
