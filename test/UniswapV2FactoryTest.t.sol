// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { CustomUniswapV2Factory } from "../src/dex/CustomUniswapV2Factory.sol";
import { CustomUniswapV2Pair } from "../src/dex/CustomUniswapV2Pair.sol";
import { TestFixtures } from "./shared/fixtures.sol";
import { TestUtilities } from "./shared/utilities.sol";

contract UniswapV2FactoryTest is Test, TestFixtures {
    using TestUtilities for uint256;
    
    CustomUniswapV2Factory factory;
    address deployer;
    address other;
    
    // Test addresses from Uniswap V2 tests
    address constant TEST_ADDRESS_0 = 0x1000000000000000000000000000000000000000;
    address constant TEST_ADDRESS_1 = 0x2000000000000000000000000000000000000000;
    
    // Events (matching actual factory implementation)
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);
    event FeeToUpdated(address indexed newFeeTo);
    event CustomFeeRateUpdated(uint256 newFeeRate);
    
    function setUp() public {
        deployer = makeAddr("deployer");
        other = makeAddr("other");
        
        vm.prank(deployer);
        factory = new CustomUniswapV2Factory(deployer);
    }
    
    function test_InitialState() public {
        assertEq(factory.feeTo(), address(0));
        assertEq(factory.feeToSetter(), deployer);
        assertEq(factory.allPairsLength(), 0);
        // Custom fee rate should be initialized to 30 (0.3%) as per the factory implementation
        assertEq(factory.customFeeRate(), 30);
    }
    
    function test_CreatePair() public {
        // Predict the address using CREATE2
        bytes32 salt = keccak256(abi.encodePacked(TEST_ADDRESS_0, TEST_ADDRESS_1));
        bytes memory bytecode = type(CustomUniswapV2Pair).creationCode;
        address predictedAddress = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(factory),
            salt,
            keccak256(bytecode)
        )))));
        
        // Expect PairCreated event
        vm.expectEmit(true, true, false, true);
        emit PairCreated(TEST_ADDRESS_0, TEST_ADDRESS_1, predictedAddress, 1);
        
        address pair = factory.createPair(TEST_ADDRESS_0, TEST_ADDRESS_1);
        
        // Verify the predicted address matches
        assertEq(pair, predictedAddress);
        
        assertEq(factory.getPair(TEST_ADDRESS_0, TEST_ADDRESS_1), pair);
        assertEq(factory.getPair(TEST_ADDRESS_1, TEST_ADDRESS_0), pair);
        assertEq(factory.allPairs(0), pair);
        assertEq(factory.allPairsLength(), 1);
        
        CustomUniswapV2Pair pairContract = CustomUniswapV2Pair(pair);
        assertEq(pairContract.factory(), address(factory));
        assertEq(pairContract.token0(), TEST_ADDRESS_0);
        assertEq(pairContract.token1(), TEST_ADDRESS_1);
    }
    
    function test_CreatePairReverse() public {
        // First create pair normally
        bytes32 salt = keccak256(abi.encodePacked(TEST_ADDRESS_0, TEST_ADDRESS_1));
        bytes memory bytecode = type(CustomUniswapV2Pair).creationCode;
        address predictedAddress = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(factory),
            salt,
            keccak256(bytecode)
        )))));
        
        // Expect PairCreated event
        vm.expectEmit(true, true, false, true);
        emit PairCreated(TEST_ADDRESS_0, TEST_ADDRESS_1, predictedAddress, 1);
        
        address pair1 = factory.createPair(TEST_ADDRESS_0, TEST_ADDRESS_1);
        
        // Creating pair with reversed addresses should revert because pair already exists
        vm.expectRevert("UniswapV2: PAIR_EXISTS");
        factory.createPair(TEST_ADDRESS_1, TEST_ADDRESS_0);
        
        // Verify the original pair is still accessible both ways
        assertEq(factory.getPair(TEST_ADDRESS_0, TEST_ADDRESS_1), pair1);
        assertEq(factory.getPair(TEST_ADDRESS_1, TEST_ADDRESS_0), pair1);
    }
    
    function test_CreatePairGas() public {
        uint256 gasBefore = gasleft();
        factory.createPair(TEST_ADDRESS_0, TEST_ADDRESS_1);
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for createPair:", gasUsed);
        // Should be reasonable gas usage (original Uniswap used ~2.5M gas)
        assertLt(gasUsed, 3000000);
    }
    
    function test_CreatePairIdenticalAddresses() public {
        vm.expectRevert("UniswapV2: IDENTICAL_ADDRESSES");
        factory.createPair(TEST_ADDRESS_0, TEST_ADDRESS_0);
    }
    
    function test_CreatePairZeroAddress() public {
        vm.expectRevert("UniswapV2: ZERO_ADDRESS");
        factory.createPair(address(0), TEST_ADDRESS_1);
        
        vm.expectRevert("UniswapV2: ZERO_ADDRESS");
        factory.createPair(TEST_ADDRESS_0, address(0));
    }
    
    function test_CreatePairExists() public {
        factory.createPair(TEST_ADDRESS_0, TEST_ADDRESS_1);
        
        vm.expectRevert("UniswapV2: PAIR_EXISTS");
        factory.createPair(TEST_ADDRESS_0, TEST_ADDRESS_1);
        
        vm.expectRevert("UniswapV2: PAIR_EXISTS");
        factory.createPair(TEST_ADDRESS_1, TEST_ADDRESS_0);
    }
    
    function test_SetFeeTo() public {
        // Non-authorized user should not be able to set feeTo
        vm.expectRevert("UniswapV2: FORBIDDEN");
        vm.prank(other);
        factory.setFeeTo(other);
        
        // Authorized user should be able to set feeTo
        vm.expectEmit(true, false, false, false);
        emit FeeToUpdated(other);
        
        vm.prank(deployer);
        factory.setFeeTo(other);
        assertEq(factory.feeTo(), other);
        
        // Test setting to zero address
        vm.expectEmit(true, false, false, false);
        emit FeeToUpdated(address(0));
        
        vm.prank(deployer);
        factory.setFeeTo(address(0));
        assertEq(factory.feeTo(), address(0));
    }
    
    function test_SetFeeToSetter() public {
        vm.expectRevert("UniswapV2: FORBIDDEN");
        vm.prank(other);
        factory.setFeeToSetter(other);
        
        vm.prank(deployer);
        factory.setFeeToSetter(other);
        assertEq(factory.feeToSetter(), other);
        
        // Original deployer should no longer have permission
        vm.expectRevert("UniswapV2: FORBIDDEN");
        vm.prank(deployer);
        factory.setFeeToSetter(deployer);
    }
    
    function test_SetCustomFeeRate() public {
        // Non-authorized user should not be able to set custom fee rate
        vm.expectRevert("UniswapV2: FORBIDDEN");
        vm.prank(other);
        factory.setCustomFeeRate(100);
        
        // Authorized user should be able to set custom fee rate
        vm.expectEmit(false, false, false, true);
        emit CustomFeeRateUpdated(100);
        
        vm.prank(deployer);
        factory.setCustomFeeRate(100);
        assertEq(factory.customFeeRate(), 100);
        
        // Test maximum fee rate (10%)
        vm.expectEmit(false, false, false, true);
        emit CustomFeeRateUpdated(1000);
        
        vm.prank(deployer);
        factory.setCustomFeeRate(1000);
        assertEq(factory.customFeeRate(), 1000);
        
        // Test minimum fee rate (0%)
        vm.expectEmit(false, false, false, true);
        emit CustomFeeRateUpdated(0);
        
        vm.prank(deployer);
        factory.setCustomFeeRate(0);
        assertEq(factory.customFeeRate(), 0);
        
        // Test invalid fee rate (over 10%)
        vm.expectRevert("UniswapV2: FEE_TOO_HIGH");
        vm.prank(deployer);
        factory.setCustomFeeRate(1001);
    }
    
    function testFuzz_CreatePair(address tokenA, address tokenB) public {
        vm.assume(tokenA != tokenB);
        vm.assume(tokenA != address(0) && tokenB != address(0));
        vm.assume(tokenA.code.length == 0 && tokenB.code.length == 0);
        
        address pair = factory.createPair(tokenA, tokenB);
        
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        assertEq(factory.getPair(tokenA, tokenB), pair);
        assertEq(factory.getPair(tokenB, tokenA), pair);
        assertEq(factory.allPairs(0), pair);
        assertEq(factory.allPairsLength(), 1);
        
        CustomUniswapV2Pair pairContract = CustomUniswapV2Pair(pair);
        assertEq(pairContract.factory(), address(factory));
        assertEq(pairContract.token0(), token0);
        assertEq(pairContract.token1(), token1);
    }
    
    function testFuzz_CustomFeeRate(uint256 feeRate) public {
        feeRate = bound(feeRate, 0, 1000); // 0-10%
        
        vm.prank(deployer);
        factory.setCustomFeeRate(feeRate);
        assertEq(factory.customFeeRate(), feeRate);
    }
    
    function test_MultipleParallelPairs() public {
        address pair1 = factory.createPair(TEST_ADDRESS_0, TEST_ADDRESS_1);
        
        address token2 = makeAddr("token2");
        address token3 = makeAddr("token3");
        address pair2 = factory.createPair(token2, token3);
        
        assertNotEq(pair1, pair2);
        assertEq(factory.allPairsLength(), 2);
        assertEq(factory.allPairs(0), pair1);
        assertEq(factory.allPairs(1), pair2);
    }
    
    // Additional comprehensive tests based on original Uniswap V2
    
    function test_FactoryInitialization() public {
        // Test factory deployment with different feeToSetter
        address newFeeToSetter = makeAddr("newFeeToSetter");
        CustomUniswapV2Factory newFactory = new CustomUniswapV2Factory(newFeeToSetter);
        
        assertEq(newFactory.feeTo(), address(0));
        assertEq(newFactory.feeToSetter(), newFeeToSetter);
        assertEq(newFactory.allPairsLength(), 0);
        assertEq(newFactory.customFeeRate(), 30); // Default 0.3%
    }
    
    function test_CREATE2AddressPrediction() public {
        // Test CREATE2 address prediction for different token pairs
        address tokenA = makeAddr("tokenA");
        address tokenB = makeAddr("tokenB");
        
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes memory bytecode = type(CustomUniswapV2Pair).creationCode;
        address predictedAddress = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(factory),
            salt,
            keccak256(bytecode)
        )))));
        
        address actualAddress = factory.createPair(tokenA, tokenB);
        assertEq(actualAddress, predictedAddress);
    }
    
    function test_TokenSorting() public {
        // Test that tokens are sorted correctly regardless of input order
        address tokenA = address(0x1111111111111111111111111111111111111111);
        address tokenB = address(0x2222222222222222222222222222222222222222);
        
        address pair1 = factory.createPair(tokenA, tokenB);
        
        // Create another factory and create pair with reversed order
        CustomUniswapV2Factory factory2 = new CustomUniswapV2Factory(deployer);
        address pair2 = factory2.createPair(tokenB, tokenA);
        
        // Both pairs should have the same token0 and token1 due to sorting
        CustomUniswapV2Pair pairContract1 = CustomUniswapV2Pair(pair1);
        CustomUniswapV2Pair pairContract2 = CustomUniswapV2Pair(pair2);
        
        assertEq(pairContract1.token0(), pairContract2.token0());
        assertEq(pairContract1.token1(), pairContract2.token1());
        assertEq(pairContract1.token0(), tokenA); // Lower address
        assertEq(pairContract1.token1(), tokenB); // Higher address
    }
    
    function test_PairContractInitialization() public {
        address pair = factory.createPair(TEST_ADDRESS_0, TEST_ADDRESS_1);
        
        CustomUniswapV2Pair pairContract = CustomUniswapV2Pair(pair);
        
        // Test basic ERC20 properties
        assertEq(pairContract.name(), "Uniswap V2");
        assertEq(pairContract.symbol(), "UNI-V2");
        assertEq(pairContract.decimals(), 18);
        assertEq(pairContract.totalSupply(), 0);
        
        // Test pair-specific properties
        assertEq(pairContract.factory(), address(factory));
        assertEq(pairContract.token0(), TEST_ADDRESS_0);
        assertEq(pairContract.token1(), TEST_ADDRESS_1);
        assertEq(pairContract.MINIMUM_LIQUIDITY(), 1000);
        
        // Test initial reserves
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = pairContract.getReserves();
        assertEq(reserve0, 0);
        assertEq(reserve1, 0);
        assertEq(blockTimestampLast, 0);
    }
    
    function test_FactoryOwnershipTransfer() public {
        // Test transferring feeToSetter ownership
        address newOwner = makeAddr("newOwner");
        
        vm.prank(deployer);
        factory.setFeeToSetter(newOwner);
        
        // Old owner should not have access anymore
        vm.expectRevert("UniswapV2: FORBIDDEN");
        vm.prank(deployer);
        factory.setFeeTo(makeAddr("someAddress"));
        
        // New owner should have access
        vm.prank(newOwner);
        factory.setFeeTo(makeAddr("someAddress"));
        
        // New owner can transfer ownership again
        address anotherOwner = makeAddr("anotherOwner");
        vm.prank(newOwner);
        factory.setFeeToSetter(anotherOwner);
        
        assertEq(factory.feeToSetter(), anotherOwner);
    }
    
    function test_CustomFeeRateEdgeCases() public {
        // Test setting the same fee rate multiple times
        vm.prank(deployer);
        factory.setCustomFeeRate(50);
        
        vm.prank(deployer);
        factory.setCustomFeeRate(50); // Should work without issues
        
        assertEq(factory.customFeeRate(), 50);
        
        // Test boundary values
        vm.prank(deployer);
        factory.setCustomFeeRate(1); // Minimum non-zero
        assertEq(factory.customFeeRate(), 1);
        
        vm.prank(deployer);
        factory.setCustomFeeRate(999); // Maximum below limit
        assertEq(factory.customFeeRate(), 999);
    }
    
    function test_FactoryEvents() public {
        // Test all factory events
        
        // FeeToUpdated event
        vm.expectEmit(true, false, false, false);
        emit FeeToUpdated(other);
        vm.prank(deployer);
        factory.setFeeTo(other);
        
        // CustomFeeRateUpdated event
        vm.expectEmit(false, false, false, true);
        emit CustomFeeRateUpdated(150);
        vm.prank(deployer);
        factory.setCustomFeeRate(150);
        
        // PairCreated event
        bytes32 salt = keccak256(abi.encodePacked(TEST_ADDRESS_0, TEST_ADDRESS_1));
        bytes memory bytecode = type(CustomUniswapV2Pair).creationCode;
        address predictedAddress = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(factory),
            salt,
            keccak256(bytecode)
        )))));
        
        vm.expectEmit(true, true, false, true);
        emit PairCreated(TEST_ADDRESS_0, TEST_ADDRESS_1, predictedAddress, 1);
        factory.createPair(TEST_ADDRESS_0, TEST_ADDRESS_1);
    }
    
    function test_LargePairCount() public {
        // Test creating many pairs
        for (uint i = 0; i < 10; i++) {
            address tokenA = address(uint160(0x1000 + i));
            address tokenB = address(uint160(0x2000 + i));
            
            factory.createPair(tokenA, tokenB);
        }
        
        assertEq(factory.allPairsLength(), 10);
        
        // Verify all pairs are accessible
        for (uint i = 0; i < 10; i++) {
            address tokenA = address(uint160(0x1000 + i));
            address tokenB = address(uint160(0x2000 + i));
            
            address pair = factory.getPair(tokenA, tokenB);
            assertNotEq(pair, address(0));
            assertEq(factory.allPairs(i), pair);
        }
    }
}
