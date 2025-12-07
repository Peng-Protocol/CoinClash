// SPDX-License-Identifier: MIT
// Version: 0.0.4 - Added onlyOwner modifier for addReenterer and removeReenterer
// Modified from OpenZeppelin ReentrancyGuard v4.9.0 - Peng Protocol
// Note: In dependent contracts, import Ownable before ReentrancyGuard to ensure proper inheritance

pragma solidity ^0.8.2;

import "./Ownable.sol";

abstract contract ReentrancyGuard is Ownable {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _status;
    mapping(address => bool) private _reentrancyExceptions; // Tracks addresses allowed to reenter

    constructor() {
        _status = _NOT_ENTERED;
    }

    modifier nonReentrant() {
        if (!_reentrancyExceptions[msg.sender]) {
            _nonReentrantBefore();
        }
        _;
        if (!_reentrancyExceptions[msg.sender]) {
            _nonReentrantAfter();
        }
    }

    function _nonReentrantBefore() private {
        require(_status != _ENTERED, "ReentrancyGuard: reentrant call");
        _status = _ENTERED;
    }

    function _nonReentrantAfter() private {
        _status = _NOT_ENTERED;
    }

    // Adds address to reentrancy exception list
    function addReenterer(address account) external onlyOwner {
        require(account != address(0), "ReentrancyGuard: zero address");
        _reentrancyExceptions[account] = true; // Allows reentrancy for account
    }

    // Removes address from reentrancy exception list
    function removeReenterer(address account) external onlyOwner {
        require(account != address(0), "ReentrancyGuard: zero address");
        _reentrancyExceptions[account] = false; // Disallows reentrancy for account
    }

    // Checks if address is in exception list
    function isReentrancyException(address account) external view returns (bool) {
        return _reentrancyExceptions[account]; // Returns true if account can reenter
    }
}