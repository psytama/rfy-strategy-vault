// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { MockERC4626Vault } from "../../src/mocks/MockERC4626Vault.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockERC4626Script is Script {
	MockERC4626Vault public mockERC4626Vault;

	function run() external {
		uint256 deployerPrivateKey = vm.envUint("DEV_PRIVATE_KEY");

		string memory tokenName = "USDC Vault";
		string memory tokenSymbol = "USDCVAULT";
		uint256 bonusRate = 1500;

		address assetAddress = vm.envAddress("USDC_ADDRESS");
		IERC20 asset = IERC20(assetAddress);

		vm.startBroadcast(deployerPrivateKey);

		mockERC4626Vault = new MockERC4626Vault(asset, tokenName, tokenSymbol);

		vm.stopBroadcast();

		_postDeployment();
	}

	function _postDeployment() internal view {
		console.log("Deployment Summary:");
		console.log("-------------------");
		console.log("Vault deployed at: ", address(mockERC4626Vault));
	}
}
