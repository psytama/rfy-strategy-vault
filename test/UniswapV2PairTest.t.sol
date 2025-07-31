// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { CustomUniswapV2Factory } from "../src/dex/CustomUniswapV2Factory.sol";
import { CustomUniswapV2Pair } from "../src/dex/CustomUniswapV2Pair.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { TestFixtures } from "./shared/fixtures.sol";
import { TestUtilities } from "./shared/utilities.sol";

contract UniswapV2PairTest is Test, TestFixtures {
    using TestUtilities for uint256;
    
    CustomUniswapV2Factory factory;
    MockERC20 token0;
    MockERC20 token1;
    CustomUniswapV2Pair pair;
    address deployer;
    address other;
    
    uint256 constant MINIMUM_LIQUIDITY = 10**3;
    
    function setUp() public {
        other = makeAddr("other");
        
        PairFixture memory fixture = createPairFixture();
        factory = fixture.factory;
        token0 = fixture.token0;
        token1 = fixture.token1;
        pair = fixture.pair;
        deployer = fixture.deployer;
    }
    
    function test_Mint() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(4);
        
        token0.transfer(address(pair), token0Amount);
        token1.transfer(address(pair), token1Amount);
        
        uint256 expectedLiquidity = TestUtilities.expandTo18Decimals(2);
        uint256 liquidity = pair.mint(address(this));
        
        assertEq(liquidity, expectedLiquidity - MINIMUM_LIQUIDITY);
        assertEq(pair.totalSupply(), expectedLiquidity);
        assertEq(pair.balanceOf(address(this)), expectedLiquidity - MINIMUM_LIQUIDITY);
        assertEq(token0.balanceOf(address(pair)), token0Amount);
        assertEq(token1.balanceOf(address(pair)), token1Amount);
        
        (uint112 reserves0, uint112 reserves1,) = pair.getReserves();
        assertEq(reserves0, token0Amount);
        assertEq(reserves1, token1Amount);
    }
    
    function addLiquidity(uint256 token0Amount, uint256 token1Amount) internal {
        token0.transfer(address(pair), token0Amount);
        token1.transfer(address(pair), token1Amount);
        pair.mint(address(this));
    }
    
    function test_SwapToken0() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(5);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(10);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        uint256 expectedOutputAmount = 1662497915624478906;
        token0.transfer(address(pair), swapAmount);
        
        pair.swap(0, expectedOutputAmount, address(this), new bytes(0));
        
        (uint112 reserves0, uint112 reserves1,) = pair.getReserves();
        assertEq(reserves0, token0Amount + swapAmount);
        assertEq(reserves1, token1Amount - expectedOutputAmount);
        assertEq(token0.balanceOf(address(pair)), token0Amount + swapAmount);
        assertEq(token1.balanceOf(address(pair)), token1Amount - expectedOutputAmount);
        
        uint256 totalSupplyToken0 = token0.totalSupply();
        uint256 totalSupplyToken1 = token1.totalSupply();
        assertEq(token0.balanceOf(address(this)), totalSupplyToken0 - token0Amount - swapAmount);
        assertEq(token1.balanceOf(address(this)), totalSupplyToken1 - token1Amount + expectedOutputAmount);
    }
    
    function test_SwapToken1() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(5);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(10);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        uint256 expectedOutputAmount = 453305446940074565;
        token1.transfer(address(pair), swapAmount);
        
        pair.swap(expectedOutputAmount, 0, address(this), new bytes(0));
        
        (uint112 reserves0, uint112 reserves1,) = pair.getReserves();
        assertEq(reserves0, token0Amount - expectedOutputAmount);
        assertEq(reserves1, token1Amount + swapAmount);
        assertEq(token0.balanceOf(address(pair)), token0Amount - expectedOutputAmount);
        assertEq(token1.balanceOf(address(pair)), token1Amount + swapAmount);
        
        uint256 totalSupplyToken0 = token0.totalSupply();
        uint256 totalSupplyToken1 = token1.totalSupply();
        assertEq(token0.balanceOf(address(this)), totalSupplyToken0 - token0Amount + expectedOutputAmount);
        assertEq(token1.balanceOf(address(this)), totalSupplyToken1 - token1Amount - swapAmount);
    }
    
    function test_Burn() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(3);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(3);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 expectedLiquidity = TestUtilities.expandTo18Decimals(3);
        pair.transfer(address(pair), expectedLiquidity - MINIMUM_LIQUIDITY);
        
        (uint256 amount0, uint256 amount1) = pair.burn(address(this));
        
        assertEq(amount0, token0Amount - 1000);
        assertEq(amount1, token1Amount - 1000);
        assertEq(pair.balanceOf(address(this)), 0);
        assertEq(pair.totalSupply(), MINIMUM_LIQUIDITY);
        assertEq(token0.balanceOf(address(pair)), 1000);
        assertEq(token1.balanceOf(address(pair)), 1000);
        
        uint256 totalSupplyToken0 = token0.totalSupply();
        uint256 totalSupplyToken1 = token1.totalSupply();
        assertEq(token0.balanceOf(address(this)), totalSupplyToken0 - 1000);
        assertEq(token1.balanceOf(address(this)), totalSupplyToken1 - 1000);
    }
    
    function test_PriceAccumulators() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(3);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(3);
        addLiquidity(token0Amount, token1Amount);
        
        (, , uint32 blockTimestamp) = pair.getReserves();
        vm.warp(blockTimestamp + 1);
        pair.sync();
        
        (uint256 price0, uint256 price1) = TestUtilities.encodePrice(uint112(token0Amount), uint112(token1Amount));
        assertEq(pair.price0CumulativeLast(), price0);
        assertEq(pair.price1CumulativeLast(), price1);
        
        (, , uint32 newBlockTimestamp) = pair.getReserves();
        assertEq(newBlockTimestamp, blockTimestamp + 1);
        
        // Add more tokens to change price
        uint256 swapAmount = TestUtilities.expandTo18Decimals(3);
        token0.transfer(address(pair), swapAmount);
        vm.warp(blockTimestamp + 10);
        
        // Swap to new price
        pair.swap(0, TestUtilities.expandTo18Decimals(1), address(this), new bytes(0));
        
        assertEq(pair.price0CumulativeLast(), price0 * 10);
        assertEq(pair.price1CumulativeLast(), price1 * 10);
        
        (, , uint32 finalBlockTimestamp) = pair.getReserves();
        assertEq(finalBlockTimestamp, blockTimestamp + 10);
        
        vm.warp(blockTimestamp + 20);
        pair.sync();
        
        (uint256 newPrice0, uint256 newPrice1) = TestUtilities.encodePrice(
            uint112(TestUtilities.expandTo18Decimals(6)), 
            uint112(TestUtilities.expandTo18Decimals(2))
        );
        assertEq(pair.price0CumulativeLast(), price0 * 10 + newPrice0 * 10);
        assertEq(pair.price1CumulativeLast(), price1 * 10 + newPrice1 * 10);
    }
    
    function test_FeeToOff() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1000);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(1000);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        uint256 expectedOutputAmount = 996006981039903216;
        token1.transfer(address(pair), swapAmount);
        pair.swap(expectedOutputAmount, 0, address(this), new bytes(0));
        
        uint256 expectedLiquidity = TestUtilities.expandTo18Decimals(1000);
        pair.transfer(address(pair), expectedLiquidity - MINIMUM_LIQUIDITY);
        pair.burn(address(this));
        assertEq(pair.totalSupply(), MINIMUM_LIQUIDITY);
    }
    
    function test_FeeToOn() public {
        vm.prank(deployer);
        factory.setFeeTo(other);
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1000);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(1000);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        // Calculate expected output accounting for default custom fee (0.3%)
        uint256 baseExpectedOutput = 996006981039903216;
        uint256 adjustedExpectedOutputAmount = baseExpectedOutput - (baseExpectedOutput * 30) / 10000;
        
        token1.transfer(address(pair), swapAmount);
        pair.swap(adjustedExpectedOutputAmount, 0, address(this), new bytes(0));
        
        uint256 expectedLiquidity = TestUtilities.expandTo18Decimals(1000);
        pair.transfer(address(pair), expectedLiquidity - MINIMUM_LIQUIDITY);
        pair.burn(address(this));
        
        // Should have protocol fee liquidity tokens minted
        assertGt(pair.totalSupply(), MINIMUM_LIQUIDITY);
        assertGt(pair.balanceOf(other), 0);
        
        // Check that tokens in pair are reasonable
        assertGt(token0.balanceOf(address(pair)), 1000);
        assertGt(token1.balanceOf(address(pair)), 1000);
    }
    
    function test_SwapWithCustomFees() public {
        // Set custom fee rate to 1%
        vm.prank(deployer);
        factory.setCustomFeeRate(100);
        
        // Set fee collector
        address feeCollector = makeAddr("feeCollector");
        vm.prank(deployer);
        factory.setFeeTo(feeCollector);
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1000);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(1000);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        token0.transfer(address(pair), swapAmount);
        
        uint256 feeCollectorToken1BalanceBefore = token1.balanceOf(feeCollector);
        uint256 userToken1BalanceBefore = token1.balanceOf(address(this));
        
        // The custom fee logic works by taking the requested amountOut and:
        // 1. Calculating fee = amountOut * feeRate / 10000
        // 2. Transferring fee to feeTo
        // 3. Transferring (amountOut - fee) to user
        // The total withdrawn from reserves is still amountOut
        
        uint256 requestedOutputAmount = 996006981039903216; // Standard Uniswap calculation
        uint256 expectedFee = (requestedOutputAmount * 100) / 10000; // 1% fee
        uint256 expectedUserAmount = requestedOutputAmount - expectedFee;
        
        pair.swap(0, requestedOutputAmount, address(this), new bytes(0));
        
        // Check that custom fee was collected
        uint256 actualFeeCollected = token1.balanceOf(feeCollector) - feeCollectorToken1BalanceBefore;
        uint256 actualUserReceived = token1.balanceOf(address(this)) - userToken1BalanceBefore;
        
        assertEq(actualFeeCollected, expectedFee);
        assertEq(actualUserReceived, expectedUserAmount);
    }
    
    function test_Skim() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(4);
        addLiquidity(token0Amount, token1Amount);
        
        // Send extra tokens to pair
        token0.transfer(address(pair), TestUtilities.expandTo18Decimals(1));
        token1.transfer(address(pair), TestUtilities.expandTo18Decimals(1));
        
        uint256 balanceBefore0 = token0.balanceOf(other);
        uint256 balanceBefore1 = token1.balanceOf(other);
        
        pair.skim(other);
        
        uint256 balanceAfter0 = token0.balanceOf(other);
        uint256 balanceAfter1 = token1.balanceOf(other);
        
        assertEq(balanceAfter0 - balanceBefore0, TestUtilities.expandTo18Decimals(1));
        assertEq(balanceAfter1 - balanceBefore1, TestUtilities.expandTo18Decimals(1));
    }
    
    // Optimistic swap tests similar to Uniswap V2
    struct SwapTestCase {
        uint256 swapAmount;
        uint256 token0Amount;
        uint256 token1Amount;
        uint256 expectedOutputAmount;
    }
    
    function test_OptimisticSwapBasic() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(5);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(10);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        token0.transfer(address(pair), swapAmount);
        
        // Test K invariant protection
        vm.expectRevert("UniswapV2: K");
        pair.swap(0, TestUtilities.expandTo18Decimals(5), address(this), new bytes(0)); // Too much output
        
        // Should work with reasonable output
        pair.swap(0, 1662497915624478906, address(this), new bytes(0));
    }
    
    // Test all swap scenarios with expected amounts from original Uniswap V2
    function test_SwapScenarios() public {
        // Test cases: [swapAmount, token0Amount, token1Amount, expectedOutputAmount]
        uint256[4][7] memory swapTestCases = [
            [TestUtilities.expandTo18Decimals(1), TestUtilities.expandTo18Decimals(5), TestUtilities.expandTo18Decimals(10), 1662497915624478906],
            [TestUtilities.expandTo18Decimals(1), TestUtilities.expandTo18Decimals(10), TestUtilities.expandTo18Decimals(5), 453305446940074565],
            [TestUtilities.expandTo18Decimals(2), TestUtilities.expandTo18Decimals(5), TestUtilities.expandTo18Decimals(10), 2851015155847869602],
            [TestUtilities.expandTo18Decimals(2), TestUtilities.expandTo18Decimals(10), TestUtilities.expandTo18Decimals(5), 831248957812239453],
            [TestUtilities.expandTo18Decimals(1), TestUtilities.expandTo18Decimals(10), TestUtilities.expandTo18Decimals(10), 906610893880149131],
            [TestUtilities.expandTo18Decimals(1), TestUtilities.expandTo18Decimals(100), TestUtilities.expandTo18Decimals(100), 987158034397061298],
            [TestUtilities.expandTo18Decimals(1), TestUtilities.expandTo18Decimals(1000), TestUtilities.expandTo18Decimals(1000), 996006981039903216]
        ];
        
        for (uint i = 0; i < swapTestCases.length; i++) {
            uint256[4] memory testCase = swapTestCases[i];
            uint256 swapAmount = testCase[0];
            uint256 token0Amount = testCase[1]; 
            uint256 token1Amount = testCase[2];
            uint256 expectedOutputAmount = testCase[3];
            
            // Reset state for each test
            setUp();
            addLiquidity(token0Amount, token1Amount);
            token0.transfer(address(pair), swapAmount);
            
            // Should revert with too high output (K violation)
            vm.expectRevert("UniswapV2: K");
            pair.swap(0, expectedOutputAmount + 1, address(this), new bytes(0));
            
            // Should succeed with correct output
            pair.swap(0, expectedOutputAmount, address(this), new bytes(0));
        }
    }
    
    function test_EmitEvents() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(4);
        
        token0.transfer(address(pair), token0Amount);
        token1.transfer(address(pair), token1Amount);
        
        uint256 expectedLiquidity = TestUtilities.expandTo18Decimals(2);
        
        // Test mint events
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(0), MINIMUM_LIQUIDITY);
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(this), expectedLiquidity - MINIMUM_LIQUIDITY);
        vm.expectEmit(true, true, true, true);
        emit Sync(uint112(token0Amount), uint112(token1Amount));
        vm.expectEmit(true, true, true, true);
        emit Mint(address(this), token0Amount, token1Amount);
        
        pair.mint(address(this));
    }
    
    function test_SwapEvents() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(5);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(10);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        uint256 expectedOutputAmount = 1662497915624478906;
        token0.transfer(address(pair), swapAmount);
        
        vm.expectEmit(true, true, true, true);
        emit Sync(uint112(token0Amount + swapAmount), uint112(token1Amount - expectedOutputAmount));
        vm.expectEmit(true, true, true, true);
        emit Swap(address(this), swapAmount, 0, 0, expectedOutputAmount, address(this));
        
        pair.swap(0, expectedOutputAmount, address(this), new bytes(0));
    }
    
    function test_BurnEvents() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(3);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(3);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 expectedLiquidity = TestUtilities.expandTo18Decimals(3);
        pair.transfer(address(pair), expectedLiquidity - MINIMUM_LIQUIDITY);
        
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(pair), address(0), expectedLiquidity - MINIMUM_LIQUIDITY);
        vm.expectEmit(true, true, true, true);
        emit Sync(1000, 1000);
        vm.expectEmit(true, true, true, true);
        emit Burn(address(this), token0Amount - 1000, token1Amount - 1000, address(this));
        
        pair.burn(address(this));
    }
    
    // Additional events to match interface
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    
    function testFuzz_Mint(uint256 token0Amount, uint256 token1Amount) public {
        token0Amount = bound(token0Amount, MINIMUM_LIQUIDITY + 1, TestUtilities.expandTo18Decimals(1000));
        token1Amount = bound(token1Amount, MINIMUM_LIQUIDITY + 1, TestUtilities.expandTo18Decimals(1000));
        
        token0.transfer(address(pair), token0Amount);
        token1.transfer(address(pair), token1Amount);
        
        uint256 expectedLiquidity = TestUtilities.sqrt(token0Amount * token1Amount);
        uint256 liquidity = pair.mint(address(this));
        
        assertEq(liquidity, expectedLiquidity - MINIMUM_LIQUIDITY);
        assertEq(pair.totalSupply(), expectedLiquidity);
        assertEq(pair.balanceOf(address(this)), expectedLiquidity - MINIMUM_LIQUIDITY);
    }
    
    function test_SwapGas() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(5);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(10);
        addLiquidity(token0Amount, token1Amount);
        
        // Ensure price accumulators are set for first time (affects gas)
        (, , uint32 blockTimestamp) = pair.getReserves();
        vm.warp(blockTimestamp + 1);
        pair.sync();
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        uint256 expectedOutputAmount = 453305446940074565;
        token1.transfer(address(pair), swapAmount);
        vm.warp(blockTimestamp + 1);
        
        uint256 gasBefore = gasleft();
        pair.swap(expectedOutputAmount, 0, address(this), new bytes(0));
        uint256 gasUsed = gasBefore - gasleft();
        
        console.log("Gas used for swap:", gasUsed);
        // Should be reasonable gas usage (original Uniswap used ~73k gas)
        assertLt(gasUsed, 100000);
    }
    
    // Test custom fee edge cases
    function test_CustomFeeZeroRate() public {
        // Set custom fee rate to 0% 
        vm.prank(deployer);
        factory.setCustomFeeRate(0);
        
        address feeCollector = makeAddr("feeCollector");
        vm.prank(deployer);
        factory.setFeeTo(feeCollector);
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1000);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(1000);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        token0.transfer(address(pair), swapAmount);
        
        uint256 feeCollectorBalanceBefore = token1.balanceOf(feeCollector);
        uint256 userBalanceBefore = token1.balanceOf(address(this));
        
        uint256 expectedOutputAmount = 996006981039903216; // Standard calculation
        pair.swap(0, expectedOutputAmount, address(this), new bytes(0));
        
        // With 0% custom fee, fee collector should get nothing
        assertEq(token1.balanceOf(feeCollector), feeCollectorBalanceBefore);
        // User should get full amount
        assertEq(token1.balanceOf(address(this)), userBalanceBefore + expectedOutputAmount);
    }
    
    function test_CustomFeeMaxRate() public {
        // Set custom fee rate to max (10%)
        vm.prank(deployer);
        factory.setCustomFeeRate(1000);
        
        address feeCollector = makeAddr("feeCollector");
        vm.prank(deployer);
        factory.setFeeTo(feeCollector);
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1000);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(1000);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        token0.transfer(address(pair), swapAmount);
        
        uint256 feeCollectorToken1BalanceBefore = token1.balanceOf(feeCollector);
        uint256 userToken1BalanceBefore = token1.balanceOf(address(this));
        
        uint256 requestedOutputAmount = 996006981039903216;
        uint256 expectedFee = (requestedOutputAmount * 1000) / 10000; // 10% fee
        uint256 expectedUserAmount = requestedOutputAmount - expectedFee;
        
        pair.swap(0, requestedOutputAmount, address(this), new bytes(0));
        
        // Check fee was collected correctly
        uint256 actualFeeCollected = token1.balanceOf(feeCollector) - feeCollectorToken1BalanceBefore;
        uint256 actualUserReceived = token1.balanceOf(address(this)) - userToken1BalanceBefore;
        
        assertEq(actualFeeCollected, expectedFee);
        assertEq(actualUserReceived, expectedUserAmount);
    }
    
    function test_CustomFeeInvalidRate() public {
        // Should revert when setting fee rate too high
        vm.prank(deployer);
        vm.expectRevert("UniswapV2: FEE_TOO_HIGH");
        factory.setCustomFeeRate(1001); // Over 10%
    }
    
    function test_CustomFeeWithoutFeeTo() public {
        // Test that custom fees don't apply when feeTo is not set
        vm.prank(deployer);
        factory.setCustomFeeRate(100); // 1%
        
        // Don't set feeTo
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1000);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(1000);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        token0.transfer(address(pair), swapAmount);
        
        uint256 userBalanceBefore = token1.balanceOf(address(this));
        
        uint256 expectedOutputAmount = 996006981039903216;
        pair.swap(0, expectedOutputAmount, address(this), new bytes(0));
        
        // User should get full amount since no feeTo is set
        assertEq(token1.balanceOf(address(this)), userBalanceBefore + expectedOutputAmount);
    }
    
    function test_SwapInvalidTo() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(5);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(10);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        token0.transfer(address(pair), swapAmount);
        
        // Should revert when trying to swap to token addresses
        vm.expectRevert("UniswapV2: INVALID_TO");
        pair.swap(0, 1, address(token0), new bytes(0));
        
        vm.expectRevert("UniswapV2: INVALID_TO");
        pair.swap(0, 1, address(token1), new bytes(0));
    }
    
    function test_SwapInsufficientLiquidity() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(5);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(10);
        addLiquidity(token0Amount, token1Amount);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        token0.transfer(address(pair), swapAmount);
        
        // Should revert when trying to output more than reserves
        vm.expectRevert("UniswapV2: INSUFFICIENT_LIQUIDITY");
        pair.swap(0, token1Amount + 1, address(this), new bytes(0));
        
        vm.expectRevert("UniswapV2: INSUFFICIENT_LIQUIDITY");
        pair.swap(token0Amount + 1, 0, address(this), new bytes(0));
    }
    
    function test_SwapInsufficientOutputAmount() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(5);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(10);
        addLiquidity(token0Amount, token1Amount);
        
        // Should revert when both outputs are 0
        vm.expectRevert("UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        pair.swap(0, 0, address(this), new bytes(0));
    }
    
    function test_SwapInsufficientInputAmount() public {
        uint256 token0Amount = TestUtilities.expandTo18Decimals(5);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(10);
        addLiquidity(token0Amount, token1Amount);
        
        // Don't transfer any tokens, so no input
        vm.expectRevert("UniswapV2: INSUFFICIENT_INPUT_AMOUNT");
        pair.swap(0, 1, address(this), new bytes(0));
    }
}
