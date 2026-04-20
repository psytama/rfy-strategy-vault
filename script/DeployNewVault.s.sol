// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { IRfyVaultFactory } from "../src/interfaces/IRfyVaultFactory.sol";
import { IRfyVault } from "../src/interfaces/IRfyVault.sol";

contract DeployNewVault is Script {
	IRfyVault vault;

	function run() external {
		IRfyVaultFactory rfyVaultFactory = IRfyVaultFactory(vm.envAddress("VAULT_FACTORY"));
		address assetAddress = vm.envAddress("ASSET_ADDRESS");
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
