// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.2.0 (Trimmed)
// Changes:
// - Removed OrderProcessContext struct (inline logic)
// - Removed _computeSwapAmount (amountIn passed from router in normalized 18 decimal format)
// - Removed _executeOrderSwap (direct call to execute functions)
// - Removed _prepareUpdateData (simplified update logic)
// - Removed _applyOrderUpdate (direct update creation)
// - Simplified _validateOrderParams to return only necessary data
// - MAINTAINED: All normalize/denormalize conversions handled in CCUniPartial
// - Note: amountIn arrives normalized (18 decimals), gets denormalized in swap prep

import "./CCUniPartial.sol";

contract CCSettlementPartial is CCUniPartial {
    
    function _checkPricing(address listingAddress, uint256 orderIdentifier, bool isBuyOrder) internal returns (bool) {
        ICCListing listingContract = ICCListing(listingAddress);
        (uint256 maxPrice, uint256 minPrice) = isBuyOrder ? listingContract.getBuyOrderPricing(orderIdentifier) : listingContract.getSellOrderPricing(orderIdentifier);
        uint256 currentPrice = listingContract.prices(0);
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

    function _processBuyOrder(address listingAddress, uint256 orderIdentifier, uint256 amountIn, ICCListing listingContract, SettlementContext memory settlementContext) internal returns (ICCListing.BuyOrderUpdate[] memory buyUpdates) {
        if (uniswapV2Router == address(0)) {
            emit OrderSkipped(orderIdentifier, "Uniswap V2 router not set");
            return new ICCListing.BuyOrderUpdate[](0);
        }
        
        // pendingAmount is stored normalized (18 decimals)
        (uint256 pendingAmount, , ) = listingContract.getBuyOrderAmounts(orderIdentifier);
        (, , uint8 status) = listingContract.getBuyOrderCore(orderIdentifier);
        
        if (status != 1 || pendingAmount == 0) {
            emit OrderSkipped(orderIdentifier, "Invalid status or no pending amount");
            return new ICCListing.BuyOrderUpdate[](0);
        }
        
        // amountIn is normalized (18 decimals) from router
        if (amountIn == 0) {
            emit OrderSkipped(orderIdentifier, "Zero swap amount");
            return new ICCListing.BuyOrderUpdate[](0);
        }
        
        // Denormalize amountIn for actual token transfer (handled in _prepBuyOrderUpdate)
        _prepBuyOrderUpdate(listingAddress, orderIdentifier, denormalize(amountIn, settlementContext.decimalsB), settlementContext);
        
        // _executePartialBuySwap handles denormalization for Uniswap and normalization of results
        return _executePartialBuySwap(listingAddress, orderIdentifier, amountIn, pendingAmount, settlementContext);
    }

    function _processSellOrder(address listingAddress, uint256 orderIdentifier, uint256 amountIn, ICCListing listingContract, SettlementContext memory settlementContext) internal returns (ICCListing.SellOrderUpdate[] memory sellUpdates) {
        if (uniswapV2Router == address(0)) {
            emit OrderSkipped(orderIdentifier, "Uniswap V2 router not set");
            return new ICCListing.SellOrderUpdate[](0);
        }
        
        // pendingAmount is stored normalized (18 decimals)
        (uint256 pendingAmount, , ) = listingContract.getSellOrderAmounts(orderIdentifier);
        (, , uint8 status) = listingContract.getSellOrderCore(orderIdentifier);
        
        if (status != 1 || pendingAmount == 0) {
            emit OrderSkipped(orderIdentifier, "Invalid status or no pending amount");
            return new ICCListing.SellOrderUpdate[](0);
        }
        
        // amountIn is normalized (18 decimals) from router
        if (amountIn == 0) {
            emit OrderSkipped(orderIdentifier, "Zero swap amount");
            return new ICCListing.SellOrderUpdate[](0);
        }
        
        // _executePartialSellSwap handles denormalization for Uniswap and normalization of results
        return _executePartialSellSwap(listingAddress, orderIdentifier, amountIn, pendingAmount, settlementContext);
    }
}