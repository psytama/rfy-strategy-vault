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
		IRfyVaultFactory rfyVaultFactory = IRfyVaultFactory(0x51eCE283e41f2Bb9928746ACE0028ef77F30b3ba);
		address assetAddress = 0xe9aBA835f813ca05E50A6C0ce65D0D74390F7dE7;
		address yearnVault = vm.envAddress("YEARN_ADDRESS");
		address trader = vm.envAddress("TRADER_ADDRESS");
		uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
		address deployer = vm.addr(deployerPrivateKey);

		vm.startBroadcast(deployerPrivateKey);
		string memory tokenName = "Weth Yield Vault";
		string memory tokenSymbol = "rfyWETH";
		uint256 epochDuration = 30 days;

		vault = IRfyVault(
			rfyVaultFactory.createVault(
				tokenName,
				tokenSymbol,
				"",  // memeName
				assetAddress,
				deployer,
				trader,
				yearnVault,
				epochDuration,
				500e18  // maxTotalDeposits
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
