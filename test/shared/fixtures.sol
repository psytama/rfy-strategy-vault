// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { CustomUniswapV2Factory } from "../../src/dex/CustomUniswapV2Factory.sol";
import { CustomUniswapV2Pair } from "../../src/dex/CustomUniswapV2Pair.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { TestUtilities } from "../shared/utilities.sol";

contract TestFixtures is Test {
    using TestUtilities for uint256;
    
    struct FactoryFixture {
        CustomUniswapV2Factory factory;
        address deployer;
    }
    
    struct PairFixture {
        CustomUniswapV2Factory factory;
        MockERC20 token0;
        MockERC20 token1;
        CustomUniswapV2Pair pair;
        address deployer;
    }
    
    function createFactoryFixture() internal returns (FactoryFixture memory) {
        address deployer = address(this);
        CustomUniswapV2Factory factory = new CustomUniswapV2Factory(deployer);
        
        return FactoryFixture({
            factory: factory,
            deployer: deployer
        });
    }
    
    function createPairFixture() internal returns (PairFixture memory) {
        FactoryFixture memory factoryFixture = createFactoryFixture();
        
        MockERC20 tokenA = new MockERC20("Token A", "TKNA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKNB", 18);
        
        // Mint large amounts for testing
        uint256 totalSupply = TestUtilities.expandTo18Decimals(10000);
        tokenA.mint(address(this), totalSupply);
        tokenB.mint(address(this), totalSupply);
        
        // Create pair
        factoryFixture.factory.createPair(address(tokenA), address(tokenB));
        address pairAddress = factoryFixture.factory.getPair(address(tokenA), address(tokenB));
        CustomUniswapV2Pair pair = CustomUniswapV2Pair(pairAddress);
        
        // Determine token0 and token1 based on pair
        address token0Address = pair.token0();
        MockERC20 token0 = address(tokenA) == token0Address ? tokenA : tokenB;
        MockERC20 token1 = address(tokenA) == token0Address ? tokenB : tokenA;
        
        return PairFixture({
            factory: factoryFixture.factory,
            token0: token0,
            token1: token1,
            pair: pair,
            deployer: factoryFixture.deployer
        });
    }
}
