// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

// a library for performing overflow-safe math, courtesy of DappHub (https://github.com/dapphub/ds-math)
// Updated for Solidity 0.8.28 - removed overflow checks as they're built-in now

library SafeMath {
    function add(uint x, uint y) internal pure returns (uint z) {
        z = x + y;
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        z = x - y;
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        z = x * y;
    }
}
