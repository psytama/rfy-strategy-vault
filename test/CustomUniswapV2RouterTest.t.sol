// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { CustomUniswapV2Factory } from "../src/dex/CustomUniswapV2Factory.sol";
import { CustomUniswapV2Pair } from "../src/dex/CustomUniswapV2Pair.sol";
import { CustomUniswapV2Router } from "../src/dex/CustomUniswapV2Router.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { MockWETH } from "./mocks/MockWETH.sol";
import { DeflatingERC20 } from "./mocks/DeflatingERC20.sol";
import { TestUtilities } from "./shared/utilities.sol";

contract CustomUniswapV2RouterTest is Test {
    using TestUtilities for uint256;
    
    CustomUniswapV2Factory factory;
    CustomUniswapV2Router router;
    MockWETH WETH;
    MockERC20 token0;
    MockERC20 token1;
    DeflatingERC20 DTT;
    
    address deployer;
    address user;
    
    uint256 constant MINIMUM_LIQUIDITY = 10**3;
    uint256 constant MAX_UINT = 2**256 - 1;
    
    function setUp() public {
        deployer = address(this);
        user = makeAddr("user");
        
        // Deploy contracts
        factory = new CustomUniswapV2Factory(deployer);
        WETH = new MockWETH();
        router = new CustomUniswapV2Router(address(factory), address(WETH));
        
        // Deploy tokens
        token0 = new MockERC20("Token 0", "TKN0", 18);
        token1 = new MockERC20("Token 1", "TKN1", 18);
        DTT = new DeflatingERC20(TestUtilities.expandTo18Decimals(10000));
        
        // Ensure token0 < token1 for consistent ordering
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        // Mint tokens to test contract and user
        uint256 totalSupply = TestUtilities.expandTo18Decimals(10000);
        token0.mint(address(this), totalSupply);
        token1.mint(address(this), totalSupply);
        token0.mint(user, totalSupply);
        token1.mint(user, totalSupply);
        
        // Give user some ETH
        vm.deal(user, 100 ether);
        vm.deal(address(this), 100 ether);
    }
    
    // **** LIBRARY FUNCTION TESTS ****
    
    function test_Quote() public {
        assertEq(router.quote(1, 100, 200), 2);
        assertEq(router.quote(2, 200, 100), 1);
        
        vm.expectRevert("UniswapV2Library: INSUFFICIENT_AMOUNT");
        router.quote(0, 100, 200);
        
        vm.expectRevert("UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        router.quote(1, 0, 200);
        
        vm.expectRevert("UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        router.quote(1, 100, 0);
    }
    
    function test_GetAmountOut() public {
        assertEq(router.getAmountOut(2, 100, 100), 1);
        
        vm.expectRevert("UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        router.getAmountOut(0, 100, 100);
        
        vm.expectRevert("UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        router.getAmountOut(2, 0, 100);
        
        vm.expectRevert("UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        router.getAmountOut(2, 100, 0);
    }
    
    function test_GetAmountIn() public {
        assertEq(router.getAmountIn(1, 100, 100), 2);
        
        vm.expectRevert("UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        router.getAmountIn(0, 100, 100);
        
        vm.expectRevert("UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        router.getAmountIn(1, 0, 100);
        
        vm.expectRevert("UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        router.getAmountIn(1, 100, 0);
    }
    
    function test_GetAmountsOut() public {
        // First add liquidity to have a pair
        token0.approve(address(router), MAX_UINT);
        token1.approve(address(router), MAX_UINT);
        router.addLiquidity(
            address(token0),
            address(token1),
            10000,
            10000,
            0,
            0,
            address(this),
            block.timestamp + 1
        );
        
        vm.expectRevert("UniswapV2Library: INVALID_PATH");
        address[] memory invalidPath = new address[](1);
        invalidPath[0] = address(token0);
        router.getAmountsOut(2, invalidPath);
        
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        uint[] memory amounts = router.getAmountsOut(2, path);
        assertEq(amounts[0], 2);
        assertEq(amounts[1], 1);
    }
    
    function test_GetAmountsIn() public {
        // First add liquidity to have a pair
        token0.approve(address(router), MAX_UINT);
        token1.approve(address(router), MAX_UINT);
        router.addLiquidity(
            address(token0),
            address(token1),
            10000,
            10000,
            0,
            0,
            address(this),
            block.timestamp + 1
        );
        
        vm.expectRevert("UniswapV2Library: INVALID_PATH");
        address[] memory invalidPath = new address[](1);
        invalidPath[0] = address(token0);
        router.getAmountsIn(1, invalidPath);
        
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        uint[] memory amounts = router.getAmountsIn(1, path);
        assertEq(amounts[0], 2);
        assertEq(amounts[1], 1);
    }
    
    // **** ADD LIQUIDITY TESTS ****
    
    function test_AddLiquidity() public {
        token0.approve(address(router), MAX_UINT);
        token1.approve(address(router), MAX_UINT);
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(4);
        uint256 expectedLiquidity = TestUtilities.expandTo18Decimals(2);
        
        (uint amountA, uint amountB, uint liquidity) = router.addLiquidity(
            address(token0),
            address(token1),
            token0Amount,
            token1Amount,
            0,
            0,
            address(this),
            block.timestamp + 1
        );
        
        assertEq(amountA, token0Amount);
        assertEq(amountB, token1Amount);
        assertEq(liquidity, expectedLiquidity - MINIMUM_LIQUIDITY);
    }
    
    function test_AddLiquidityETH() public {
        token0.approve(address(router), MAX_UINT);
        
        uint256 tokenAmount = TestUtilities.expandTo18Decimals(1);
        uint256 ethAmount = TestUtilities.expandTo18Decimals(4);
        uint256 expectedLiquidity = TestUtilities.expandTo18Decimals(2);
        
        (uint amountToken, uint amountETH, uint liquidity) = router.addLiquidityETH{value: ethAmount}(
            address(token0),
            tokenAmount,
            0,
            0,
            address(this),
            block.timestamp + 1
        );
        
        assertEq(amountToken, tokenAmount);
        assertEq(amountETH, ethAmount);
        assertEq(liquidity, expectedLiquidity - MINIMUM_LIQUIDITY);
    }
    
    // **** REMOVE LIQUIDITY TESTS ****
    
    function test_RemoveLiquidity() public {
        // First add liquidity
        token0.approve(address(router), MAX_UINT);
        token1.approve(address(router), MAX_UINT);
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(3);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(3);
        
        (,, uint liquidity) = router.addLiquidity(
            address(token0),
            address(token1),
            token0Amount,
            token1Amount,
            0,
            0,
            address(this),
            block.timestamp + 1
        );
        
        // Get pair and approve router to spend LP tokens
        address pairAddress = factory.getPair(address(token0), address(token1));
        CustomUniswapV2Pair pair = CustomUniswapV2Pair(pairAddress);
        pair.approve(address(router), MAX_UINT);
        
        // Remove liquidity
        (uint amountA, uint amountB) = router.removeLiquidity(
            address(token0),
            address(token1),
            liquidity,
            0,
            0,
            address(this),
            block.timestamp + 1
        );
        
        assertEq(amountA, token0Amount - 1000);
        assertEq(amountB, token1Amount - 1000);
    }
    
    function test_RemoveLiquidityETH() public {
        // First add liquidity
        token0.approve(address(router), MAX_UINT);
        
        uint256 tokenAmount = TestUtilities.expandTo18Decimals(3);
        uint256 ethAmount = TestUtilities.expandTo18Decimals(3);
        
        (,, uint liquidity) = router.addLiquidityETH{value: ethAmount}(
            address(token0),
            tokenAmount,
            0,
            0,
            address(this),
            block.timestamp + 1
        );
        
        // Get pair and approve router to spend LP tokens
        address pairAddress = factory.getPair(address(token0), address(WETH));
        CustomUniswapV2Pair pair = CustomUniswapV2Pair(pairAddress);
        pair.approve(address(router), MAX_UINT);
        
        uint256 ethBalanceBefore = address(this).balance;
        
        // Remove liquidity
        (uint amountToken, uint amountETH) = router.removeLiquidityETH(
            address(token0),
            liquidity,
            0,
            0,
            address(this),
            block.timestamp + 1
        );
        
        assertEq(amountToken, tokenAmount - 1000);
        assertEq(amountETH, ethAmount - 1000);
        assertEq(address(this).balance, ethBalanceBefore + amountETH);
    }
    
    // **** SWAP TESTS ****
    
    function test_SwapExactTokensForTokens() public {
        // Add liquidity first
        addLiquidity();
        
        token0.approve(address(router), MAX_UINT);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        
        uint256 token1BalanceBefore = token1.balanceOf(address(this));
        
        uint[] memory amounts = router.swapExactTokensForTokens(
            swapAmount,
            0,
            path,
            address(this),
            block.timestamp + 1
        );
        
        uint256 token1BalanceAfter = token1.balanceOf(address(this));
        assertEq(token1BalanceAfter - token1BalanceBefore, amounts[1]);
    }
    
    function test_SwapTokensForExactTokens() public {
        // Add liquidity first
        addLiquidity();
        
        token0.approve(address(router), MAX_UINT);
        
        uint256 amountOut = TestUtilities.expandTo18Decimals(1);
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        
        uint256 token0BalanceBefore = token0.balanceOf(address(this));
        uint256 token1BalanceBefore = token1.balanceOf(address(this));
        
        uint[] memory amounts = router.swapTokensForExactTokens(
            amountOut,
            MAX_UINT,
            path,
            address(this),
            block.timestamp + 1
        );
        
        uint256 token0BalanceAfter = token0.balanceOf(address(this));
        uint256 token1BalanceAfter = token1.balanceOf(address(this));
        
        assertEq(token0BalanceBefore - token0BalanceAfter, amounts[0]);
        assertEq(token1BalanceAfter - token1BalanceBefore, amounts[1]);
        assertEq(amounts[1], amountOut);
    }
    
    function test_SwapExactETHForTokens() public {
        // Add liquidity first
        addLiquidityETH();
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(token0);
        
        uint256 token0BalanceBefore = token0.balanceOf(address(this));
        
        uint[] memory amounts = router.swapExactETHForTokens{value: swapAmount}(
            0,
            path,
            address(this),
            block.timestamp + 1
        );
        
        uint256 token0BalanceAfter = token0.balanceOf(address(this));
        assertEq(token0BalanceAfter - token0BalanceBefore, amounts[1]);
    }
    
    function test_SwapTokensForExactETH() public {
        // Add liquidity first
        addLiquidityETH();
        
        token0.approve(address(router), MAX_UINT);
        
        uint256 amountOut = TestUtilities.expandTo18Decimals(1);
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(WETH);
        
        uint256 ethBalanceBefore = address(this).balance;
        
        uint[] memory amounts = router.swapTokensForExactETH(
            amountOut,
            MAX_UINT,
            path,
            address(this),
            block.timestamp + 1
        );
        
        uint256 ethBalanceAfter = address(this).balance;
        assertEq(ethBalanceAfter - ethBalanceBefore, amounts[1]);
        assertEq(amounts[1], amountOut);
    }
    
    function test_SwapExactTokensForETH() public {
        // Add liquidity first
        addLiquidityETH();
        
        token0.approve(address(router), MAX_UINT);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(WETH);
        
        uint256 ethBalanceBefore = address(this).balance;
        
        uint[] memory amounts = router.swapExactTokensForETH(
            swapAmount,
            0,
            path,
            address(this),
            block.timestamp + 1
        );
        
        uint256 ethBalanceAfter = address(this).balance;
        assertEq(ethBalanceAfter - ethBalanceBefore, amounts[1]);
    }
    
    function test_SwapETHForExactTokens() public {
        // Add liquidity first
        addLiquidityETH();
        
        uint256 amountOut = TestUtilities.expandTo18Decimals(1);
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(token0);
        
        uint256 token0BalanceBefore = token0.balanceOf(address(this));
        uint256 ethBalanceBefore = address(this).balance;
        
        uint[] memory amounts = router.swapETHForExactTokens{value: TestUtilities.expandTo18Decimals(5)}(
            amountOut,
            path,
            address(this),
            block.timestamp + 1
        );
        
        uint256 token0BalanceAfter = token0.balanceOf(address(this));
        uint256 ethBalanceAfter = address(this).balance;
        
        assertEq(token0BalanceAfter - token0BalanceBefore, amounts[1]);
        assertEq(amounts[1], amountOut);
        // Should have refunded excess ETH
        assertEq(ethBalanceBefore - ethBalanceAfter, amounts[0]);
    }
    
    // **** FEE-ON-TRANSFER TOKEN TESTS ****
    
    function test_RemoveLiquidityETHSupportingFeeOnTransferTokens() public {
        uint256 DTTAmount = TestUtilities.expandTo18Decimals(1);
        uint256 ETHAmount = TestUtilities.expandTo18Decimals(4);
        addLiquidityDTT(DTTAmount, ETHAmount);
        
        address pairAddress = factory.getPair(address(DTT), address(WETH));
        CustomUniswapV2Pair pair = CustomUniswapV2Pair(pairAddress);
        
        uint256 DTTInPair = DTT.balanceOf(pairAddress);
        uint256 WETHInPair = WETH.balanceOf(pairAddress);
        uint256 liquidity = pair.balanceOf(address(this));
        uint256 totalSupply = pair.totalSupply();
        uint256 NaiveDTTExpected = DTTInPair * liquidity / totalSupply;
        uint256 WETHExpected = WETHInPair * liquidity / totalSupply;
        
        pair.approve(address(router), MAX_UINT);
        router.removeLiquidityETHSupportingFeeOnTransferTokens(
            address(DTT),
            liquidity,
            NaiveDTTExpected,
            WETHExpected,
            address(this),
            block.timestamp + 1
        );
    }
    
    function test_SwapExactTokensForTokensSupportingFeeOnTransferTokens_DTT_WETH() public {
        uint256 DTTAmount = TestUtilities.expandTo18Decimals(5) * 100 / 99;
        uint256 ETHAmount = TestUtilities.expandTo18Decimals(10);
        uint256 amountIn = TestUtilities.expandTo18Decimals(1);
        
        addLiquidityDTT(DTTAmount, ETHAmount);
        
        DTT.approve(address(router), MAX_UINT);
        
        address[] memory path = new address[](2);
        path[0] = address(DTT);
        path[1] = address(WETH);
        
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            0,
            path,
            address(this),
            block.timestamp + 1
        );
    }
    
    function test_SwapExactTokensForTokensSupportingFeeOnTransferTokens_WETH_DTT() public {
        uint256 DTTAmount = TestUtilities.expandTo18Decimals(5) * 100 / 99;
        uint256 ETHAmount = TestUtilities.expandTo18Decimals(10);
        uint256 amountIn = TestUtilities.expandTo18Decimals(1);
        
        addLiquidityDTT(DTTAmount, ETHAmount);
        
        WETH.deposit{value: amountIn}();
        WETH.approve(address(router), MAX_UINT);
        
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(DTT);
        
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            0,
            path,
            address(this),
            block.timestamp + 1
        );
    }
    
    function test_SwapExactETHForTokensSupportingFeeOnTransferTokens() public {
        uint256 DTTAmount = TestUtilities.expandTo18Decimals(10) * 100 / 99;
        uint256 ETHAmount = TestUtilities.expandTo18Decimals(5);
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        
        addLiquidityDTT(DTTAmount, ETHAmount);
        
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(DTT);
        
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: swapAmount}(
            0,
            path,
            address(this),
            block.timestamp + 1
        );
    }
    
    function test_SwapExactTokensForETHSupportingFeeOnTransferTokens() public {
        uint256 DTTAmount = TestUtilities.expandTo18Decimals(5) * 100 / 99;
        uint256 ETHAmount = TestUtilities.expandTo18Decimals(10);
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        
        addLiquidityDTT(DTTAmount, ETHAmount);
        
        DTT.approve(address(router), MAX_UINT);
        
        address[] memory path = new address[](2);
        path[0] = address(DTT);
        path[1] = address(WETH);
        
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapAmount,
            0,
            path,
            address(this),
            block.timestamp + 1
        );
    }
    
    // Test fee-on-transfer tokens: reloaded (DTT <-> DTT2)
    function test_SwapExactTokensForTokensSupportingFeeOnTransferTokens_DTT_DTT2() public {
        DeflatingERC20 DTT2 = new DeflatingERC20(TestUtilities.expandTo18Decimals(10000));
        
        uint256 DTTAmount = TestUtilities.expandTo18Decimals(5) * 100 / 99;
        uint256 DTT2Amount = TestUtilities.expandTo18Decimals(5);
        uint256 amountIn = TestUtilities.expandTo18Decimals(1);
        
        // Add liquidity for DTT-DTT2 pair
        DTT.approve(address(router), MAX_UINT);
        DTT2.approve(address(router), MAX_UINT);
        
        router.addLiquidity(
            address(DTT),
            address(DTT2),
            DTTAmount,
            DTT2Amount,
            DTTAmount,
            DTT2Amount,
            address(this),
            block.timestamp + 1
        );
        
        address[] memory path = new address[](2);
        path[0] = address(DTT);
        path[1] = address(DTT2);
        
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            0,
            path,
            address(this),
            block.timestamp + 1
        );
    }
    
    // **** CUSTOM FEE TESTS ****
    
    function test_SwapsWithCustomFees() public {
        // Set custom fee rate to 1%
        factory.setCustomFeeRate(100);
        
        // Set fee collector
        address feeCollector = makeAddr("feeCollector");
        factory.setFeeTo(feeCollector);
        
        // Add liquidity
        addLiquidity();
        
        token0.approve(address(router), MAX_UINT);
        
        uint256 swapAmount = TestUtilities.expandTo18Decimals(1);
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        
        uint256 feeCollectorBalanceBefore = token1.balanceOf(feeCollector);
        uint256 userBalanceBefore = token1.balanceOf(address(this));
        
        // Get expected amounts - these don't account for custom fees at router level
        uint[] memory expectedAmounts = router.getAmountsOut(swapAmount, path);
        uint256 expectedOutput = expectedAmounts[1];
        
        uint[] memory amounts = router.swapExactTokensForTokens(
            swapAmount,
            0,
            path,
            address(this),
            block.timestamp + 1
        );
        
        uint256 feeCollectorBalanceAfter = token1.balanceOf(feeCollector);
        uint256 userBalanceAfter = token1.balanceOf(address(this));
        
        uint256 actualFeeCollected = feeCollectorBalanceAfter - feeCollectorBalanceBefore;
        uint256 actualUserReceived = userBalanceAfter - userBalanceBefore;
        
        // The router calculates and returns the full amount before custom fees
        assertEq(amounts[1], expectedOutput);
        
        // Custom fee is 1% of the expected output
        uint256 expectedFee = (expectedOutput * 100) / 10000;
        assertEq(actualFeeCollected, expectedFee);
        
        // User receives the amount after custom fees are deducted
        uint256 expectedUserOutput = expectedOutput - expectedFee;
        assertEq(actualUserReceived, expectedUserOutput);
        
        // Total should equal expected output
        assertEq(actualFeeCollected + actualUserReceived, expectedOutput);
    }
    
    // **** ERROR TESTS ****
    
    function test_ExpiredDeadline() public {
        token0.approve(address(router), MAX_UINT);
        token1.approve(address(router), MAX_UINT);
        
        vm.expectRevert("UniswapV2Router: EXPIRED");
        router.addLiquidity(
            address(token0),
            address(token1),
            1000,
            1000,
            0,
            0,
            address(this),
            block.timestamp - 1 // Expired deadline
        );
    }
    
    function test_InsufficientOutput() public {
        addLiquidity();
        
        token0.approve(address(router), MAX_UINT);
        
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        
        vm.expectRevert("UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        router.swapExactTokensForTokens(
            TestUtilities.expandTo18Decimals(1),
            TestUtilities.expandTo18Decimals(2), // Unrealistic minimum output
            path,
            address(this),
            block.timestamp + 1
        );
    }
    
    function test_ExcessiveInput() public {
        addLiquidity();
        
        token0.approve(address(router), MAX_UINT);
        
        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        
        vm.expectRevert("UniswapV2Router: EXCESSIVE_INPUT_AMOUNT");
        router.swapTokensForExactTokens(
            TestUtilities.expandTo18Decimals(1),
            1, // Maximum input too low
            path,
            address(this),
            block.timestamp + 1
        );
    }
    
    function test_InvalidPath() public {
        vm.expectRevert("UniswapV2Router: INVALID_PATH");
        address[] memory invalidPath = new address[](2);
        invalidPath[0] = address(token0);
        invalidPath[1] = address(token0); // Invalid path to WETH
        router.swapExactETHForTokens{value: 1 ether}(
            0,
            invalidPath,
            address(this),
            block.timestamp + 1
        );
    }
    
    // **** HELPER FUNCTIONS ****
    
    function addLiquidity() internal {
        token0.approve(address(router), MAX_UINT);
        token1.approve(address(router), MAX_UINT);
        
        router.addLiquidity(
            address(token0),
            address(token1),
            TestUtilities.expandTo18Decimals(10),
            TestUtilities.expandTo18Decimals(10),
            0,
            0,
            address(this),
            block.timestamp + 1
        );
    }
    
    function addLiquidityETH() internal {
        token0.approve(address(router), MAX_UINT);
        
        router.addLiquidityETH{value: TestUtilities.expandTo18Decimals(10)}(
            address(token0),
            TestUtilities.expandTo18Decimals(10),
            0,
            0,
            address(this),
            block.timestamp + 1
        );
    }
    
    function addLiquidityDTT(uint256 DTTAmount, uint256 ETHAmount) internal {
        DTT.approve(address(router), MAX_UINT);
        
        router.addLiquidityETH{value: ETHAmount}(
            address(DTT),
            DTTAmount,
            DTTAmount,
            ETHAmount,
            address(this),
            block.timestamp + 1
        );
    }
    
    // Required to receive ETH
    receive() external payable {}
}
