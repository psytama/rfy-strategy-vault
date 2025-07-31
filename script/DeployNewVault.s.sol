// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IRfyVaultFactory } from "../src/interfaces/IRfyVaultFactory.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";

contract DeployNewVault is Script {
	// address public constant ASSET_ADDRESS = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
	// address public constant YEARN_VAULT = 0x6FAF8b7fFeE3306EfcFc2BA9Fec912b4d49834C1;

	IRfyVault vault;

	function run() external {
		IRfyVaultFactory rfyVaultFactory = IRfyVaultFactory(vm.envAddress("RFY_VAULT_FACTORY"));
		address assetAddress = vm.envAddress("USDC_ADDRESS");
		address yearnVault = vm.envAddress("YEARN_ADDRESS");
		address trader = vm.envAddress("TRADER_ADDRESS");
		uint256 deployerPrivateKey = vm.envUint("DEV_PRIVATE_KEY");
		address deployer = vm.addr(deployerPrivateKey);

		vm.startBroadcast(deployerPrivateKey);
		string memory tokenName = "RfyVault";
		string memory tokenSymbol = "RfyVault";
		uint256 epochDuration = 20 minutes;

		vault = IRfyVault(
			rfyVaultFactory.createVault(
				tokenName,
				tokenSymbol,
				"TEST",  // memeName
				assetAddress,
				deployer,
				trader,
				yearnVault,
				epochDuration,
				1_000_000e6  // maxTotalDeposits
			)
		);

		vm.stopBroadcast();
		_postDeployment();
	}

	function _postDeployment() internal view {
		console.log("Deployment Summary:");
		console.log("-------------------");
		console.log("Vault deployed to : ", address(vault));
		console.log("Asset: ", address(vault.asset()));
	}
}
