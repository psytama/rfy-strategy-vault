// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script, console } from "forge-std/Script.sol";
import { MockERC20 } from "../src/mocks/MockERC20.sol";

/**
 * @title MintMockTokens
 * @dev Script to mint mock tokens to the deployer address
 * 
 * Usage:
 *   forge script script/MintMockTokens.s.sol:MintMockTokens --rpc-url <rpc> --broadcast
 * 
 * Environment Variables:
 *   PRIVATE_KEY - Private key for the transaction
 *   MOCK_TOKEN_ADDRESS - Address of the mock token to mint
 */
contract MintMockTokens is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address tokenAddress = 0x2508FC3487c21f67F30eDeC94afB24fdF6735C76;
        
        MockERC20 token = MockERC20(tokenAddress);
        uint8 decimals = token.decimals();
        uint256 mintAmount = 100_000 * (10 ** decimals);
        
        vm.startBroadcast(deployerPrivateKey);
        
        token.mint(deployer, mintAmount);
        
        vm.stopBroadcast();
        
        console.log("=== Mint Summary ===");
        console.log("Token:", tokenAddress);
        console.log("Token Name:", token.name());
        console.log("Token Symbol:", token.symbol());
        console.log("Decimals:", decimals);
        console.log("Minted to:", deployer);
        console.log("Amount minted:", mintAmount);
        console.log("Deployer balance:", token.balanceOf(deployer));
    }
}
