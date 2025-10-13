/*
 SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
 Version: 0.0.51 (13/10/2025)
 Changes:
 - v0.0.51 (13/10): Updated _computeFeePercent for 0.05% min fee at ≤1% liquidity usage, scaling to 0.10% at 2%, 0.50% at 10%, up to 50% at 100%.
 - v0.0.50 (11/10): Refactored _processSingleOrder to resolve stack too deep error by splitting into _validateLiquidity, _checkUniswapBalance, and _executeOrder, each handling ≤4 variables. Removed unused parameters: orderIdentifier from _prepareLiquidityUpdates, isBuyOrder from _computeUpdateStatus, maxIterations from _collectOrderIdentifiers, tokenDecimals from _prepareLiquidityUpdates, pendingAmount from _executeOrderWithFees, recipientAddress from _computeAmountSent, and result from _processSingleOrder. Added UniswapLiquidityExcess event and check in _checkUniswapBalance. Consolidated fee updates in _updateFees.
 - v0.0.49: Added Uniswap LP balance check in _processSingleOrder to prevent settlement if Uniswap LP output token balance exceeds xLiquid/yLiquid. (11/10/2025)
 - v0.0.48: Refactored _computeFee into _getLiquidityData, _computeFeePercent, _finalizeFee. (Previous changes omitted for brevity)
 Compatible with CCListingTemplate.sol v0.3.9, CCLiquidityTemplate.sol v0.1.20, CCLiquidRouter.sol v0.0.25, CCMainPartial.sol v0.1.5.
*/

pragma solidity ^0.8.2;

import "./CCMainPartial.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}

