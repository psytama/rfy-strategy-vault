// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test, console } from "forge-std/Test.sol";
import { CustomUniswapV2Pair } from "../src/dex/CustomUniswapV2Pair.sol";
import { CustomUniswapV2Factory } from "../src/dex/CustomUniswapV2Factory.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { TestFixtures } from "./shared/fixtures.sol";
import { TestUtilities } from "./shared/utilities.sol";

contract UniswapV2ERC20Test is Test, TestFixtures {
    using TestUtilities for uint256;
    
    CustomUniswapV2Pair pair;
    CustomUniswapV2Factory factory;
    MockERC20 testToken;
    address deployer;
    address other;
    address wallet;
    
    uint256 constant TOTAL_SUPPLY = 10000 * 10**18;
    uint256 constant TEST_AMOUNT = 10 * 10**18;
    
    // Constants for permit testing
    bytes32 constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    
    function setUp() public {
        wallet = address(this);
        other = makeAddr("other");
        
        PairFixture memory fixture = createPairFixture();
        pair = fixture.pair;
        factory = fixture.factory;
        deployer = fixture.deployer;
        
        // Create a test token that inherits from UniswapV2ERC20 functionality
        testToken = new MockERC20("Test Token", "TEST", 18);
        testToken.mint(address(this), TOTAL_SUPPLY);
    }
    
    function test_NameSymbolDecimals() public {
        assertEq(pair.name(), "Uniswap V2");
        assertEq(pair.symbol(), "UNI-V2");
        assertEq(pair.decimals(), 18);
    }
    
    function test_TotalSupplyBalanceOf() public {
        // Initially, no liquidity tokens
        assertEq(pair.totalSupply(), 0);
        assertEq(pair.balanceOf(address(this)), 0);
        
        // Test with mock token for basic ERC20 functionality
        assertEq(testToken.totalSupply(), TOTAL_SUPPLY);
        assertEq(testToken.balanceOf(address(this)), TOTAL_SUPPLY);
    }
    
    function test_DOMAIN_SEPARATOR() public {
        // The DOMAIN_SEPARATOR should be properly calculated
        string memory name = pair.name();
        bytes32 expectedDomainSeparator = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                block.chainid,
                address(pair)
            )
        );
        assertEq(pair.DOMAIN_SEPARATOR(), expectedDomainSeparator);
    }
    
    function test_PERMIT_TYPEHASH() public {
        bytes32 expected = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        assertEq(pair.PERMIT_TYPEHASH(), expected);
        assertEq(pair.PERMIT_TYPEHASH(), PERMIT_TYPEHASH);
    }
    
    function test_Approve() public {
        assertEq(testToken.allowance(address(this), other), 0);
        
        bool success = testToken.approve(other, TEST_AMOUNT);
        assertTrue(success);
        assertEq(testToken.allowance(address(this), other), TEST_AMOUNT);
    }
    
    function test_Transfer() public {
        uint256 balanceBefore = testToken.balanceOf(address(this));
        
        bool success = testToken.transfer(other, TEST_AMOUNT);
        assertTrue(success);
        
        assertEq(testToken.balanceOf(address(this)), balanceBefore - TEST_AMOUNT);
        assertEq(testToken.balanceOf(other), TEST_AMOUNT);
    }
    
    function test_TransferFail() public {
        vm.expectRevert();
        testToken.transfer(other, TOTAL_SUPPLY + 1);
        
        vm.prank(other);
        vm.expectRevert();
        testToken.transfer(address(this), 1);
    }
    
    function test_TransferFrom() public {
        testToken.approve(other, TEST_AMOUNT);
        
        vm.prank(other);
        bool success = testToken.transferFrom(address(this), other, TEST_AMOUNT);
        assertTrue(success);
        
        assertEq(testToken.allowance(address(this), other), 0);
        assertEq(testToken.balanceOf(address(this)), TOTAL_SUPPLY - TEST_AMOUNT);
        assertEq(testToken.balanceOf(other), TEST_AMOUNT);
    }
    
    function test_TransferFromMax() public {
        testToken.approve(other, type(uint256).max);
        
        vm.prank(other);
        bool success = testToken.transferFrom(address(this), other, TEST_AMOUNT);
        assertTrue(success);
        
        assertEq(testToken.allowance(address(this), other), type(uint256).max);
        assertEq(testToken.balanceOf(address(this)), TOTAL_SUPPLY - TEST_AMOUNT);
        assertEq(testToken.balanceOf(other), TEST_AMOUNT);
    }
    
    function test_LiquidityTokenTransfer() public {
        // Add some liquidity to get LP tokens
        PairFixture memory fixture = createPairFixture();
        MockERC20 token0 = fixture.token0;
        MockERC20 token1 = fixture.token1;
        CustomUniswapV2Pair liquidityPair = fixture.pair;
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(4);
        
        token0.transfer(address(liquidityPair), token0Amount);
        token1.transfer(address(liquidityPair), token1Amount);
        uint256 liquidity = liquidityPair.mint(address(this));
        
        assertTrue(liquidity > 0);
        assertEq(liquidityPair.balanceOf(address(this)), liquidity);
        
        // Test transfer of LP tokens
        bool success = liquidityPair.transfer(other, liquidity / 2);
        assertTrue(success);
        
        assertEq(liquidityPair.balanceOf(address(this)), liquidity / 2);
        assertEq(liquidityPair.balanceOf(other), liquidity / 2);
    }
    
    function test_LiquidityTokenApproval() public {
        // Add some liquidity first
        PairFixture memory fixture = createPairFixture();
        MockERC20 token0 = fixture.token0;
        MockERC20 token1 = fixture.token1;
        CustomUniswapV2Pair liquidityPair = fixture.pair;
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(4);
        
        token0.transfer(address(liquidityPair), token0Amount);
        token1.transfer(address(liquidityPair), token1Amount);
        uint256 liquidity = liquidityPair.mint(address(this));
        
        // Test approval and transferFrom
        liquidityPair.approve(other, liquidity);
        assertEq(liquidityPair.allowance(address(this), other), liquidity);
        
        vm.prank(other);
        bool success = liquidityPair.transferFrom(address(this), other, liquidity);
        assertTrue(success);
        
        assertEq(liquidityPair.balanceOf(address(this)), 0);
        assertEq(liquidityPair.balanceOf(other), liquidity);
        assertEq(liquidityPair.allowance(address(this), other), 0);
    }
    
    function test_LiquidityTokenApprovalMaxUint() public {
        // Add some liquidity first
        PairFixture memory fixture = createPairFixture();
        MockERC20 token0 = fixture.token0;
        MockERC20 token1 = fixture.token1;
        CustomUniswapV2Pair liquidityPair = fixture.pair;
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(4);
        
        token0.transfer(address(liquidityPair), token0Amount);
        token1.transfer(address(liquidityPair), token1Amount);
        uint256 liquidity = liquidityPair.mint(address(this));
        
        // Test max uint approval (should not decrease on transferFrom)
        liquidityPair.approve(other, type(uint256).max);
        assertEq(liquidityPair.allowance(address(this), other), type(uint256).max);
        
        vm.prank(other);
        bool success = liquidityPair.transferFrom(address(this), other, liquidity / 2);
        assertTrue(success);
        
        // Allowance should remain max uint
        assertEq(liquidityPair.allowance(address(this), other), type(uint256).max);
        assertEq(liquidityPair.balanceOf(address(this)), liquidity / 2);
        assertEq(liquidityPair.balanceOf(other), liquidity / 2);
    }
    
    // Helper function to get approval digest for permit
    
    // Additional edge case tests
    function test_TransferToSelf() public {
        uint256 balanceBefore = testToken.balanceOf(address(this));
        bool success = testToken.transfer(address(this), TEST_AMOUNT);
        assertTrue(success);
        assertEq(testToken.balanceOf(address(this)), balanceBefore);
    }
    
    function test_TransferFromToSelf() public {
        testToken.approve(address(this), TEST_AMOUNT);
        uint256 balanceBefore = testToken.balanceOf(address(this));
        
        bool success = testToken.transferFrom(address(this), address(this), TEST_AMOUNT);
        assertTrue(success);
        assertEq(testToken.balanceOf(address(this)), balanceBefore);
        assertEq(testToken.allowance(address(this), address(this)), 0);
    }
    
    function test_ZeroTransfer() public {
        uint256 balanceBefore = testToken.balanceOf(address(this));
        uint256 otherBalanceBefore = testToken.balanceOf(other);
        
        bool success = testToken.transfer(other, 0);
        assertTrue(success);
        
        assertEq(testToken.balanceOf(address(this)), balanceBefore);
        assertEq(testToken.balanceOf(other), otherBalanceBefore);
    }
    
    function test_ZeroApproval() public {
        testToken.approve(other, TEST_AMOUNT);
        assertEq(testToken.allowance(address(this), other), TEST_AMOUNT);
        
        // Reset to zero
        testToken.approve(other, 0);
        assertEq(testToken.allowance(address(this), other), 0);
    }
    
    function test_LiquidityTokenNoncesIncrement() public {
        assertEq(pair.nonces(wallet), 0);
        
        // Create a valid permit to increment nonce
        uint256 privateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address signer = vm.addr(privateKey);
        
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 1000;
        
        bytes32 digest = getApprovalDigest(pair, signer, other, value, pair.nonces(signer), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        
        pair.permit(signer, other, value, deadline, v, r, s);
        assertEq(pair.nonces(signer), 1);
        
        // Try to use the same nonce again - should fail
        vm.expectRevert("UniswapV2: INVALID_SIGNATURE");
        pair.permit(signer, other, value, deadline, v, r, s);
    }
    
    function test_PermitReplayProtection() public {
        uint256 privateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address signer = vm.addr(privateKey);
        
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = 1000;
        
        bytes32 digest = getApprovalDigest(pair, signer, other, value, pair.nonces(signer), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        
        // First permit should work
        pair.permit(signer, other, value, deadline, v, r, s);
        assertEq(pair.allowance(signer, other), value);
        
        // Second permit with same signature should fail (nonce changed)
        vm.expectRevert("UniswapV2: INVALID_SIGNATURE");
        pair.permit(signer, other, value, deadline, v, r, s);
    }
    
    // Enhanced fuzz tests
    function testFuzz_Transfer(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(to != address(this));
        amount = bound(amount, 0, TOTAL_SUPPLY);
        
        uint256 balanceFromBefore = testToken.balanceOf(address(this));
        uint256 balanceToBefore = testToken.balanceOf(to);
        
        bool success = testToken.transfer(to, amount);
        assertTrue(success);
        
        assertEq(testToken.balanceOf(address(this)), balanceFromBefore - amount);
        assertEq(testToken.balanceOf(to), balanceToBefore + amount);
        
        // Total supply should remain constant
        assertEq(testToken.totalSupply(), TOTAL_SUPPLY);
    }
    
    function testFuzz_Approve(address spender, uint256 amount) public {
        vm.assume(spender != address(0));
        
        bool success = testToken.approve(spender, amount);
        assertTrue(success);
        assertEq(testToken.allowance(address(this), spender), amount);
    }
    
    function testFuzz_TransferFrom(address to, uint256 approval, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(to != address(this));
        vm.assume(other != address(0));
        vm.assume(other != address(this));
        vm.assume(other != to);
        
        amount = bound(amount, 0, TOTAL_SUPPLY);
        approval = bound(approval, amount, type(uint256).max);
        
        testToken.approve(other, approval);
        
        uint256 balanceFromBefore = testToken.balanceOf(address(this));
        uint256 balanceToBefore = testToken.balanceOf(to);
        uint256 allowanceBefore = testToken.allowance(address(this), other);
        
        vm.prank(other);
        bool success = testToken.transferFrom(address(this), to, amount);
        assertTrue(success);
        
        assertEq(testToken.balanceOf(address(this)), balanceFromBefore - amount);
        assertEq(testToken.balanceOf(to), balanceToBefore + amount);
        
        if (approval != type(uint256).max) {
            assertEq(testToken.allowance(address(this), other), allowanceBefore - amount);
        } else {
            assertEq(testToken.allowance(address(this), other), type(uint256).max);
        }
        
        // Total supply should remain constant
        assertEq(testToken.totalSupply(), TOTAL_SUPPLY);
    }
    
    function testFuzz_PermitValues(uint256 value, uint256 deadline) public {
        // Bound inputs to reasonable ranges
        value = bound(value, 0, type(uint128).max);
        deadline = bound(deadline, block.timestamp, block.timestamp + 365 days);
        
        uint256 privateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address signer = vm.addr(privateKey);
        
        bytes32 digest = getApprovalDigest(pair, signer, other, value, pair.nonces(signer), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        
        pair.permit(signer, other, value, deadline, v, r, s);
        assertEq(pair.allowance(signer, other), value);
        assertEq(pair.nonces(signer), 1);
    }
    
    // Helper function to get approval digest for permit
    function getApprovalDigest(
        CustomUniswapV2Pair token,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                '\x19\x01',
                token.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline))
            )
        );
    }
    
    function test_Permit() public {
        // Add some liquidity to get LP tokens for permit testing
        PairFixture memory fixture = createPairFixture();
        MockERC20 token0 = fixture.token0;
        MockERC20 token1 = fixture.token1;
        CustomUniswapV2Pair liquidityPair = fixture.pair;
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(4);
        
        token0.transfer(address(liquidityPair), token0Amount);
        token1.transfer(address(liquidityPair), token1Amount);
        uint256 liquidity = liquidityPair.mint(address(this));
        
        assertTrue(liquidity > 0);
        
        // Setup permit test
        uint256 nonce = liquidityPair.nonces(wallet);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = liquidity / 2;
        
        // Create permit signature
        bytes32 digest = getApprovalDigest(liquidityPair, wallet, other, value, nonce, deadline);
        
        // Create a private key for testing
        uint256 privateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address signer = vm.addr(privateKey);
        
        // Transfer some LP tokens to the signer for testing
        liquidityPair.transfer(signer, liquidity);
        
        // Get the digest for the signer
        bytes32 signerDigest = getApprovalDigest(liquidityPair, signer, other, value, liquidityPair.nonces(signer), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, signerDigest);
        
        // Check initial state
        assertEq(liquidityPair.allowance(signer, other), 0);
        assertEq(liquidityPair.nonces(signer), 0);
        
        // Execute permit
        liquidityPair.permit(signer, other, value, deadline, v, r, s);
        
        // Verify permit worked
        assertEq(liquidityPair.allowance(signer, other), value);
        assertEq(liquidityPair.nonces(signer), 1);
    }
    
    function test_PermitExpired() public {
        uint256 privateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address signer = vm.addr(privateKey);
        
        uint256 deadline = block.timestamp - 1; // expired
        uint256 value = TEST_AMOUNT;
        
        bytes32 digest = getApprovalDigest(pair, signer, other, value, pair.nonces(signer), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        
        vm.expectRevert("UniswapV2: EXPIRED");
        pair.permit(signer, other, value, deadline, v, r, s);
    }
    
    function test_PermitInvalidSignature() public {
        uint256 privateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        address signer = vm.addr(privateKey);
        
        uint256 deadline = block.timestamp + 1 hours;
        uint256 value = TEST_AMOUNT;
        
        bytes32 digest = getApprovalDigest(pair, signer, other, value, pair.nonces(signer), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        
        // Use wrong signer address
        address wrongSigner = makeAddr("wrongSigner");
        
        vm.expectRevert("UniswapV2: INVALID_SIGNATURE");
        pair.permit(wrongSigner, other, value, deadline, v, r, s);
    }
    
    function test_LiquidityTokenTransferWithCustomFees() public {
        // Add some liquidity to get LP tokens
        PairFixture memory fixture = createPairFixture();
        MockERC20 token0 = fixture.token0;
        MockERC20 token1 = fixture.token1;
        CustomUniswapV2Pair liquidityPair = fixture.pair;
        
        // Set custom fee rate for testing
        vm.prank(deployer);
        factory.setCustomFeeRate(100); // 1% fee
        
        // Set fee recipient
        vm.prank(deployer);
        factory.setFeeTo(deployer);
        
        uint256 token0Amount = TestUtilities.expandTo18Decimals(1);
        uint256 token1Amount = TestUtilities.expandTo18Decimals(4);
        
        token0.transfer(address(liquidityPair), token0Amount);
        token1.transfer(address(liquidityPair), token1Amount);
        uint256 liquidity = liquidityPair.mint(address(this));
        
        assertTrue(liquidity > 0);
        assertEq(liquidityPair.balanceOf(address(this)), liquidity);
        
        // Test transfer of LP tokens (should work normally as custom fees apply only to swaps)
        bool success = liquidityPair.transfer(other, liquidity / 2);
        assertTrue(success);
        
        assertEq(liquidityPair.balanceOf(address(this)), liquidity / 2);
        assertEq(liquidityPair.balanceOf(other), liquidity / 2);
    }
}
