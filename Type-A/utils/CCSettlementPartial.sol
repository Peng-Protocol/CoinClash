// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.4.3 (27/11/2025)
// Changes:
// - (27/11/2035): Replaced nominal price check with impact price check.
// - (26/11/2025): Ensured settlement of orders with status=2. 

import "./CCUniPartial.sol";

contract CCSettlementPartial is CCUniPartial {
    /**
     * (0.4.3) Checks if the trade causes an Impact Price violation.
     * Uses linear estimation for output to calculate.
     */
    function _checkPricing(
        uint256 orderIdentifier,
        uint256 amountIn, // Normalized (18 decimals)
        bool isBuyOrder,
        uint256[] memory orderPrices, // [0]=maxPrice, [1]=minPrice
        SettlementContext memory ctx
    ) internal view returns (bool) {
        // 1. Load Current Reserves
        // We use ctx.tokenA / ctx.tokenB which are mapped correctly for the pair
        uint256 rA = normalize(IERC20(ctx.tokenA).balanceOf(ctx.uniswapV2Pair), ctx.decimalsA);
        uint256 rB = normalize(IERC20(ctx.tokenB).balanceOf(ctx.uniswapV2Pair), ctx.decimalsB);

        if (rA == 0 || rB == 0) return false;

        // 2. Calculate Current Spot Price (Price = B / A)
        // Note: We use high precision for internal calculation
        uint256 currentPrice = (rB * 1e18) / rA;

        // 3. Calculate Impact Reserves
        uint256 impactResA;
        uint256 impactResB;
        
        // Note: We use the linear constant-price estimation for output as a conservative check.
        // Real swaps have slippage (convexity), so real output < estimated output.
        // This makes the check slightly stricter than reality, which is safer.
        
        if (isBuyOrder) {
            // BUY: Input TokenB -> Output TokenA
            // Estimated Output A = Input B / Price
            uint256 estimatedOutA = (amountIn * 1e18) / currentPrice;

            // Impact A = Reserve A - Out A
            impactResA = rA > estimatedOutA ? rA - estimatedOutA : 1; // Prevent div by 0
            
            // Impact B = Reserve B + In B
            impactResB = rB + amountIn;

        } else {
            // SELL: Input TokenA -> Output TokenB
            // Estimated Output B = Input A * Price
            uint256 estimatedOutB = (amountIn * currentPrice) / 1e18;

            // Impact A = Reserve A + In A
            impactResA = rA + amountIn;

            // Impact B = Reserve B - Out B
            impactResB = rB > estimatedOutB ? rB - estimatedOutB : 1; // Prevent div by 0
        }

        // 4. Calculate Impact Price
        // Impact Price = ImpactResB / ImpactResA
        uint256 impactPrice = (impactResB * 1e18) / impactResA;

        // 5. Verify Bounds
        uint256 maxPrice = orderPrices[0];
        uint256 minPrice = orderPrices[1];

        if (impactPrice > maxPrice || impactPrice < minPrice) {
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