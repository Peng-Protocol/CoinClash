// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.1;

interface IERC20 {
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256); // Added for OMFAgent prepListing
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}