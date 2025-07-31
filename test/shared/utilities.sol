// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Math } from "../../src/dex/libraries/Math.sol";

library TestUtilities {
    uint256 constant DECIMALS_18 = 10**18;
    
    function expandTo18Decimals(uint256 n) internal pure returns (uint256) {
        return n * DECIMALS_18;
    }
    
    function encodePrice(uint112 reserve0, uint112 reserve1) internal pure returns (uint256 price0, uint256 price1) {
        uint256 Q112 = 2**112;
        price0 = (uint256(reserve1) * Q112) / uint256(reserve0);
        price1 = (uint256(reserve0) * Q112) / uint256(reserve1);
    }
    
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        return Math.sqrt(y);
    }
}
