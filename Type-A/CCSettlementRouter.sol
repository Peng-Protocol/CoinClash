// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.2.0 (Trimmed)
// Changes:
// - Modified settleOrders to accept amountIn array (off-chain calculation)
// - Removed _processOrder wrapper (inline logic)
// - Simplified _validateOrder to minimal checks
// - Consolidated settlement logic directly in main function
// - Router expects pre-calculated amounts from off-chain in NORMALIZED (18 decimal) format
// - MAINTAINED: All normalize/denormalize conversions handled in lower layers
// - Note: amountsIn array must be in 18 decimal normalized format

import "./utils/CCSettlementPartial.sol";

contract CCSettlementRouter is CCSettlementPartial {

    function _validateOrder(
        address listingAddress,
        uint256 orderId,
        bool isBuyOrder,
        ICCListing listingContract
    ) internal returns (bool valid) {
        // All amounts retrieved here are normalized (18 decimals)
        (uint256 pending, , ) = isBuyOrder ? listingContract.getBuyOrderAmounts(orderId) : listingContract.getSellOrderAmounts(orderId);
        (, , uint8 status) = isBuyOrder ? listingContract.getBuyOrderCore(orderId) : listingContract.getSellOrderCore(orderId);
        
        if (pending == 0 || status != 1) {
            emit OrderSkipped(orderId, "No pending amount or invalid status");
            return false;
        }
        
        if (!_checkPricing(listingAddress, orderId, isBuyOrder)) {
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
            new ICCListing.BalanceUpdate[](0),
            new ICCListing.HistoricalUpdate[](0)
        ) {
            (, , context.status) = isBuyOrder
                ? listingContract.getBuyOrderCore(context.orderId)
                : listingContract.getSellOrderCore(context.orderId);
            if (context.status == 0 || context.status == 3) {
                return (false, "");
            }
            return (true, "");
        } catch Error(string memory updateReason) {
            return (false, string(abi.encodePacked("Update failed for order ", uint2str(context.orderId), ": ", updateReason)));
        }
    }

    function _createHistoricalEntry(ICCListing listingContract) private {
        // volumeBalances returns normalized (18 decimal) amounts
        (uint256 xBalance, uint256 yBalance) = listingContract.volumeBalances(0);
        uint256 price = listingContract.prices(0);
        uint256 xVolume = 0;
        uint256 yVolume = 0;
        uint256 historicalLength = listingContract.historicalDataLengthView();
        
        if (historicalLength > 0) {
            ICCListing.HistoricalData memory historicalData = listingContract.getHistoricalDataView(historicalLength - 1);
            xVolume = historicalData.xVolume;
            yVolume = historicalData.yVolume;
        }
        
        ICCListing.HistoricalUpdate[] memory historicalUpdates = new ICCListing.HistoricalUpdate[](1);
        historicalUpdates[0] = ICCListing.HistoricalUpdate({
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
            new ICCListing.BalanceUpdate[](0),
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
     * @dev Off-chain calculation should account for:
     *      - Max price impact tolerance
     *      - Reserve constraints
     *      - Slippage tolerance
     *      - Convert final amounts to 18 decimal normalized format before calling
     */
    function settleOrders(
        address listingAddress,
        uint256[] calldata orderIds,
        uint256[] calldata amountsIn,
        bool isBuyOrder
    ) external nonReentrant onlyValidListing(listingAddress) returns (string memory reason) {
        if (uniswapV2Router == address(0)) {
            revert("Missing Uniswap V2 router address");
        }
        
        if (orderIds.length != amountsIn.length) {
            revert("Order IDs and amounts length mismatch");
        }
        
        if (orderIds.length == 0) {
            revert("No orders to settle");
        }
        
        ICCListing listingContract = ICCListing(listingAddress);
        SettlementContext memory settlementContext = SettlementContext({
            tokenA: listingContract.tokenA(),
            tokenB: listingContract.tokenB(),
            decimalsA: listingContract.decimalsA(),
            decimalsB: listingContract.decimalsB(),
            uniswapV2Pair: listingContract.uniswapV2PairView()
        });
        
        _createHistoricalEntry(listingContract);
        
        uint256 count = 0;
        for (uint256 i = 0; i < orderIds.length; i++) {
            if (!_validateOrder(listingAddress, orderIds[i], isBuyOrder, listingContract)) {
                continue;
            }
            
            OrderContext memory context;
            context.orderId = orderIds[i];
            
            // amountsIn[i] is expected to be normalized (18 decimals)
            // Denormalization happens in _processBuyOrder/_processSellOrder
            if (isBuyOrder) {
                context.buyUpdates = _processBuyOrder(listingAddress, orderIds[i], amountsIn[i], listingContract, settlementContext);
            } else {
                context.sellUpdates = _processSellOrder(listingAddress, orderIds[i], amountsIn[i], listingContract, settlementContext);
            }
            
            (bool success, string memory updateReason) = _updateOrder(listingContract, context, isBuyOrder);
            if (!success && bytes(updateReason).length > 0) {
                revert(updateReason);
            }
            if (success) {
                count++;
            }
        }
        
        if (count == 0) {
            return "No orders settled: price out of range or swap failure";
        }
        return "";
    }
}