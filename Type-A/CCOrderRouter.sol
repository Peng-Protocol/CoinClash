// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.1.6
// Changes:
// - v0.1.6: Updated _checkTransferAmountNative to directly transfer ETH to listing address using call. Adjusted createNativeBuyOrder and createNativeSellOrder to validate transfer success.
// - v0.1.5: Added allowance check in _checkTransferAmountToken with explicit error.
// - v0.1.4: Patched _checkTransferAmountNative to remove circular ETH transfer, directly track msg.value. 
// - v0.1.3: Updated settleLongLiquid and settleShortLiquid to use ICCLiquidity.activeLongPayoutsView and ICCLiquidity.activeShortPayoutsView instead of ICCListing for fetching active payout IDs, aligning with payout functionality move to CCLiquidityTemplate.sol v0.1.9.
// - v0.1.2: Updated settleLongLiquid and settleShortLiquid to use activeLongPayoutsView and activeShortPayoutsView for fetching active payout IDs, integrating with updated settleSingleLongLiquid and settleSingleShortLiquid from CCOrderPartial.sol v0.1.4.
// - v0.1.1: Removed settleLong/ShortPayout.
// - v0.1.0: Bumped version
// - v0.0.11: Moved payout-related functions (executeLongPayouts, executeShortPayouts, executeLongPayout, executeShortPayout, settleLongLiquid, settleShortLiquid) from CCLiquidityRouter.sol v0.0.16 and CCLiquidityPartial.sol v0.0.11. Updated compatibility to CCOrderPartial.sol v0.0.04.
// - v0.0.10: Fixed shadowing declaration of 'maker' in clearOrders by reusing the same variable for getBuyOrderCore and getSellOrderCore destructuring.
// - v0.0.9: Removed caller parameter from listingContract.update and transact calls to align with ICCListing.sol v0.0.7 and CCMainPartial.sol v0.0.10. Updated _executeSingleOrder to pass msg.sender as depositor.
// Compatible with CCListing.sol (v0.0.3), CCOrderPartial.sol (v0.0.04), CCMainPartial.sol (v0.0.10).

import "./utils/CCOrderPartial.sol";

