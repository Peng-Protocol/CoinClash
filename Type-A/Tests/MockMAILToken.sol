// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.1 (07/11/2025)
// Changelog:
// - 07/11/2025: Initial MockMAILToken with 6 decimals, setDetails flexibility

contract MockMAILToken {
    string public name = "Mock MAIL";
    string public symbol = "MMAIL";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor() {
        // 10,000,000 tokens to deployer
        _mint(msg.sender, 10_000_000 * 1e18);
    }

    function setDetails(
        string calldata _name,
        string calldata _symbol,
        uint8 _decimals
    ) external {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function mint(address to, uint256 amount) external { _mint(to, amount); }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}