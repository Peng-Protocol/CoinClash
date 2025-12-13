// SPDX-License-Identifier: BSL 1.1
pragma solidity ^0.8.2;

// File Version: 0.0.1 (24/11/2025)  // Initial version for this file, incrementing third numerator from implied 0.0.0
// Changelog Summary:
// - 24/11/2025: Fixed explicit type conversion error from "address" to "contract MockUniPair" by casting pair addresses to payable before conversion, as MockUniPair has a payable fallback.

import "./MockUniFactory.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
    function transfer(address to, uint value) external returns (bool);
}

contract MockUniRouter {
    address public immutable factory;
    address public immutable WETH;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, "MockUniRouter: EXPIRED");
        _;
    }

    constructor(address _factory, address _weth) {
        factory = _factory;
        WETH = _weth;
    }

    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // ============ Library Logic (Inlined for simplicity) ============

    // Returns sorted token addresses, used to handle return values from pairs
    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "MockUniRouter: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "MockUniRouter: ZERO_ADDRESS");
    }

    // Calculates the CREATE2 address for a pair without making any external calls
    // NOTE: This must match our MockUniFactory's creation logic. 
    // Since MockUniFactory uses create2, we can just ask the factory to ensure 100% accuracy in tests.
    function pairFor(address tokenA, address tokenB) internal view returns (address pair) {
        pair = MockUniFactory(factory).getPair(tokenA, tokenB);
        require(pair != address(0), "MockUniRouter: PAIR_NOT_FOUND");
    }

    // Standard Uniswap V2 Pricing Formula (0.3% fee)
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) public pure returns (uint amountOut) {
        require(amountIn > 0, "MockUniRouter: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "MockUniRouter: INSUFFICIENT_LIQUIDITY");
        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * reserveOut;
        uint denominator = (reserveIn * 1000) + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // Performs chained getAmountOut calculations for any path
    // CHANGELOG 24/11/2025 - Fixed type conversion by casting to payable
// • Declared pair as address payable using payable(pairFor(...))
function getAmountsOut(uint amountIn, address[] memory path) public view returns (uint[] memory amounts) {
    require(path.length >= 2, "MockUniRouter: INVALID_PATH");
    amounts = new uint[](path.length);
    amounts[0] = amountIn;
    for (uint i; i < path.length - 1; i++) {
        address payable pair = payable(pairFor(path[i], path[i + 1]));
        (uint reserveIn, uint reserveOut,) = MockUniPair(pair).getReserves();
        // Sort reserves to match path direction
        (address token0,) = sortTokens(path[i], path[i + 1]);
        if (path[i] == token0) {
             // Reserves are already (0, 1)
        } else {
            (reserveIn, reserveOut) = (reserveOut, reserveIn);
        }
        amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
    }
}

    // ============ Swap Execution ============

    // Internal function to traverse the path and trigger swaps
    // CHANGELOG 24/11/2025 - Fixed type conversion by casting to payable
// • Declared pair as address payable using payable(pairFor(...))
function _swap(uint[] memory amounts, address[] memory path, address _to) internal {
    for (uint i; i < path.length - 1; i++) {
        (address input, address output) = (path[i], path[i + 1]);
        (address token0,) = sortTokens(input, output);
        uint amountOut = amounts[i + 1];
        
        // If output is token0, we want (amountOut, 0). If output is token1, we want (0, amountOut)
        (uint amount0Out, uint amount1Out) = input == token0 
            ? (uint(0), amountOut) 
            : (amountOut, uint(0));
        
        address to = i < path.length - 2 ? pairFor(output, path[i + 2]) : _to;
        
        address payable pair = payable(pairFor(input, output));
        MockUniPair(pair).swap(amount0Out, amount1Out, to, new bytes(0));
    }
    }

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual ensure(deadline) returns (uint[] memory amounts) {
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "MockUniRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        
        // Transfer user tokens to the first pair
        address pair = pairFor(path[0], path[1]);
        IERC20(path[0]).transferFrom(msg.sender, pair, amounts[0]);
        
        _swap(amounts, path, to);
    }

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable virtual ensure(deadline) returns (uint[] memory amounts) {
        require(path[0] == WETH, "MockUniRouter: INVALID_PATH");
        
        amounts = getAmountsOut(msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "MockUniRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        
        // Wrap ETH -> WETH
        IWETH(WETH).deposit{value: amounts[0]}();
        
        // Send WETH to the first pair
        address pair = pairFor(path[0], path[1]);
        assert(IWETH(WETH).transfer(pair, amounts[0]));
        
        _swap(amounts, path, to);
    }

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual ensure(deadline) returns (uint[] memory amounts) {
        require(path[path.length - 1] == WETH, "MockUniRouter: INVALID_PATH");
        
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "MockUniRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        
        // Transfer user tokens to the first pair
        address pair = pairFor(path[0], path[1]);
        IERC20(path[0]).transferFrom(msg.sender, pair, amounts[0]);
        
        // Router receives the WETH output of the final swap
        _swap(amounts, path, address(this));
        
        // Unwrap WETH -> ETH and send to user
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        (bool success, ) = to.call{value: amounts[amounts.length - 1]}("");
        require(success, "MockUniRouter: ETH_TRANSFER_FAILED");
    }
}