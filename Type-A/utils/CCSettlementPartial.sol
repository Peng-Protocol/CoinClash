// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.4.1 (26/11/2025)
// Changes:
// - (26/11/2025): Removed erroneous settler billing in buy order settlement. 

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

// 0.4.1 fixed billing, does not bill settler, uses listing template balance. 

function _processBuyOrder(
    address listingAddress,
    uint256 orderIdentifier,
    uint256 amountIn, // <--- NOW represents the normalized amount of Token B (Listing's/Buyer's token) to swap.
    ICCListing listingContract,
    SettlementContext memory settlementContext
) internal returns (ICCListing.BuyOrderUpdate[] memory buyUpdates) {
    // Get order data - amounts[0] = pending, amounts[1] = filled, amounts[2] = amountSent
    (address[] memory addresses, , uint256[] memory amounts, uint8 status) = 
        listingContract.getBuyOrder(orderIdentifier);
    
    uint256 pendingAmount = amounts[0]; // Normalized Token B pending
    
    if (status != 1 || pendingAmount == 0) {
        emit OrderSkipped(orderIdentifier, "Invalid status or no pending amount");
        return new ICCListing.BuyOrderUpdate[](0);
    }
    
    if (amountIn == 0) {
        emit OrderSkipped(orderIdentifier, "Zero swap amount");
        return new ICCListing.BuyOrderUpdate[](0);
    }
    
    // CRITICAL CHANGE: Removed the call to _prepBuyOrderUpdate which incorrectly pulled Token A from the Settler.
    
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
        
        if (status != 1 || pendingAmount == 0) {
            emit OrderSkipped(orderIdentifier, "Invalid status or no pending amount");
            return new ICCListing.SellOrderUpdate[](0);
        }
        
        if (amountIn == 0) {
            emit OrderSkipped(orderIdentifier, "Zero swap amount");
            return new ICCListing.SellOrderUpdate[](0);
        }
        
        // Execute swap and create updates
        // Similar functionality to buy side equivalent  but delegated
        return _executePartialSellSwap(listingAddress, orderIdentifier, amountIn, pendingAmount, addresses, amounts, settlementContext);
    }
}