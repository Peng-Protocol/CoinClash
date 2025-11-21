// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.2 (07/11/2025)
// Changelog:
// - 07/11/2025: Added payable to proxyCall for ETH transfers.
// - 04/11/2025: Derived from MockKarahTester, removed interface. 

contract MockMailTester {
    address public owner;
    constructor(address _owner) { owner = _owner; }
    receive() external payable {}
    
    event ProxyError(string reason);

    function proxyCall(address target, bytes memory data) external payable {
    require(msg.sender == owner, "Not owner");
    (bool success, bytes memory returnData) = target.call{value: msg.value}(data);
    if (!success) {
        if (returnData.length > 0) {
            assembly { revert(add(returnData, 0x20), mload(returnData)) }
        } else {
            revert("Proxy failed (no revert data)");
        }
    }
}
}