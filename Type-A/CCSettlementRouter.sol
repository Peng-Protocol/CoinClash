// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.4.5 (27/11/2025)
// Changes:
// - (27/11/2025): Further refactored to eliminate stack-too-deep in _processAllOrders
// - Split order processing into more granular functions with minimal stack usage

import "./utils/CCSettlementPartial.sol";

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract CCSettlementRouter is CCSettlementPartial {

    // Temporary struct to pass data between functions
    struct ProcessingState {
        uint256 settledCount;
        address firstStartToken;
        address firstEndToken;
        bool hasTrackedPair;
    }

    function _validateOrder(
        address listingAddress,
        uint256 orderId,
        bool isBuyOrder,
        ICCListing listingContract
    ) internal returns (bool valid) {
        (address[] memory addresses, uint256[] memory prices_, uint256[] memory amounts, uint8 status) = 
            isBuyOrder ? listingContract.getBuyOrder(orderId) : listingContract.getSellOrder(orderId);
        
        if (amounts[0] == 0) {
            emit OrderSkipped(orderId, "No pending amount");
            return false;
        }
        
        if (status != 1 && status != 2) {
            emit OrderSkipped(orderId, "Invalid status - must be pending or partially filled");
            return false;
        }
        
        return true;
    }

    function _updateOrder(
        ICCListing listingContract,
        OrderContext memory context,
        bool isBuyOrder
    ) internal returns (bool success, string memory reason) {
        if ((isBuyOrder && context.buyUpdates.length == 0) || (!isBuyOrder && context.sellUpdates.length == 0)) {
            return (false, "");
        }
        
        try listingContract.ccUpdate(
            isBuyOrder ? context.buyUpdates : new ICCListing.BuyOrderUpdate[](0),
            isBuyOrder ? new ICCListing.SellOrderUpdate[](0) : context.sellUpdates,
            new ICCListing.HistoricalUpdate[](0)
        ) {
            (, , uint256[] memory amounts, uint8 newStatus) = isBuyOrder
                ? listingContract.getBuyOrder(context.orderId)
                : listingContract.getSellOrder(context.orderId);
            
            context.status = newStatus;
            if (context.status == 0 || context.status == 3) {
                return (false, "");
            }
            return (true, "");
        } catch Error(string memory updateReason) {
            return (false, string(abi.encodePacked("Update failed for order ", uint2str(context.orderId), ": ", updateReason)));
        }
    }

    function _createHistoricalEntry(
        ICCListing listingContract,
        address tokenA,
        address tokenB
    ) private {
        uint256 price = listingContract.prices(tokenA, tokenB);
        
        address factory = listingContract.uniswapV2Factory();
        require(factory != address(0), "Factory not set");
        address pairAddress = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), "Pair does not exist");
        
        uint8 decimalsA = _getTokenDecimals(tokenA);
        uint8 decimalsB = _getTokenDecimals(tokenB);
        
        uint256 xBalance = normalize(IERC20(tokenA).balanceOf(pairAddress), decimalsA);
        uint256 yBalance = normalize(IERC20(tokenB).balanceOf(pairAddress), decimalsB);
        
        uint256 xVolume = 0;
        uint256 yVolume = 0;
        uint256 historicalLength = listingContract.historicalDataLengthView(tokenA, tokenB);
        
        if (historicalLength > 0) {
            ICCListing.HistoricalData memory historicalData = listingContract.getHistoricalDataView(tokenA, tokenB, historicalLength - 1);
            xVolume = historicalData.xVolume;
            yVolume = historicalData.yVolume;
        }
        
        ICCListing.HistoricalUpdate[] memory historicalUpdates = new ICCListing.HistoricalUpdate[](1);
        historicalUpdates[0] = ICCListing.HistoricalUpdate({
            tokenA: tokenA,
            tokenB: tokenB,
            price: price,
            xBalance: xBalance,
            yBalance: yBalance,
            xVolume: xVolume,
            yVolume: yVolume,
            timestamp: block.timestamp
        });
        
        try listingContract.ccUpdate(
            new ICCListing.BuyOrderUpdate[](0),
            new ICCListing.SellOrderUpdate[](0),
            historicalUpdates
        ) {} catch Error(string memory updateReason) {
            revert(string(abi.encodePacked("Failed to create historical data entry: ", updateReason)));
        }
    }

    function settleOrders(
        address listingAddress,
        uint256[] calldata orderIds,
        uint256[] calldata amountsIn,
        bool isBuyOrder
    ) external nonReentrant returns (string memory reason) {
        require(listingTemplate != address(0), "Listing template not set");
        require(listingAddress == listingTemplate, "Invalid listing address");
        require(orderIds.length == amountsIn.length, "Order IDs and amounts length mismatch");
        require(orderIds.length > 0, "No orders to settle");

        ICCListing listingContract = ICCListing(listingAddress);
        
        ProcessingState memory state = ProcessingState({
            settledCount: 0,
            firstStartToken: address(0),
            firstEndToken: address(0),
            hasTrackedPair: false
        });

        for (uint256 i = 0; i < orderIds.length; i++) {
            _processSingleOrder(
                listingContract,
                orderIds[i],
                amountsIn[i],
                isBuyOrder,
                listingAddress,
                state
            );
        }

        if (state.settledCount > 0 && state.firstStartToken != address(0)) {
            _createHistoricalEntry(listingContract, state.firstStartToken, state.firstEndToken);
        }

        if (state.settledCount == 0) {
            return "No orders settled: price/impact check failed";
        }
        return "";
    }

    function _processSingleOrder(
        ICCListing listingContract,
        uint256 orderId,
        uint256 amountIn,
        bool isBuyOrder,
        address listingAddress,
        ProcessingState memory state
    ) private {
        if (amountIn == 0) return;

        // Validate order status and pending amount
        (, , uint256[] memory amounts, uint8 status) = isBuyOrder 
            ? listingContract.getBuyOrder(orderId) 
            : listingContract.getSellOrder(orderId);

        if (amounts[0] == 0 || (status != 1 && status != 2)) {
            emit OrderSkipped(orderId, status != 1 && status != 2 ? "Invalid status" : "No pending amount");
            return;
        }

        // Get settlement context
        SettlementContext memory ctx = _getOrderTokenContext(listingContract, orderId, isBuyOrder);

        // Check pricing
        if (!_performPricingCheck(listingContract, orderId, amountIn, isBuyOrder, ctx)) {
            return;
        }

        // Track first pair
        if (!state.hasTrackedPair) {
            state.firstStartToken = isBuyOrder ? ctx.tokenB : ctx.tokenA;
            state.firstEndToken = isBuyOrder ? ctx.tokenA : ctx.tokenB;
            state.hasTrackedPair = true;
        }

        // Process and update
        if (_executeAndUpdate(listingContract, orderId, amountIn, isBuyOrder, listingAddress, ctx)) {
            state.settledCount++;
        }
    }

    function _performPricingCheck(
        ICCListing listingContract,
        uint256 orderId,
        uint256 amountIn,
        bool isBuyOrder,
        SettlementContext memory ctx
    ) private returns (bool) {
        (, uint256[] memory prices, , ) = isBuyOrder 
            ? listingContract.getBuyOrder(orderId) 
            : listingContract.getSellOrder(orderId);

        if (!_checkPricing(orderId, amountIn, isBuyOrder, prices, ctx)) {
            emit OrderSkipped(orderId, "Impact Price out of bounds");
            return false;
        }
        return true;
    }

    function _executeAndUpdate(
        ICCListing listingContract,
        uint256 orderId,
        uint256 amountIn,
        bool isBuyOrder,
        address listingAddress,
        SettlementContext memory ctx
    ) private returns (bool success) {
        OrderContext memory orderCtx = OrderContext({
            orderId: orderId,
            pending: 0,
            status: 0,
            buyUpdates: new ICCListing.BuyOrderUpdate[](0),
            sellUpdates: new ICCListing.SellOrderUpdate[](0)
        });

        if (isBuyOrder) {
            orderCtx.buyUpdates = _processBuyOrder(listingAddress, orderId, amountIn, listingContract, ctx);
        } else {
            orderCtx.sellUpdates = _processSellOrder(listingAddress, orderId, amountIn, listingContract, ctx);
        }

        (success, ) = _updateOrder(listingContract, orderCtx, isBuyOrder);
    }
    
    function _getOrderTokenContext(
        ICCListing listingContract,
        uint256 orderId,
        bool isBuyOrder
    ) internal view returns (SettlementContext memory settlementContext) {
        (address[] memory addresses, , , ) = isBuyOrder
            ? listingContract.getBuyOrder(orderId)
            : listingContract.getSellOrder(orderId);
        
        address startToken = addresses[2];
        address endToken = addresses[3];
        
        uint8 startDecimals = _getTokenDecimals(startToken);
        uint8 endDecimals = _getTokenDecimals(endToken);
        
        address pairAddress = _getPairAddress(listingContract, startToken, endToken);
        
        settlementContext.tokenA = isBuyOrder ? endToken : startToken;
        settlementContext.tokenB = isBuyOrder ? startToken : endToken;
        settlementContext.decimalsA = isBuyOrder ? endDecimals : startDecimals;
        settlementContext.decimalsB = isBuyOrder ? startDecimals : endDecimals;
        settlementContext.uniswapV2Pair = pairAddress;
    }
    
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == address(0)) return 18;
        try IERC20(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18;
        }
    }
    
    function _getPairAddress(
        ICCListing listingContract,
        address tokenA,
        address tokenB
    ) internal view returns (address) {
        address factory = listingContract.uniswapV2Factory();
        require(factory != address(0), "Factory not set");
        
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        address pair = IUniswapV2Factory(factory).getPair(token0, token1);
        
        require(pair != address(0), "Pair does not exist");
        return pair;
    }
}