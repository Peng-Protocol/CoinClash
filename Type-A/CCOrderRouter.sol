// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.2.1
// Changes:
// - v0.2.1 (21/11/2025): Now uses dynamic WETH address, transfers principal to listing. 

import "./utils/CCOrderPartial.sol";

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

contract CCOrderRouter is CCOrderPartial {
    function createBuyOrder(
        address startToken,
        address endToken,
        address recipientAddress,
        uint256 inputAmount,
        uint256 maxPrice,
        uint256 minPrice
    ) external payable nonReentrant {
        // Creates buy order (buying endToken with startToken)
        // startToken is what user pays with, endToken is what they receive
        require(startToken != endToken, "Tokens must be different");
        require(!(startToken == address(0) && endToken == address(0)), "Both tokens cannot be native");
        
        _validateUniswapPair(startToken, endToken);
        
        bool isStartTokenNative = (startToken == address(0));
        
        OrderPrep memory prep = _handleOrderPrep(
            msg.sender,
            recipientAddress,
            startToken,
            endToken,
            inputAmount,
            maxPrice,
            minPrice,
            true
        );
        
        (prep.amountReceived, prep.normalizedReceived) = _validateAndTransfer(
            startToken,
            msg.sender,
            inputAmount,
            isStartTokenNative
        );
        
        _executeSingleOrder(prep, true);
    }

    function createSellOrder(
        address startToken,
        address endToken,
        address recipientAddress,
        uint256 inputAmount,
        uint256 maxPrice,
        uint256 minPrice
    ) external payable nonReentrant {
        // Creates sell order (selling startToken for endToken)
        // startToken is what user sells, endToken is what they receive
        require(startToken != endToken, "Tokens must be different");
        require(!(startToken == address(0) && endToken == address(0)), "Both tokens cannot be native");
        
        _validateUniswapPair(startToken, endToken);
        
        bool isStartTokenNative = (startToken == address(0));
        
        OrderPrep memory prep = _handleOrderPrep(
            msg.sender,
            recipientAddress,
            startToken,
            endToken,
            inputAmount,
            maxPrice,
            minPrice,
            false
        );
        
        (prep.amountReceived, prep.normalizedReceived) = _validateAndTransfer(
            startToken,
            msg.sender,
            inputAmount,
            isStartTokenNative
        );
        
        _executeSingleOrder(prep, false);
    }

    function _validateAndTransfer(
    address token,
    address from,
    uint256 inputAmount,
    bool isNative
) internal returns (uint256 amountReceived, uint256 normalizedReceived) {
    // Unified transfer validation for both native and ERC20 tokens
    // Transfers to this contract, AND forwards to listing template
    if (isNative) {
        require(msg.value == inputAmount, "Incorrect ETH amount");
        amountReceived = msg.value;
        normalizedReceived = normalize(amountReceived, 18);
        require(amountReceived > 0, "No ETH received");

        // FIX: Forward ETH to listing template so it holds the funds for refunds
        (bool success,) = listingTemplate.call{value: amountReceived}("");
        require(success, "ETH forwarding failed");
    } else {
        require(token != address(0), "Token must be ERC20");
        uint8 tokenDecimals = IERC20(token).decimals();
        
        // Transfer from user to Router first
        uint256 allowance = IERC20(token).allowance(from, address(this));
        require(allowance >= inputAmount, "Insufficient token allowance");
        
        uint256 preBalance = IERC20(token).balanceOf(address(this));
        IERC20(token).transferFrom(from, address(this), inputAmount);
        uint256 postBalance = IERC20(token).balanceOf(address(this));
        
        amountReceived = postBalance > preBalance ? postBalance - preBalance : 0;
        normalizedReceived = amountReceived > 0 ? normalize(amountReceived, tokenDecimals) : 0;
        
        require(amountReceived > 0, "No tokens received");

        // FIX: Forward Tokens to listing template so it holds the funds for refunds
        IERC20(token).transfer(listingTemplate, amountReceived);
    }
}

    function _validateUniswapPair(address tokenA, address tokenB) internal view {
        // Validates that Uniswap V2 pair exists with non-zero reserves
        require(listingTemplate != address(0), "Listing template not set");
        
        address factory = ICCListing(listingTemplate).uniswapV2Factory();
        require(factory != address(0), "Factory not set");
        
        // Convert address(0) to WETH for native tokens
        address token0 = tokenA == address(0) ? _getWETH() : tokenA;
        address token1 = tokenB == address(0) ? _getWETH() : tokenB;
        
        address pairAddress = IUniswapV2Factory(factory).getPair(token0, token1);
        require(pairAddress != address(0), "Uniswap pair does not exist");
        
        // Verify pair has liquidity
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pairAddress).getReserves();
        require(reserve0 > 0 && reserve1 > 0, "Uniswap pair has no liquidity");
    }

    function _getWETH() internal view returns (address) {
    // Returns configured WETH or defaults to Mainnet if not set
    return wethAddress != address(0) ? wethAddress : address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
}

    function clearSingleOrder(uint256 orderIdentifier, bool isBuyOrder) 
        external 
        nonReentrant 
    {
        // Clears a single order, maker check in _clearOrderData
        _clearOrderData(orderIdentifier, isBuyOrder);
    }

    function clearOrders(uint256 maxIterations) 
        external 
        nonReentrant 
    {
        // Clears multiple orders for msg.sender up to maxIterations
        require(listingTemplate != address(0), "Listing template not set");
        
        ICCListing listingContract = ICCListing(listingTemplate);
        uint256[] memory orderIds = listingContract.makerPendingOrdersView(msg.sender);
        uint256 iterationCount = maxIterations < orderIds.length ? maxIterations : orderIds.length;
        
        for (uint256 i = 0; i < iterationCount; i++) {
            uint256 orderId = orderIds[i];
            
            // Check if it's a buy order
            (address[] memory buyAddresses,,,) = listingContract.getBuyOrder(orderId);
            if (buyAddresses.length > 0 && buyAddresses[0] == msg.sender) {
                _clearOrderData(orderId, true);
                continue;
            }
            
            // Check if it's a sell order
            (address[] memory sellAddresses,,,) = listingContract.getSellOrder(orderId);
            if (sellAddresses.length > 0 && sellAddresses[0] == msg.sender) {
                _clearOrderData(orderId, false);
            }
        }
    }
}