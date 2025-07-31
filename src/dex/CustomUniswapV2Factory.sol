// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import './interfaces/ICustomUniswapV2Factory.sol';
import './CustomUniswapV2Pair.sol';

contract CustomUniswapV2Factory is ICustomUniswapV2Factory {
    address public feeTo;
    address public feeToSetter;
    uint256 public customFeeRate = 30; // 0.3% in basis points (30/10000) - ONLY ADDITION

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    constructor(address _feeToSetter) {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(CustomUniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        CustomUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
        emit FeeToUpdated(_feeTo);
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }

    // ONLY ADDITION - Custom fee rate management
    function setCustomFeeRate(uint256 _customFeeRate) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        require(_customFeeRate <= 1000, 'UniswapV2: FEE_TOO_HIGH'); // Max 10%
        customFeeRate = _customFeeRate;
        emit CustomFeeRateUpdated(_customFeeRate);
    }
}
