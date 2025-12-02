/*
 SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025

 Version: 0.1.1 (02/12/2025)
Changes: 
- v0.1.1 (02/12): Used correct liquidity template address, not address(this). 
- v0.1.0 (11/11): Complete refactor for monolithic architecture. Removed per-pair assumptions.
  Updated to work with CCListingTemplate v0.4.2 and CCLiquidityTemplate v0.2.0.
  Orders now use startToken/endToken from order data.
  Removed volumeBalances checks (now queries Uniswap pair directly).
  Simplified order settlement to work with token-specific liquidity.
*/

pragma solidity ^0.8.2;

import "./utils/CCLiquidPartial.sol";

contract CCLiquidRouter is CCLiquidPartial {
    
    // Settles buy orders for msg.sender
    // Update (0.1.1) settleBuyLiquid
function settleBuyLiquid(uint256 step) external nonReentrant {
    require(listingAddress != address(0), "Listing not set");
    require(liquidityAddress != address(0), "Liquidity not set"); // ADDED THIS
    
    ICCListing listingContract = ICCListing(listingAddress);
    ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress); // FIXED THIS
    
    uint256[] memory pendingOrders = listingContract.makerPendingOrdersView(msg.sender);
    if (pendingOrders.length == 0 || step >= pendingOrders.length) {
        emit NoPendingOrders(listingAddress, true);
        return;
    }
    
    bool success = _processOrderBatch(liquidityContract, true, step);
    if (!success) {
        emit UpdateFailed(listingAddress, "Buy order batch processing failed");
    }
}

// Update (0.1.1) settleSellLiquid
function settleSellLiquid(uint256 step) external nonReentrant {
    require(listingAddress != address(0), "Listing not set");
    require(liquidityAddress != address(0), "Liquidity not set"); // ADDED THIS
    
    ICCListing listingContract = ICCListing(listingAddress);
    ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress); // FIXED THIS
    
    uint256[] memory pendingOrders = listingContract.makerPendingOrdersView(msg.sender);
    if (pendingOrders.length == 0 || step >= pendingOrders.length) {
        emit NoPendingOrders(listingAddress, false);
        return;
    }
    
    bool success = _processOrderBatch(liquidityContract, false, step);
    if (!success) {
        emit UpdateFailed(listingAddress, "Sell order batch processing failed");
    }
}
}
