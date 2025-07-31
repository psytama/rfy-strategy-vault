// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ERC20Mock
 * @dev Mock ERC20 token for testing purposes
 */
contract ERC20Mock is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function setDecimals(uint8 decimals_) public {
        _decimals = decimals_;
    }
}
