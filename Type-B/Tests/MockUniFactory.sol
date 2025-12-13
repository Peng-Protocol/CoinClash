// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.2 (21/11/2025)
// Changelog Summary:
// - 21/11/2025: Fixed explicit type conversion error from "address" → "MockUniPair" by returning address payable from create2 and using address(pair) cast only where required

import "./MockUniPair.sol";

contract MockUniFactory {
    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;
    address public WETH;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);

    constructor(address _weth) {
        WETH = _weth;
    }

    // CHANGELOG 21/11/2025 - Fixed type conversion error
    // • Return type changed to "address payable" so create2 result can be stored directly
    // • Explicit cast to MockUniPair now allowed because the variable is payable
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, "Identical addresses");
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "Zero address");
        require(getPair[token0][token1] == address(0), "Pair exists");

        // Deploy new pair
        bytes memory bytecode = type(MockUniPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        
        // create2 returns a payable address - store it directly in a payable variable
        address payable newPair;
        
        assembly {
            newPair := create2(0, add(bytecode, 32), mload(bytecode), salt)
            if iszero(newPair) { revert(0, 0) } // revert on failure
        }

        // Safe: newPair is payable → conversion to contract type is allowed
        MockUniPair(newPair).initialize(token0, token1);

        // Store the plain address in mapping and array (non-payable is fine here)
        pair = address(newPair);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }
}