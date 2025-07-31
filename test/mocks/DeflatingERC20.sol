// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract DeflatingERC20 is ERC20 {
    uint256 public feeRate = 100; // 1% fee (100 basis points)
    
    constructor(uint256 _totalSupply) ERC20("Deflating Token", "DTT") {
        _mint(msg.sender, _totalSupply);
    }
    
    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeRate) / 10000;
        uint256 transferAmount = amount - fee;
        
        _transfer(_msgSender(), to, transferAmount);
        if (fee > 0) {
            _burn(_msgSender(), fee);
        }
        
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * feeRate) / 10000;
        uint256 transferAmount = amount - fee;
        
        address spender = _msgSender();
        _spendAllowance(from, spender, amount);
        _transfer(from, to, transferAmount);
        if (fee > 0) {
            _burn(from, fee);
        }
        
        return true;
    }
    
    function setFeeRate(uint256 _feeRate) external {
        require(_feeRate <= 1000, "Fee rate too high"); // Max 10%
        feeRate = _feeRate;
    }
}
