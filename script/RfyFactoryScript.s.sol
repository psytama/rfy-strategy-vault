// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { RfyVaultFactory } from "../src/RfyVaultFactory.sol";

contract RfyVaultFactoryScript is Script {
	RfyVaultFactory public rfyVaultFactory;

	function run() external {
		uint256 deployerPrivateKey = vm.envUint("DEV_PRIVATE_KEY");
		address rfyVaultImplementation = vm.envAddress("RFY_VAULT_IMPLEMENTATION");

		vm.startBroadcast(deployerPrivateKey);

		rfyVaultFactory = new RfyVaultFactory(rfyVaultImplementation);

		vm.stopBroadcast();

		_postDeployment();
	}

	function _postDeployment() internal view {
		console.log("Deployment Summary:");
		console.log("-------------------");
		console.log("RfyVaultFactory deployed at: ", address(rfyVaultFactory));
	}
}