contract CCLiquidPartial is CCMainPartial {
    struct OrderContext {
        ICCListing listingContract;
        address tokenIn;
        address tokenOut;
    }

    struct PrepOrderUpdateResult {
        address makerAddress;
        address recipientAddress;
        uint256 amountReceived;
        uint256 normalizedReceived;
        uint256 amountSent;
        uint8 status;
    }

    struct BuyOrderUpdateContext {
        address makerAddress;
        address recipient;
        uint8 status;
        uint256 amountReceived;
        uint256 normalizedReceived;
        uint256 amountSent;
        uint256 preTransferWithdrawn;
    }

    struct SellOrderUpdateContext {
        address makerAddress;
        address recipient;
        uint8 status;
        uint256 amountReceived;
        uint256 normalizedReceived;
        uint256 amountSent;
        uint256 preTransferWithdrawn;
    }

    struct OrderBatchContext {
        address listingAddress;
        uint256 maxIterations;
        bool isBuyOrder;
    }

    struct SwapImpactContext {
        uint256 reserveIn;
        uint256 reserveOut;
        uint8 decimalsIn;
        uint8 decimalsOut;
        uint256 amountInAfterFee;
        uint256 price;
        uint256 amountOut;
    }

    struct FeeContext {
        uint256 feeAmount;
        uint256 netAmount;
        uint256 liquidityAmount;
        uint8 decimals;
    }

    struct OrderProcessingContext {
        uint256 maxPrice;
        uint256 minPrice;
        uint256 currentPrice;
        uint256 impactPrice;
    }

    struct LiquidityUpdateContext {
        uint256 pendingAmount;
        uint256 amountOut;
        bool isBuyOrder;
    }

    struct FeeCalculationContext {
        uint256 outputLiquidityAmount;
        uint8 outputDecimals;
        uint256 normalizedAmountSent;
        uint256 normalizedLiquidity;
    }

    struct LiquidityValidationContext {
        uint256 normalizedPending;
        uint256 normalizedSettle;
        uint256 xLiquid;
        uint256 yLiquid;
    }

    struct UniswapBalanceContext {
        address outputToken;
        uint256 normalizedUniswapBalance;
        uint256 internalLiquidity;
    }

    event FeeDeducted(address indexed listingAddress, uint256 orderId, bool isBuyOrder, uint256 feeAmount, uint256 netAmount);
    event PriceOutOfBounds(address indexed listingAddress, uint256 orderId, uint256 impactPrice, uint256 maxPrice, uint256 minPrice);
    event MissingUniswapRouter(address indexed listingAddress, uint256 orderId, string reason);
    event TokenTransferFailed(address indexed listingAddress, uint256 orderId, address token, string reason);
    event SwapFailed(address indexed listingAddress, uint256 orderId, uint256 amountIn, string reason);
    event ApprovalFailed(address indexed listingAddress, uint256 orderId, address token, string reason);
    event UpdateFailed(address indexed listingAddress, string reason);
    event InsufficientBalance(address indexed listingAddress, uint256 required, uint256 available);
    event UniswapLiquidityExcess(address indexed listingAddress, uint256 orderId, bool isBuyOrder, uint256 uniswapBalance, uint256 internalLiquidity);

    function _getSwapReserves(address listingAddress, bool isBuyOrder) private view returns (SwapImpactContext memory context) {
        ICCListing listingContract = ICCListing(listingAddress);
        address pairAddress = listingContract.uniswapV2PairView();
        require(pairAddress != address(0), "Uniswap V2 pair not set");
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        address token0 = pair.token0();
        bool isToken0In = isBuyOrder ? listingContract.tokenB() == token0 : listingContract.tokenA() == token0;
        context.reserveIn = isToken0In ? IERC20(token0).balanceOf(pairAddress) : IERC20(listingContract.tokenB()).balanceOf(pairAddress);
        context.reserveOut = isToken0In ? IERC20(listingContract.tokenA()).balanceOf(pairAddress) : IERC20(token0).balanceOf(pairAddress);
        context.decimalsIn = isBuyOrder ? listingContract.decimalsB() : listingContract.decimalsA();
        context.decimalsOut = isBuyOrder ? listingContract.decimalsA() : listingContract.decimalsB();
    }

    function _computeCurrentPrice(address listingAddress) private view returns (uint256 price) {
        ICCListing listingContract = ICCListing(listingAddress);
        address pairAddress = listingContract.uniswapV2PairView();
        uint256 balanceA = listingContract.tokenA() == address(0) ? address(pairAddress).balance : IERC20(listingContract.tokenA()).balanceOf(pairAddress);
        uint256 balanceB = listingContract.tokenB() == address(0) ? address(pairAddress).balance : IERC20(listingContract.tokenB()).balanceOf(pairAddress);
        balanceA = normalize(balanceA, listingContract.decimalsA());
        balanceB = normalize(balanceB, listingContract.decimalsB());
        return balanceA == 0 ? 0 : (balanceB * 1e18) / balanceA;
    }

       // Computes pre-transfer balance of the contract for a token
    function _computeAmountSent(address tokenAddress) private view returns (uint256 preBalance) {
        preBalance = tokenAddress == address(0) ? address(this).balance : IERC20(tokenAddress).balanceOf(address(this));
    }

    function _computeUpdateStatus(uint256 normalizedReceived) private pure returns (uint8 updateStatus) {
        updateStatus = normalizedReceived > 0 ? 2 : 3;
    }

    function _getTokenAndDecimals(address listingAddress, bool isBuyOrder) internal view returns (address tokenAddress, uint8 tokenDecimals) {
        ICCListing listingContract = ICCListing(listingAddress);
        tokenAddress = isBuyOrder ? listingContract.tokenB() : listingContract.tokenA();
        tokenDecimals = isBuyOrder ? listingContract.decimalsB() : listingContract.decimalsA();
    }

        // Prepares buy order update data
    function _prepBuyOrderUpdate(address listingAddress, uint256 orderIdentifier, uint256 pendingAmount, uint256 amountOut) internal view returns (PrepOrderUpdateResult memory result) {
        ICCListing listingContract = ICCListing(listingAddress);
        (address maker, address recipient, uint8 status) = listingContract.getBuyOrderCore(orderIdentifier);
        (, , uint256 priorAmountSent) = listingContract.getBuyOrderAmounts(orderIdentifier);
        (address tokenAddress, ) = _getTokenAndDecimals(listingAddress, true);
        uint256 preBalance = _computeAmountSent(tokenAddress);
        result.makerAddress = maker;
        result.recipientAddress = recipient;
        result.amountReceived = amountOut;
        result.normalizedReceived = normalize(amountOut, listingContract.decimalsA());
        result.amountSent = priorAmountSent + normalize(pendingAmount, listingContract.decimalsB()) - preBalance;
        result.status = status == 1 ? _computeUpdateStatus(result.normalizedReceived) : status;
    }

        // Prepares sell order update data
    function _prepSellOrderUpdate(address listingAddress, uint256 orderIdentifier, uint256 pendingAmount, uint256 amountOut) internal view returns (PrepOrderUpdateResult memory result) {
        ICCListing listingContract = ICCListing(listingAddress);
        (address maker, address recipient, uint8 status) = listingContract.getSellOrderCore(orderIdentifier);
        (, , uint256 priorAmountSent) = listingContract.getSellOrderAmounts(orderIdentifier);
        (address tokenAddress, ) = _getTokenAndDecimals(listingAddress, false);
        uint256 preBalance = _computeAmountSent(tokenAddress);
        result.makerAddress = maker;
        result.recipientAddress = recipient;
        result.amountReceived = amountOut;
        result.normalizedReceived = normalize(amountOut, listingContract.decimalsB());
        result.amountSent = priorAmountSent + normalize(pendingAmount, listingContract.decimalsA()) - preBalance;
        result.status = status == 1 ? _computeUpdateStatus(result.normalizedReceived) : status;
    }

    function _computeSwapImpact(address listingAddress, uint256 amountIn, bool isBuyOrder) private view returns (uint256 price, uint256 amountOut) {
        SwapImpactContext memory context = _getSwapReserves(listingAddress, isBuyOrder);
        uint256 amountInWithFee = (amountIn * 997) / 1000;
        context.amountInAfterFee = amountInWithFee;
        context.price = context.reserveIn == 0 ? 0 : (context.reserveOut * 1e18) / context.reserveIn;
        amountOut = (context.reserveOut * amountInWithFee) / (context.reserveIn + amountInWithFee);
        price = context.price;
    }

    function _getLiquidityData(address listingAddress, bool isBuyOrder) private view returns (uint256 liquidityAmount, uint8 decimals) {
        ICCListing listingContract = ICCListing(listingAddress);
        ICCLiquidity liquidityContract = ICCLiquidity(listingContract.liquidityAddressView());
        (uint256 xLiquid, uint256 yLiquid) = liquidityContract.liquidityAmounts();
        liquidityAmount = isBuyOrder ? yLiquid : xLiquid;
        decimals = isBuyOrder ? listingContract.decimalsB() : listingContract.decimalsA();
    }

    function _computeFeePercent(uint256 amountIn, uint256 liquidityAmount) private pure returns (uint256 feePercent) {
    // Scales fee from 0.05% at ≤1% usage to 50% at 100% usage
    uint256 usagePercent = (amountIn * 1e18) / (liquidityAmount == 0 ? 1 : liquidityAmount);
    feePercent = (usagePercent * 5e15) / 1e16; // Linear scaling: 0.05% per 1% usage
    if (feePercent < 5e14) feePercent = 5e14; // 0.05% minimum
    if (feePercent > 5e17) feePercent = 5e17; // 50% maximum
}

    function _finalizeFee(uint256 amountIn, uint256 feePercent, uint8 decimals) private pure returns (FeeContext memory feeContext) {
        feeContext.feeAmount = (amountIn * feePercent) / 1e18;
        feeContext.netAmount = amountIn - feeContext.feeAmount;
        feeContext.decimals = decimals;
    }

    function _computeFee(address listingAddress, uint256 amountIn, bool isBuyOrder) private view returns (FeeContext memory feeContext) {
        (uint256 liquidityAmount, uint8 decimals) = _getLiquidityData(listingAddress, isBuyOrder);
        uint256 feePercent = _computeFeePercent(amountIn, liquidityAmount);
        feeContext = _finalizeFee(amountIn, feePercent, decimals);
        feeContext.liquidityAmount = liquidityAmount;
    }

    function _computeSwapAmount(address listingAddress, FeeContext memory feeContext, bool isBuyOrder) private view returns (LiquidityUpdateContext memory context) {
        context.pendingAmount = feeContext.netAmount;
        context.isBuyOrder = isBuyOrder;
        (, context.amountOut) = _computeSwapImpact(listingAddress, feeContext.netAmount, isBuyOrder);
    }

    function _toSingleUpdateArray(ICCLiquidity.UpdateType memory update) private pure returns (ICCLiquidity.UpdateType[] memory) {
        ICCLiquidity.UpdateType[] memory updates = new ICCLiquidity.UpdateType[](1);
        updates[0] = update;
        return updates;
    }

     // Updates fee-related liquidity data
    function _updateFees(address listingAddress, uint256 normalizedFee, bool isBuyOrder) private {
        ICCListing listingContract = ICCListing(listingAddress);
        ICCLiquidity liquidityContract = ICCLiquidity(listingContract.liquidityAddressView());
        ICCLiquidity.UpdateType memory update = ICCLiquidity.UpdateType({
            updateType: 1,
            index: isBuyOrder ? 1 : 0,
            value: normalizedFee,
            addr: address(this),
            recipient: address(0)
        });
        try liquidityContract.ccUpdate(address(this), _toSingleUpdateArray(update)) {} catch Error(string memory reason) {
            revert(string(abi.encodePacked("Fee update failed: ", reason)));
        }
    }

       // Prepares liquidity updates and processes fees
    function _prepareLiquidityUpdates(address listingAddress, LiquidityUpdateContext memory context) private {
        ICCListing listingContract = ICCListing(listingAddress);
        ICCLiquidity liquidityContract = ICCLiquidity(listingContract.liquidityAddressView());
        (uint256 xLiquid, uint256 yLiquid) = liquidityContract.liquidityAmounts();
        (address tokenAddress, ) = _getTokenAndDecimals(listingAddress, context.isBuyOrder);
        uint256 normalizedPending = normalize(context.pendingAmount, context.isBuyOrder ? listingContract.decimalsB() : listingContract.decimalsA());
        uint256 normalizedSettle = normalize(context.amountOut, context.isBuyOrder ? listingContract.decimalsA() : listingContract.decimalsB());
        FeeContext memory feeContext = _computeFee(listingAddress, context.pendingAmount, context.isBuyOrder);
        uint256 normalizedFee = normalize(feeContext.feeAmount, context.isBuyOrder ? listingContract.decimalsB() : listingContract.decimalsA());

        require(context.isBuyOrder ? yLiquid >= normalizedPending : xLiquid >= normalizedPending, "Insufficient input liquidity");
        require(context.isBuyOrder ? xLiquid >= normalizedSettle : yLiquid >= normalizedSettle, "Insufficient output liquidity");

        ICCLiquidity.UpdateType memory update = ICCLiquidity.UpdateType({
            updateType: 0,
            index: context.isBuyOrder ? 1 : 0,
            value: context.isBuyOrder ? yLiquid + normalizedPending : xLiquid + normalizedPending,
            addr: address(this),
            recipient: address(0)
        });
        try liquidityContract.ccUpdate(address(this), _toSingleUpdateArray(update)) {} catch Error(string memory reason) {
            revert(string(abi.encodePacked("Incoming liquidity update failed: ", reason)));
        }

        update = ICCLiquidity.UpdateType({
            updateType: 0,
            index: context.isBuyOrder ? 0 : 1,
            value: context.isBuyOrder ? xLiquid - normalizedSettle : yLiquid - normalizedSettle,
            addr: address(this),
            recipient: address(0)
        });
        try liquidityContract.ccUpdate(address(this), _toSingleUpdateArray(update)) {} catch Error(string memory reason) {
            revert(string(abi.encodePacked("Outgoing liquidity update failed: ", reason)));
        }

        _updateFees(listingAddress, normalizedFee, context.isBuyOrder);

        if (tokenAddress == address(0)) {
            try listingContract.transactNative(context.pendingAmount, listingContract.liquidityAddressView()) {} catch Error(string memory reason) {
                revert(string(abi.encodePacked("Native transfer failed: ", reason)));
            }
        } else {
            try listingContract.transactToken(tokenAddress, context.pendingAmount, listingContract.liquidityAddressView()) {} catch Error(string memory reason) {
                revert(string(abi.encodePacked("Token transfer failed: ", reason)));
            }
        }
    }

    function _executeOrderWithFees(address listingAddress, uint256 orderIdentifier, bool isBuyOrder, FeeContext memory feeContext) private returns (bool success) {
        ICCListing listingContract = ICCListing(listingAddress);
        emit FeeDeducted(listingAddress, orderIdentifier, isBuyOrder, feeContext.feeAmount, feeContext.netAmount);
        LiquidityUpdateContext memory liquidityContext = _computeSwapAmount(listingAddress, feeContext, isBuyOrder);
        _prepareLiquidityUpdates(listingAddress, liquidityContext);

        ICCListing.HistoricalUpdate[] memory historicalUpdates = new ICCListing.HistoricalUpdate[](1);
        (uint256 xBalance, uint256 yBalance) = listingContract.volumeBalances(0);
        uint256 historicalLength = listingContract.historicalDataLengthView();
        uint256 xVolume = 0;
        uint256 yVolume = 0;
        if (historicalLength > 0) {
            ICCListing.HistoricalData memory lastData = listingContract.getHistoricalDataView(historicalLength - 1);
            xVolume = lastData.xVolume;
            yVolume = lastData.yVolume;
        }
        historicalUpdates[0] = ICCListing.HistoricalUpdate({
            price: listingContract.prices(0),
            xBalance: xBalance,
            yBalance: yBalance,
            xVolume: xVolume,
            yVolume: yVolume,
            timestamp: block.timestamp
        });
        try listingContract.ccUpdate(
            new ICCListing.BuyOrderUpdate[](0),
            new ICCListing.SellOrderUpdate[](0),
            new ICCListing.BalanceUpdate[](0),
            historicalUpdates
        ) {} catch Error(string memory reason) {
            revert(string(abi.encodePacked("Historical update failed: ", reason)));
        }

        success = isBuyOrder ? executeSingleBuyLiquid(listingAddress, orderIdentifier) : executeSingleSellLiquid(listingAddress, orderIdentifier);
        require(success, "Order execution failed");
    }
    
   // Executes a single buy order, updating order status and transferring tokens
    function executeSingleBuyLiquid(address listingAddress, uint256 orderIdentifier) internal returns (bool success) {
        ICCListing listingContract = ICCListing(listingAddress);
        (, address recipient, uint8 status) = listingContract.getBuyOrderCore(orderIdentifier);
        if (status != 1) return false;
        (, uint256 amountOut, ) = listingContract.getBuyOrderAmounts(orderIdentifier);
        try listingContract.transactToken(listingContract.tokenA(), amountOut, recipient) {
            listingContract.ccUpdate(
                new ICCListing.BuyOrderUpdate[](1),
                new ICCListing.SellOrderUpdate[](0),
                new ICCListing.BalanceUpdate[](0),
                new ICCListing.HistoricalUpdate[](0)
            );
            return true;
        } catch Error(string memory reason) {
            emit TokenTransferFailed(listingAddress, orderIdentifier, listingContract.tokenA(), reason);
            return false;
        }
    }

    // Executes a single sell order, updating order status and transferring tokens
    function executeSingleSellLiquid(address listingAddress, uint256 orderIdentifier) internal returns (bool success) {
        ICCListing listingContract = ICCListing(listingAddress);
        (, address recipient, uint8 status) = listingContract.getSellOrderCore(orderIdentifier);
        if (status != 1) return false;
        (, uint256 amountOut, ) = listingContract.getSellOrderAmounts(orderIdentifier);
        try listingContract.transactToken(listingContract.tokenB(), amountOut, recipient) {
            listingContract.ccUpdate(
                new ICCListing.BuyOrderUpdate[](0),
                new ICCListing.SellOrderUpdate[](1),
                new ICCListing.BalanceUpdate[](0),
                new ICCListing.HistoricalUpdate[](0)
            );
            return true;
        } catch Error(string memory reason) {
            emit TokenTransferFailed(listingAddress, orderIdentifier, listingContract.tokenB(), reason);
            return false;
        }
    }

        // Validates liquidity availability, non-view due to external call
    function _validateLiquidity(address listingAddress, uint256 pendingAmount, bool isBuyOrder, uint256 amountOut) private returns (LiquidityValidationContext memory context) {
        ICCListing listingContract = ICCListing(listingAddress);
        ICCLiquidity liquidityContract = ICCLiquidity(listingContract.liquidityAddressView());
        (context.xLiquid, context.yLiquid) = liquidityContract.liquidityAmounts();
        context.normalizedPending = normalize(pendingAmount, isBuyOrder ? listingContract.decimalsB() : listingContract.decimalsA());
        context.normalizedSettle = normalize(amountOut, isBuyOrder ? listingContract.decimalsA() : listingContract.decimalsB());

        if (isBuyOrder ? context.yLiquid < context.normalizedPending : context.xLiquid < context.normalizedPending) {
            emit InsufficientBalance(listingAddress, context.normalizedPending, isBuyOrder ? context.yLiquid : context.xLiquid);
            return context;
        }
        if (isBuyOrder ? context.xLiquid < context.normalizedSettle : context.yLiquid < context.normalizedSettle) {
            emit InsufficientBalance(listingAddress, context.normalizedSettle, isBuyOrder ? context.xLiquid : context.yLiquid);
            return context;
        }
    }

       // Checks Uniswap LP balance against internal liquidity, non-view due to external call
    function _checkUniswapBalance(address listingAddress, uint256 orderIdentifier, bool isBuyOrder, LiquidityValidationContext memory validationContext) private returns (bool valid) {
        ICCListing listingContract = ICCListing(listingAddress);
        UniswapBalanceContext memory context;
        context.outputToken = isBuyOrder ? listingContract.tokenA() : listingContract.tokenB();
        context.normalizedUniswapBalance = context.outputToken == address(0) ? address(listingContract.uniswapV2PairView()).balance : IERC20(context.outputToken).balanceOf(listingContract.uniswapV2PairView());
        context.normalizedUniswapBalance = normalize(context.normalizedUniswapBalance, isBuyOrder ? listingContract.decimalsA() : listingContract.decimalsB());
        context.internalLiquidity = isBuyOrder ? validationContext.xLiquid : validationContext.yLiquid;
        if (context.normalizedUniswapBalance > context.internalLiquidity) {
            emit UniswapLiquidityExcess(listingAddress, orderIdentifier, isBuyOrder, context.normalizedUniswapBalance, context.internalLiquidity);
            return false;
        }
        return true;
    }

       // Executes order with fees after preparing updates
    function _executeOrder(address listingAddress, uint256 orderIdentifier, bool isBuyOrder, FeeContext memory feeContext) private returns (bool success) {
        success = _executeOrderWithFees(listingAddress, orderIdentifier, isBuyOrder, feeContext);
    }
    
   // Validates order pricing against Uniswap LP price with slippage tolerance
    function _validateOrderPricing(address listingAddress, bool isBuyOrder, uint256 pendingAmount) private view returns (OrderProcessingContext memory context) {
        context.currentPrice = _computeCurrentPrice(listingAddress);
        (, context.impactPrice) = _computeSwapImpact(listingAddress, pendingAmount, isBuyOrder);
        context.maxPrice = (context.currentPrice * 110) / 100; // 10% slippage tolerance
        context.minPrice = (context.currentPrice * 90) / 100;  // 10% slippage tolerance
        if (context.impactPrice > context.maxPrice || context.impactPrice < context.minPrice || context.impactPrice == 0) {
            context.impactPrice = 0; // Mark as invalid
        }
    }

        // Processes a single order, validating pricing and liquidity
    function _processSingleOrder(address listingAddress, uint256 orderIdentifier, bool isBuyOrder, uint256 pendingAmount) internal returns (bool success) {
        OrderProcessingContext memory pricingContext = _validateOrderPricing(listingAddress, isBuyOrder, pendingAmount);
        if (pricingContext.impactPrice == 0) {
            emit PriceOutOfBounds(listingAddress, orderIdentifier, pricingContext.impactPrice, pricingContext.maxPrice, pricingContext.minPrice);
            return false;
        }

        (, uint256 amountOut) = _computeSwapImpact(listingAddress, pendingAmount, isBuyOrder);
        LiquidityValidationContext memory validationContext = _validateLiquidity(listingAddress, pendingAmount, isBuyOrder, amountOut);
        if (validationContext.normalizedPending == 0 || validationContext.normalizedSettle == 0) {
            return false;
        }

        if (!_checkUniswapBalance(listingAddress, orderIdentifier, isBuyOrder, validationContext)) {
            return false;
        }

        FeeContext memory feeContext = _computeFee(listingAddress, pendingAmount, isBuyOrder);
        return _executeOrder(listingAddress, orderIdentifier, isBuyOrder, feeContext);
    }

    // Processes a batch of orders, iterating through valid order identifiers
    function _processOrderBatch(address listingAddress, bool isBuyOrder, uint256 step) internal returns (bool success) {
        ICCListing listingContract = ICCListing(listingAddress);
        (uint256[] memory orderIdentifiers, uint256 iterationCount) = _collectOrderIdentifiers(listingAddress, isBuyOrder, step);
        success = false;
        for (uint256 i = 0; i < iterationCount; i++) {
            (uint256 pendingAmount, , ) = isBuyOrder ? listingContract.getBuyOrderAmounts(orderIdentifiers[i]) : listingContract.getSellOrderAmounts(orderIdentifiers[i]);
            if (pendingAmount == 0) continue;
            if (_processSingleOrder(listingAddress, orderIdentifiers[i], isBuyOrder, pendingAmount)) {
                success = true;
            }
        }
    }

    function _collectOrderIdentifiers(address listingAddress, bool isBuyOrder, uint256 step) internal view returns (uint256[] memory orderIdentifiers, uint256 iterationCount) {
        ICCListing listingContract = ICCListing(listingAddress);
        uint256[] memory allOrders = listingContract.makerPendingOrdersView(msg.sender);
        if (step >= allOrders.length) return (new uint256[](0), 0);
        uint256 count = 0;
        for (uint256 i = step; i < allOrders.length; i++) {
            (uint256 pending, , ) = isBuyOrder ? listingContract.getBuyOrderAmounts(allOrders[i]) : listingContract.getSellOrderAmounts(allOrders[i]);
            if (pending > 0) count++;
        }
        orderIdentifiers = new uint256[](count);
        count = 0;
        for (uint256 i = step; i < allOrders.length; i++) {
            (uint256 pending, , ) = isBuyOrder ? listingContract.getBuyOrderAmounts(allOrders[i]) : listingContract.getSellOrderAmounts(allOrders[i]);
            if (pending > 0) orderIdentifiers[count++] = allOrders[i];
        }
        iterationCount = count;
    }

    function _finalizeUpdates(bool isBuyOrder, ICCListing.BuyOrderUpdate[] memory buyUpdates, ICCListing.SellOrderUpdate[] memory sellUpdates, uint256 updateIndex) internal pure returns (ICCListing.BuyOrderUpdate[] memory finalBuyUpdates, ICCListing.SellOrderUpdate[] memory finalSellUpdates) {
        if (isBuyOrder) {
            finalBuyUpdates = new ICCListing.BuyOrderUpdate[](updateIndex);
            for (uint256 i = 0; i < updateIndex; i++) {
                finalBuyUpdates[i] = buyUpdates[i];
            }
            finalSellUpdates = new ICCListing.SellOrderUpdate[](0);
        } else {
            finalSellUpdates = new ICCListing.SellOrderUpdate[](updateIndex);
            for (uint256 i = 0; i < updateIndex; i++) {
                finalSellUpdates[i] = sellUpdates[i];
            }
            finalBuyUpdates = new ICCListing.BuyOrderUpdate[](0);
        }
    }

    function uint2str(uint256 _i) internal pure returns (string memory str) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        str = string(bstr);
    }
}