// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC4626 } from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20, ERC20 } from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockERC4626Vault is ERC4626 {
    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol
    
    ) ERC20(_name, _symbol) ERC4626(_asset) {}

}