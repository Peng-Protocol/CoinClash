// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.2.0
// Changes:
// - v0.2.0: Complete refactor for monolithic listing template compatibility (v0.4.2).
// - Updated _executeSingleOrder to use array-based order structure with addresses[], prices[], amounts[].
// - Added startToken/endToken to order structs, stored in addresses[2] and addresses[3].
// - Updated _clearOrderData to work with array-based getBuyOrder/getSellOrder functions.
// - Removed liquidity-related transfer functions (moved to separate liquidity router).
// - Streamlined for consolidated order creation flow with single listing template.
// Compatible with CCListingTemplate.sol (v0.4.2), CCOrderRouter.sol (v0.2.0).

import "./CCMainPartial.sol";

contract CCOrderPartial is CCMainPartial {
    event TransferFailed(address indexed sender, address indexed token, uint256 amount, bytes reason);
    event OrderCreated(uint256 indexed orderId, address indexed maker, bool isBuy);
    event OrderCancelled(uint256 indexed orderId, address indexed maker, bool isBuy);

    error InsufficientAllowance(address sender, address token, uint256 required, uint256 available);

    struct OrderPrep {
        address maker;
        address recipient;
        address startToken;
        address endToken;
        uint256 amount;
        uint256 maxPrice;
        uint256 minPrice;
        uint256 amountReceived;
        uint256 normalizedReceived;
    }

    function _handleOrderPrep(
        address maker,
        address recipient,
        address startToken,
        address endToken,
        uint256 amount,
        uint256 maxPrice,
        uint256 minPrice,
        bool isBuy
    ) internal view returns (OrderPrep memory) {
        // Prepares order data, normalizes amount based on token decimals
        require(maker != address(0), "Invalid maker");
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        require(startToken != endToken, "Tokens must be different");
        
        uint8 decimals = startToken == address(0) ? 18 : IERC20(startToken).decimals();
        uint256 normalizedAmount = normalize(amount, decimals);
        
        return OrderPrep(maker, recipient, startToken, endToken, normalizedAmount, maxPrice, minPrice, 0, 0);
    }

    function _executeSingleOrder(
        OrderPrep memory prep,
        bool isBuy
    ) internal {
        // Executes single order creation using array-based structure
        // No race condition for nextOrderId as EVM processes transactions sequentially
        require(prep.normalizedReceived > 0, "No tokens received");
        require(listingTemplate != address(0), "Listing template not set");
        
        ICCListing listingContract = ICCListing(listingTemplate);
        uint256 orderId = listingContract.getNextOrderId();

        if (isBuy) {
            ICCListing.BuyOrderUpdate[] memory buyUpdates = new ICCListing.BuyOrderUpdate[](3);
            
            // Core update (structId: 0)
            address[] memory coreAddresses = new address[](4);
            coreAddresses[0] = prep.maker;
            coreAddresses[1] = prep.recipient;
            coreAddresses[2] = prep.startToken;
            coreAddresses[3] = prep.endToken;
            
            buyUpdates[0] = ICCListing.BuyOrderUpdate({
                structId: 0,
                orderId: orderId,
                addresses: coreAddresses,
                prices: new uint256[](0),
                amounts: new uint256[](0),
                status: 1 // pending
            });
            
            // Pricing update (structId: 1)
            uint256[] memory pricesArray = new uint256[](2);
            pricesArray[0] = prep.maxPrice;
            pricesArray[1] = prep.minPrice;
            
            buyUpdates[1] = ICCListing.BuyOrderUpdate({
                structId: 1,
                orderId: orderId,
                addresses: new address[](0),
                prices: pricesArray,
                amounts: new uint256[](0),
                status: 0
            });
            
            // Amounts update (structId: 2)
            uint256[] memory amountsArray = new uint256[](3);
            amountsArray[0] = prep.normalizedReceived; // pending
            amountsArray[1] = 0; // filled
            amountsArray[2] = 0; // amountSent
            
            buyUpdates[2] = ICCListing.BuyOrderUpdate({
                structId: 2,
                orderId: orderId,
                addresses: coreAddresses, // Include addresses for volume tracking
                prices: new uint256[](0),
                amounts: amountsArray,
                status: 0
            });
            
            listingContract.ccUpdate(
                buyUpdates, 
                new ICCListing.SellOrderUpdate[](0), 
                new ICCListing.HistoricalUpdate[](0)
            );
        } else {
            ICCListing.SellOrderUpdate[] memory sellUpdates = new ICCListing.SellOrderUpdate[](3);
            
            // Core update (structId: 0)
            address[] memory coreAddresses = new address[](4);
            coreAddresses[0] = prep.maker;
            coreAddresses[1] = prep.recipient;
            coreAddresses[2] = prep.startToken;
            coreAddresses[3] = prep.endToken;
            
            sellUpdates[0] = ICCListing.SellOrderUpdate({
                structId: 0,
                orderId: orderId,
                addresses: coreAddresses,
                prices: new uint256[](0),
                amounts: new uint256[](0),
                status: 1 // pending
            });
            
            // Pricing update (structId: 1)
            uint256[] memory pricesArray = new uint256[](2);
            pricesArray[0] = prep.maxPrice;
            pricesArray[1] = prep.minPrice;
            
            sellUpdates[1] = ICCListing.SellOrderUpdate({
                structId: 1,
                orderId: orderId,
                addresses: new address[](0),
                prices: pricesArray,
                amounts: new uint256[](0),
                status: 0
            });
            
            // Amounts update (structId: 2)
            uint256[] memory amountsArray = new uint256[](3);
            amountsArray[0] = prep.normalizedReceived; // pending
            amountsArray[1] = 0; // filled
            amountsArray[2] = 0; // amountSent
            
            sellUpdates[2] = ICCListing.SellOrderUpdate({
                structId: 2,
                orderId: orderId,
                addresses: coreAddresses, // Include addresses for volume tracking
                prices: new uint256[](0),
                amounts: amountsArray,
                status: 0
            });
            
            listingContract.ccUpdate(
                new ICCListing.BuyOrderUpdate[](0), 
                sellUpdates, 
                new ICCListing.HistoricalUpdate[](0)
            );
        }
        
        emit OrderCreated(orderId, prep.maker, isBuy);
    }

    function _clearOrderData(
        uint256 orderId,
        bool isBuy
    ) internal {
        // Clears order data, refunds pending amounts, sets status to cancelled
        require(listingTemplate != address(0), "Listing template not set");
        
        ICCListing listingContract = ICCListing(listingTemplate);
        
        address[] memory addresses;
        uint256[] memory amounts;
        uint8 status;
        
        if (isBuy) {
            (addresses,, amounts, status) = listingContract.getBuyOrder(orderId);
        } else {
            (addresses,, amounts, status) = listingContract.getSellOrder(orderId);
        }
        
        require(addresses.length > 0, "Order not found");
        require(addresses[0] == msg.sender, "Only maker can cancel");
        
        // Refund pending amount if order is pending or partially filled
        if (amounts.length > 0 && amounts[0] > 0 && (status == 1 || status == 2)) {
            address tokenAddress = addresses[2]; // startToken
            address recipient = addresses[1];
            
            uint8 tokenDecimals = tokenAddress == address(0) ? 18 : IERC20(tokenAddress).decimals();
            uint256 refundAmount = denormalize(amounts[0], tokenDecimals);
            
            if (tokenAddress == address(0)) {
                // Refund native ETH
                (bool success, ) = recipient.call{value: refundAmount}("");
                require(success, "ETH refund failed");
            } else {
                // Refund ERC20 token via listing template withdrawal
                listingContract.withdrawToken(tokenAddress, refundAmount, recipient);
            }
        }
        
        // Update order status to cancelled
        if (isBuy) {
            ICCListing.BuyOrderUpdate[] memory buyUpdates = new ICCListing.BuyOrderUpdate[](1);
            buyUpdates[0] = ICCListing.BuyOrderUpdate({
                structId: 0,
                orderId: orderId,
                addresses: new address[](0),
                prices: new uint256[](0),
                amounts: new uint256[](0),
                status: 0 // cancelled
            });
            listingContract.ccUpdate(
                buyUpdates, 
                new ICCListing.SellOrderUpdate[](0), 
                new ICCListing.HistoricalUpdate[](0)
            );
        } else {
            ICCListing.SellOrderUpdate[] memory sellUpdates = new ICCListing.SellOrderUpdate[](1);
            sellUpdates[0] = ICCListing.SellOrderUpdate({
                structId: 0,
                orderId: orderId,
                addresses: new address[](0),
                prices: new uint256[](0),
                amounts: new uint256[](0),
                status: 0 // cancelled
            });
            listingContract.ccUpdate(
                new ICCListing.BuyOrderUpdate[](0), 
                sellUpdates, 
                new ICCListing.HistoricalUpdate[](0)
            );
        }
        
        emit OrderCancelled(orderId, msg.sender, isBuy);
    }
}