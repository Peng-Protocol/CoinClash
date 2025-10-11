/*
 SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025

 Version: 0.0.26 (11/10/2025)
Changes: 
- v0.0.26 (11/10): Removed unused local variables and params.
*/

pragma solidity ^0.8.2;

import "./utils/CCLiquidPartial.sol";

contract CCLiquidRouter is CCLiquidPartial {
    event NoPendingOrders(address indexed listingAddress, bool isBuyOrder);

    struct HistoricalUpdateContext {
    uint256 xBalance;
    uint256 yBalance;
    uint256 xVolume;
    uint256 yVolume;
}

function _createHistoricalUpdate(address listingAddress, ICCListing listingContract) private {
    // Creates historical data update using live data
    HistoricalUpdateContext memory context;
    (context.xBalance, context.yBalance) = listingContract.volumeBalances(0);
    uint256 historicalLength = listingContract.historicalDataLengthView();
    if (historicalLength > 0) {
        ICCListing.HistoricalData memory historicalData = listingContract.getHistoricalDataView(historicalLength - 1);
        context.xVolume = historicalData.xVolume;
        context.yVolume = historicalData.yVolume;
    }
    ICCListing.HistoricalUpdate memory update = ICCListing.HistoricalUpdate({
        price: listingContract.prices(0),
        xBalance: context.xBalance,
        yBalance: context.yBalance,
        xVolume: context.xVolume,
        yVolume: context.yVolume,
        timestamp: block.timestamp
    });
    ICCListing.BuyOrderUpdate[] memory buyUpdates = new ICCListing.BuyOrderUpdate[](0);
    ICCListing.SellOrderUpdate[] memory sellUpdates = new ICCListing.SellOrderUpdate[](0);
    ICCListing.BalanceUpdate[] memory balanceUpdates = new ICCListing.BalanceUpdate[](0);
    ICCListing.HistoricalUpdate[] memory historicalUpdates = new ICCListing.HistoricalUpdate[](1);
    historicalUpdates[0] = update;
    try listingContract.ccUpdate(buyUpdates, sellUpdates, balanceUpdates, historicalUpdates) {
    } catch Error(string memory reason) {
        emit UpdateFailed(listingAddress, string(abi.encodePacked("Historical update failed: ", reason)));
    }
}

    // Settles buy orders for msg.sender
    function settleBuyLiquid(address listingAddress, uint256 step) external onlyValidListing(listingAddress) nonReentrant {
        ICCListing listingContract = ICCListing(listingAddress);
        uint256[] memory pendingOrders = listingContract.makerPendingOrdersView(msg.sender);
        if (pendingOrders.length == 0 || step >= pendingOrders.length) {
            emit NoPendingOrders(listingAddress, true);
            return;
        }
        (, uint256 yBalance) = listingContract.volumeBalances(0);
        if (yBalance == 0) {
            emit InsufficientBalance(listingAddress, 1, yBalance);
            return;
        }
        if (pendingOrders.length > 0) {
            _createHistoricalUpdate(listingAddress, listingContract);
        }
        bool success = _processOrderBatch(listingAddress, true, step);
        if (!success) {
            emit UpdateFailed(listingAddress, "Buy order batch processing failed");
        }
    }

    // Settles sell orders for msg.sender
    function settleSellLiquid(address listingAddress, uint256 step) external onlyValidListing(listingAddress) nonReentrant {
        ICCListing listingContract = ICCListing(listingAddress);
        uint256[] memory pendingOrders = listingContract.makerPendingOrdersView(msg.sender);
        if (pendingOrders.length == 0 || step >= pendingOrders.length) {
            emit NoPendingOrders(listingAddress, false);
            return;
        }
        (uint256 xBalance, ) = listingContract.volumeBalances(0);
        if (xBalance == 0) {
            emit InsufficientBalance(listingAddress, 1, xBalance);
            return;
        }
        if (pendingOrders.length > 0) {
            _createHistoricalUpdate(listingAddress, listingContract);
        }
        bool success = _processOrderBatch(listingAddress, false, step);
        if (!success) {
            emit UpdateFailed(listingAddress, "Sell order batch processing failed");
        }
    }
}