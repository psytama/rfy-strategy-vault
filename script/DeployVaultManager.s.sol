// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { RfyVaultManager } from "../src/RfyVaultManager.sol";

/**
 * @title DeployVaultManager
 * @notice Deploys the RfyVaultManager and registers all currently-deployed vaults on the
 *         target chain. Vault addresses are hard-coded per chain id.
 *
 * Usage:
 *   forge script script/DeployVaultManager.s.sol:DeployVaultManager \
 *       --rpc-url <rpc> --private-key <key> [--broadcast]
 *
 * Environment Variables:
 *   PRIVATE_KEY  - Private key for deployment
 *   MANAGER_OWNER (optional) - Owner of the manager. Defaults to deployer.
 */
contract DeployVaultManager is Script {
	// Chain ids
	uint256 internal constant INJECTIVE_CHAIN_ID = 1776;
	uint256 internal constant BOTANIX_CHAIN_ID = 3637;
	uint256 internal constant ETHEREUM_CHAIN_ID = 1;
	uint256 internal constant ARBITRUM_CHAIN_ID = 42161;

	RfyVaultManager public manager;
	address public deployer;
	address public owner;

	function run() external {
		uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
		deployer = vm.addr(deployerPrivateKey);
		owner = vm.envOr("MANAGER_OWNER", deployer);

		address[] memory vaults = _vaultsForChain(block.chainid);

		vm.startBroadcast(deployerPrivateKey);

		manager = new RfyVaultManager(owner);
		console.log("RfyVaultManager deployed at:", address(manager));

		// registerVault is onlyOwner — only register here if the deployer owns the manager.
		if (owner == deployer) {
			for (uint256 i = 0; i < vaults.length; i++) {
				manager.registerVault(vaults[i]);
				console.log("Registered vault:", vaults[i]);
			}
		} else {
			console.log("Owner is not deployer; skipping registration. Owner must call registerVault().");
		}

		vm.stopBroadcast();

		_logSummary(vaults);
	}

	function _vaultsForChain(uint256 chainId) internal pure returns (address[] memory vaults) {
		if (chainId == INJECTIVE_CHAIN_ID) {
			vaults = new address[](2);
			vaults[0] = 0x5cbe2CdE999d80F9699000BEBC07f1d04F2b1dc0;
			vaults[1] = 0x9a7f6C9168878aeBC80eC6Ac2a5596D3dE593138;
		} else if (chainId == BOTANIX_CHAIN_ID) {
			// pBTC, stBTC, USDC option vaults
			vaults = new address[](3);
			vaults[0] = 0xB819B78798C174fA9e80aD26903EACb27c68CfD6;
			vaults[1] = 0x5107b03D9b4fB135A58435a4507716304372645b;
			vaults[2] = 0x644C81Bac306A4dCAAeaFfe66B284E4F7B245227;
		} else if (chainId == ETHEREUM_CHAIN_ID) {
			// USDT option vault
			vaults = new address[](1);
			vaults[0] = 0xb15E63222Be05B1128609A5ce6EbB549632687Ec;
		} else if (chainId == ARBITRUM_CHAIN_ID) {
			// USDT option vault
			vaults = new address[](1);
			vaults[0] = 0xe2d73Dd71757d988971FfA947C887f1201eAd28A;
		} else {
			revert(string.concat("DeployVaultManager: no vaults configured for chainId"));
		}
	}

	function _logSummary(address[] memory vaults) internal view {
		console.log("\n================================================================");
		console.log("                  VAULT MANAGER DEPLOYMENT");
		console.log("================================================================");
		console.log("Chain ID:        ", block.chainid);
		console.log("Deployer:        ", deployer);
		console.log("Manager Owner:   ", owner);
		console.log("Manager Address: ", address(manager));
		console.log("\nRegistered vaults (", vaults.length, "):");
		for (uint256 i = 0; i < vaults.length; i++) {
			console.log("  -", vaults[i]);
		}
		console.log("================================================================");
	}
}
