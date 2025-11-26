// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.4.2 (26/11/2025)
// Changes:
// - (26/11/2025): Ensured settlement of orders with status=2. 

import "./CCUniPartial.sol";

contract CCSettlementPartial is CCUniPartial {
    
    function _checkPricing(
        address listingAddress,
        uint256 orderIdentifier,
        bool isBuyOrder,
        address startToken,
        address endToken,
        uint256[] memory orderPrices
    ) internal returns (bool) {
        ICCListing listingContract = ICCListing(listingAddress);
        
        // orderPrices[0] = maxPrice, orderPrices[1] = minPrice
        uint256 maxPrice = orderPrices[0];
        uint256 minPrice = orderPrices[1];
        
        // Get current price for this token pair
        uint256 currentPrice = listingContract.prices(
            isBuyOrder ? startToken : startToken,
            isBuyOrder ? endToken : endToken
        );
        
        if (currentPrice == 0) {
            emit OrderSkipped(orderIdentifier, "Invalid current price");
            return false;
        }
        if (currentPrice < minPrice || currentPrice > maxPrice) {
            emit OrderSkipped(orderIdentifier, "Price out of bounds");
            return false;
        }
        return true;
    }

// 0.4.2 aligned to allow settlement of orders with status=2

function _processBuyOrder(
    address listingAddress,
    uint256 orderIdentifier,
    uint256 amountIn, // Normalized amount of Token B to swap
    ICCListing listingContract,
    SettlementContext memory settlementContext
) internal returns (ICCListing.BuyOrderUpdate[] memory buyUpdates) {
    // Get order data - amounts[0] = pending, amounts[1] = filled, amounts[2] = amountSent
    (address[] memory addresses, , uint256[] memory amounts, uint8 status) = 
        listingContract.getBuyOrder(orderIdentifier);
    
    uint256 pendingAmount = amounts[0]; // Normalized Token B pending
    
    // CRITICAL FIX: Accept both status 1 (pending) and status 2 (partially filled)
    if (pendingAmount == 0) {
        emit OrderSkipped(orderIdentifier, "No pending amount");
        return new ICCListing.BuyOrderUpdate[](0);
    }
    
    if (status != 1 && status != 2) {
        emit OrderSkipped(orderIdentifier, "Invalid status - must be pending or partially filled");
        return new ICCListing.BuyOrderUpdate[](0);
    }
    
    if (amountIn == 0) {
        emit OrderSkipped(orderIdentifier, "Zero swap amount");
        return new ICCListing.BuyOrderUpdate[](0);
    }
    
    // Execute swap and create updates
    return _executePartialBuySwap(listingAddress, orderIdentifier, amountIn, pendingAmount, addresses, amounts, settlementContext);
}
    
    function _processSellOrder(
    address listingAddress,
    uint256 orderIdentifier,
    uint256 amountIn,
    ICCListing listingContract,
    SettlementContext memory settlementContext
) internal returns (ICCListing.SellOrderUpdate[] memory sellUpdates) {
    // Get order data - amounts[0] = pending, amounts[1] = filled, amounts[2] = amountSent
    (address[] memory addresses, , uint256[] memory amounts, uint8 status) = 
        listingContract.getSellOrder(orderIdentifier);
    
    uint256 pendingAmount = amounts[0]; // Normalized to 18 decimals
    
    // CRITICAL FIX: Accept both status 1 (pending) and status 2 (partially filled)
    if (pendingAmount == 0) {
        emit OrderSkipped(orderIdentifier, "No pending amount");
        return new ICCListing.SellOrderUpdate[](0);
    }
    
    if (status != 1 && status != 2) {
        emit OrderSkipped(orderIdentifier, "Invalid status - must be pending or partially filled");
        return new ICCListing.SellOrderUpdate[](0);
    }
    
    if (amountIn == 0) {
        emit OrderSkipped(orderIdentifier, "Zero swap amount");
        return new ICCListing.SellOrderUpdate[](0);
    }
    
    // Execute swap and create updates
    return _executePartialSellSwap(listingAddress, orderIdentifier, amountIn, pendingAmount, addresses, amounts, settlementContext);
}
}