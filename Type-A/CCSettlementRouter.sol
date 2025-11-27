// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.4.3 (27/11/2025)
// Changes:
// - (27/11/2025): Reordered settlement context to capture reserves for impact price calculation ..
// - (26/11/2025): Fixed order status validation, status 1 & 2 are valid, only status 0 and 3 are to be skipped. 

import "./utils/CCSettlementPartial.sol";

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract CCSettlementRouter is CCSettlementPartial {

    function _validateOrder(
    address listingAddress,
    uint256 orderId,
    bool isBuyOrder,
    ICCListing listingContract
) internal returns (bool valid) {
    // Get order data using unified getter
    (address[] memory addresses, uint256[] memory prices_, uint256[] memory amounts, uint8 status) = 
        isBuyOrder ? listingContract.getBuyOrder(orderId) : listingContract.getSellOrder(orderId);
    
    // CRITICAL FIX: Accept both status 1 (pending) and status 2 (partially filled)
    // Status 0 = cancelled, 1 = pending, 2 = partially filled, 3 = filled
    // amounts[0] = pending (normalized to 18 decimals)
    if (amounts[0] == 0) {
        emit OrderSkipped(orderId, "No pending amount");
        return false;
    }
    
    if (status != 1 && status != 2) {
        emit OrderSkipped(orderId, "Invalid status - must be pending or partially filled");
        return false;
    }
    
    // Extract tokens from addresses array for pricing check
    address startToken = addresses[2];
    address endToken = addresses[3];
    
    if (!_checkPricing(listingAddress, orderId, isBuyOrder, startToken, endToken, prices_)) {
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
            // Check updated status
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
        
        // Get pair address and query reserves directly
        address factory = listingContract.uniswapV2Factory();
        require(factory != address(0), "Factory not set");
        address pairAddress = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        require(pairAddress != address(0), "Pair does not exist");
        
        // Get token decimals
        uint8 decimalsA = _getTokenDecimals(tokenA);
        uint8 decimalsB = _getTokenDecimals(tokenB);
        
        // Query balances from pair and normalize
        uint256 xBalance = normalize(IERC20(tokenA).balanceOf(pairAddress), decimalsA);
        uint256 yBalance = normalize(IERC20(tokenB).balanceOf(pairAddress), decimalsB);
        
        // Get existing volumes from last historical entry
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

    /**
     * @notice Settles multiple orders with pre-calculated amounts
     * @param listingAddress The listing contract address
     * @param orderIds Array of order IDs to settle
     * @param amountsIn Array of amounts to swap (MUST BE NORMALIZED TO 18 DECIMALS)
     * @param isBuyOrder True for buy orders, false for sell orders
     * @dev amountsIn values must be in normalized (18 decimal) format regardless of actual token decimals
     * @dev Each order contains its own token path (startToken, endToken) in addresses array
     */
    function settleOrders(
        address listingAddress,
        uint256[] calldata orderIds,
        uint256[] calldata amountsIn,
        bool isBuyOrder
    ) external nonReentrant returns (string memory reason) {
        require(listingTemplate != address(0), "Listing template not set");
        require(listingAddress == listingTemplate, "Invalid listing address");
        
        if (orderIds.length != amountsIn.length) revert("Order IDs and amounts length mismatch");
        if (orderIds.length == 0) revert("No orders to settle");
        
        ICCListing listingContract = ICCListing(listingAddress);
        
        // Track unique token pairs for historical updates
        address firstStartToken;
        address firstEndToken;
        bool hasTrackedPair = false;
        
        uint256 count = 0;
        
        for (uint256 i = 0; i < orderIds.length; i++) {
            // 1. Retrieve Basic Order Data
            (address[] memory addresses, uint256[] memory prices, uint256[] memory amounts, uint8 status) = 
                isBuyOrder ? listingContract.getBuyOrder(orderIds[i]) : listingContract.getSellOrder(orderIds[i]);
            
            // Check Status (1=Pending, 2=Partial) and Pending Amount
            if ((status != 1 && status != 2) || amounts[0] == 0) {
                emit OrderSkipped(orderIds[i], "Invalid status or no pending amount");
                continue;
            }

            // 2. Retrieve Token Context (Pair Address, Decimals)
            SettlementContext memory settlementContext = _getOrderTokenContext(listingContract, orderIds[i], isBuyOrder);

            // 3. Perform Impact Pricing Check
            // We pass amountsIn[i] to calculate specific impact of this chunk
            if (!_checkPricing(orderIds[i], amountsIn[i], isBuyOrder, prices, settlementContext)) {
                emit OrderSkipped(orderIds[i], "Impact Price out of bounds");
                continue;
            }

            // 4. Track Pair for Historical Data (Optimized: only tracks first successful pair)
            if (!hasTrackedPair) {
                firstStartToken = isBuyOrder ? settlementContext.tokenB : settlementContext.tokenA;
                firstEndToken = isBuyOrder ? settlementContext.tokenA : settlementContext.tokenB;
                hasTrackedPair = true;
            }
            
            // 5. Process Swap
            OrderContext memory context;
            context.orderId = orderIds[i];
            
            if (isBuyOrder) {
                context.buyUpdates = _processBuyOrder(listingAddress, orderIds[i], amountsIn[i], listingContract, settlementContext);
            } else {
                context.sellUpdates = _processSellOrder(listingAddress, orderIds[i], amountsIn[i], listingContract, settlementContext);
            }
            
            (bool success, string memory updateReason) = _updateOrder(listingContract, context, isBuyOrder);
            
            if (!success) {
                if (bytes(updateReason).length > 0) revert(updateReason);
                // If silent fail, just continue
            } else {
                count++;
            }
        }
        
        // 6. Update History
        if (count > 0 && hasTrackedPair) {
            _createHistoricalEntry(listingContract, firstStartToken, firstEndToken);
        }
        
        if (count == 0) {
            return "No orders settled: price/impact check failed";
        }
        return "";
    }
    
    /**
     * @notice Retrieves order-specific token context from the listing
     * @param listingContract The listing contract
     * @param orderId The order ID
     * @param isBuyOrder Whether this is a buy order
     * @return settlementContext The token context for this specific order
     */
    function _getOrderTokenContext(
        ICCListing listingContract,
        uint256 orderId,
        bool isBuyOrder
    ) internal view returns (SettlementContext memory settlementContext) {
        // Get order data - addresses array: [maker, recipient, startToken, endToken]
        (address[] memory addresses, , , ) = isBuyOrder
            ? listingContract.getBuyOrder(orderId)
            : listingContract.getSellOrder(orderId);
        
        address startToken = addresses[2];
        address endToken = addresses[3];
        
        // Get token decimals from registry or standard ERC20
        uint8 startDecimals = _getTokenDecimals(startToken);
        uint8 endDecimals = _getTokenDecimals(endToken);
        
        // Get pair address from factory
        address pairAddress = _getPairAddress(listingContract, startToken, endToken);
        
        // For buy orders: buying endToken with startToken (startToken in, endToken out)
        // For sell orders: selling startToken for endToken (startToken in, endToken out)
        settlementContext.tokenA = isBuyOrder ? endToken : startToken;
        settlementContext.tokenB = isBuyOrder ? startToken : endToken;
        settlementContext.decimalsA = isBuyOrder ? endDecimals : startDecimals;
        settlementContext.decimalsB = isBuyOrder ? startDecimals : endDecimals;
        settlementContext.uniswapV2Pair = pairAddress;
    }
    
    /**
     * @notice Gets token decimals, handling native ETH
     */
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == address(0)) return 18; // Native ETH
        try IERC20(token).decimals() returns (uint8 decimals) {
            return decimals;
        } catch {
            return 18; // Default to 18 if decimals() fails
        }
    }
    
    /**
     * 0.4.1: Fetches from factory instead of deterministic calculation.
     */
    function _getPairAddress(
        ICCListing listingContract,
        address tokenA,
        address tokenB
    ) internal view returns (address) {
        address factory = listingContract.uniswapV2Factory();
        require(factory != address(0), "Factory not set");
        
        // Handle Native/WETH conversion if necessary for the lookup
        // (Assuming factory uses WETH for native pairs)
        // Check if tokens are address(0) and map to WETH if your factory expects that, 
        // OR if your system handles address(0) explicitly before this call.
        // Based on your context, tokens here seem to be actual ERC20s (WETH/Token) 
        // derived from settlementContext.
        
        // Sort tokens just to be safe, though getPair usually handles it or doesn't care depending on implementation
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        // DIRECT CALL TO FACTORY
        address pair = IUniswapV2Factory(factory).getPair(token0, token1);
        
        // Ensure pair exists to avoid returning address(0) which causes the zero reserve error later
        require(pair != address(0), "Pair does not exist");
        
        return pair;
    }
}