contract CCOrderRouter is CCOrderPartial {
    function createTokenBuyOrder(
        address listingAddress,
        address recipientAddress,
        uint256 inputAmount,
        uint256 maxPrice,
        uint256 minPrice
    ) external onlyValidListing(listingAddress) nonReentrant {
        // Creates buy order for ERC20 token, transfers tokens, executes
        ICCListing listingContract = ICCListing(listingAddress);
        OrderPrep memory prep = _handleOrderPrep(
            listingAddress,
            msg.sender,
            recipientAddress,
            inputAmount,
            maxPrice,
            minPrice,
            true
        );
        address tokenBAddress = listingContract.tokenB();
        require(tokenBAddress != address(0), "TokenB must be ERC20");
        (prep.amountReceived, prep.normalizedReceived) = _checkTransferAmountToken(tokenBAddress, msg.sender, listingAddress, inputAmount);
        _executeSingleOrder(listingAddress, prep, true);
    }

    function createNativeBuyOrder(
    address listingAddress,
    address recipientAddress,
    uint256 inputAmount,
    uint256 maxPrice,
    uint256 minPrice
) external payable onlyValidListing(listingAddress) nonReentrant {
    // Creates buy order for native ETH, transfers ETH, executes
    ICCListing listingContract = ICCListing(listingAddress);
    require(listingContract.tokenB() == address(0), "TokenB must be native");
    OrderPrep memory prep = _handleOrderPrep(
        listingAddress,
        msg.sender,
        recipientAddress,
        inputAmount,
        maxPrice,
        minPrice,
        true
    );
    (prep.amountReceived, prep.normalizedReceived) = _checkTransferAmountNative(listingAddress, msg.sender, inputAmount);
    _executeSingleOrder(listingAddress, prep, true);
}

    function createTokenSellOrder(
        address listingAddress,
        address recipientAddress,
        uint256 inputAmount,
        uint256 maxPrice,
        uint256 minPrice
    ) external onlyValidListing(listingAddress) nonReentrant {
        // Creates sell order for ERC20 token, transfers tokens, executes
        ICCListing listingContract = ICCListing(listingAddress);
        OrderPrep memory prep = _handleOrderPrep(
            listingAddress,
            msg.sender,
            recipientAddress,
            inputAmount,
            maxPrice,
            minPrice,
            false
        );
        address tokenAAddress = listingContract.tokenA();
        require(tokenAAddress != address(0), "TokenA must be ERC20");
        (prep.amountReceived, prep.normalizedReceived) = _checkTransferAmountToken(tokenAAddress, msg.sender, listingAddress, inputAmount);
        _executeSingleOrder(listingAddress, prep, false);
    }

    function createNativeSellOrder(
    address listingAddress,
    address recipientAddress,
    uint256 inputAmount,
    uint256 maxPrice,
    uint256 minPrice
) external payable onlyValidListing(listingAddress) nonReentrant {
    // Creates sell order for native ETH, transfers ETH, executes
    ICCListing listingContract = ICCListing(listingAddress);
    require(listingContract.tokenA() == address(0), "TokenA must be native");
    OrderPrep memory prep = _handleOrderPrep(
        listingAddress,
        msg.sender,
        recipientAddress,
        inputAmount,
        maxPrice,
        minPrice,
        false
    );
    (prep.amountReceived, prep.normalizedReceived) = _checkTransferAmountNative(listingAddress, msg.sender, inputAmount);
    _executeSingleOrder(listingAddress, prep, false);
}

    function _checkTransferAmountToken(
    address tokenAddress,
    address from,
    address to,
    uint256 inputAmount
) internal returns (uint256 amountReceived, uint256 normalizedReceived) {
    // Transfers ERC20 tokens, normalizes received amount
    ICCListing listingContract = ICCListing(to);
    uint8 tokenDecimals = IERC20(tokenAddress).decimals();
    uint256 allowance = IERC20(tokenAddress).allowance(from, address(this));
    require(allowance >= inputAmount, "Insufficient token allowance");
    uint256 preBalance = IERC20(tokenAddress).balanceOf(to);
    IERC20(tokenAddress).transferFrom(from, to, inputAmount);
    uint256 postBalance = IERC20(tokenAddress).balanceOf(to);
    amountReceived = postBalance > preBalance ? postBalance - preBalance : 0;
    normalizedReceived = amountReceived > 0 ? normalize(amountReceived, tokenDecimals) : 0;
    require(amountReceived > 0, "No tokens received");
}

    function _checkTransferAmountNative(
    address to,
    address from,
    uint256 inputAmount
) internal returns (uint256 amountReceived, uint256 normalizedReceived) {
    // Transfers ETH directly to listing contract, normalizes received amount
    require(msg.value == inputAmount, "Incorrect ETH amount");
    uint256 preBalance = to.balance;
    (bool success, ) = to.call{value: inputAmount}("");
    require(success, "ETH transfer to listing failed");
    uint256 postBalance = to.balance;
    amountReceived = postBalance > preBalance ? postBalance - preBalance : 0;
    normalizedReceived = amountReceived > 0 ? normalize(amountReceived, 18) : 0;
    require(amountReceived > 0, "No ETH received");
}

    function clearSingleOrder(address listingAddress, uint256 orderIdentifier, bool isBuyOrder) external onlyValidListing(listingAddress) nonReentrant {
        // Clears a single order, maker check in _clearOrderData
        _clearOrderData(listingAddress, orderIdentifier, isBuyOrder);
    }

    function clearOrders(address listingAddress, uint256 maxIterations) external onlyValidListing(listingAddress) nonReentrant {
        // Clears multiple orders for msg.sender up to maxIterations
        ICCListing listingContract = ICCListing(listingAddress);
        uint256[] memory orderIds = listingContract.makerPendingOrdersView(msg.sender);
        uint256 iterationCount = maxIterations < orderIds.length ? maxIterations : orderIds.length;
        for (uint256 i = 0; i < iterationCount; i++) {
            uint256 orderId = orderIds[i];
            bool isBuyOrder = false;
            address maker;
            (maker,,) = listingContract.getBuyOrderCore(orderId);
            if (maker == msg.sender) {
                isBuyOrder = true;
            } else {
                (maker,,) = listingContract.getSellOrderCore(orderId);
                if (maker != msg.sender) {
                    continue;
                }
            }
            _clearOrderData(listingAddress, orderId, isBuyOrder);
        }
    }
}