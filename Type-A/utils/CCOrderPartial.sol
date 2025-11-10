// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.1.10
// Changes:
// - v0.1.10: Added comment clarifying normalizedReceived validation in _executeSingleOrder is before ETH transfer to prevent stuck funds. Added comment in _executeSingleOrder clarifying no race condition for nextOrderId due to EVM sequential execution.
// - v0.1.9: Added validation in _executeSingleOrder to ensure normalizedReceived > 0.
// - v0.1.8: Refactored _executeSingleOrder to use BuyOrderUpdate/SellOrderUpdate structs for ccUpdate calls, ensuring compatibility with CCListingTemplate.sol v0.3.10.
// - v0.1.7: Refactored _executeSingleOrder to split ccUpdate into three separate calls for Core, Pricing, and Amounts structs, ensuring correct UpdateType encoding per CCListingTemplate.sol v0.3.8 requirements.
// - v0.1.6: Replaced updateLiquidity with ccUpdate in settleSingleLongLiquid and settleSingleShortLiquid to align with ICCLiquidity interface update removing updateLiquidity.
// - v0.1.5: Updated settleSingleLongLiquid and settleSingleShortLiquid to use ICCLiquidity instead of ICCListing for getLongPayout, getShortPayout, and ssUpdate, aligning with payout functionality move to CCLiquidityTemplate.sol v0.1.9.
// - v0.1.4: Updated settleSingleLongLiquid and settleSingleShortLiquid to use active payout arrays, fetch liquidity balances, settle required amount, reduce required by requested amount, update filled and amountSent based on pre/post checks, and update liquidity balances via ICCLiquidity.updateLiquidity.
// - v0.1.3: Updated `settleSingleLongLiquid` and `settleSingleShortLiquid` to use `payout.required` or `payout.amount` as `filled` in `PayoutUpdate` to account for transfer taxes, ensuring `filled` reflects the full amount withdrawn from liquidity pool. `amountSent` now uses pre/post balance checks. Removed listing template balance usage for payouts, relying solely on liquidity pool transfers via `_transferNative` or `_transferToken`.
// - v0.1.2: Updated `_executeSingleOrder` to set `filled=0` in BuyOrderAmounts/SellOrderAmounts (structId=2) to ensure unused fields are zeroed, per CCListingTemplate.sol v0.2.26 requirements.
// - v0.1.0: Bumped version
// - v0.0.4: Moved payout-related functionality (PayoutContext, payoutPendingAmounts, _prepPayoutContext, _checkLiquidityBalance, _transferNative, _transferToken, _createPayoutUpdate, settleSingleLongLiquid, settleSingleShortLiquid) from CCLiquidityPartial.sol v0.0.11. Ensured PayoutContext defined before use. Added TransferFailed event and InsufficientAllowance error.
// - v0.0.3: Removed caller parameter from listingContract.update and transact calls to align with ICCListing.sol v0.0.7 and CCMainPartial.sol v0.0.10. Updated _executeSingleOrder to pass msg.sender as depositor.
// - v0.0.2: Replaced invalid try-catch in _clearOrderData with conditional for native/ERC20 transfer.
// - v0.0.1: Updated to use ICCListing interface from CCMainPartial.sol v0.0.26.
// Compatible with CCListing.sol (v0.0.3), CCOrderRouter.sol (v0.0.11).

import "./CCMainPartial.sol";

contract CCOrderPartial is CCMainPartial {
    // Emitted when IERC20.transfer fails
    event TransferFailed(address indexed sender, address indexed token, uint256 amount, bytes reason);
    // Emitted when allowance is insufficient
    error InsufficientAllowance(address sender, address token, uint256 required, uint256 available);

    struct OrderPrep {
        address maker;
        address recipient;
        uint256 amount;
        uint256 maxPrice;
        uint256 minPrice;
        uint256 amountReceived;
        uint256 normalizedReceived;
    }

    mapping(address => mapping(uint256 => uint256)) internal payoutPendingAmounts;

    function _handleOrderPrep(
        address listing,
        address maker,
        address recipient,
        uint256 amount,
        uint256 maxPrice,
        uint256 minPrice,
        bool isBuy
    ) internal view returns (OrderPrep memory) {
        // Prepares order data, normalizes amount based on token decimals
        require(maker != address(0), "Invalid maker");
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        ICCListing listingContract = ICCListing(listing);
        uint8 decimals = isBuy ? listingContract.decimalsB() : listingContract.decimalsA();
        uint256 normalizedAmount = normalize(amount, decimals);
        return OrderPrep(maker, recipient, normalizedAmount, maxPrice, minPrice, 0, 0);
    }

    function _executeSingleOrder(
    address listing,
    OrderPrep memory prep,
    bool isBuy
) internal {
    // Executes single order creation, initializes amountSent and filled to 0
    // No race condition for nextOrderId as EVM processes transactions sequentially
    // Ensures normalizedReceived to listing address is validated before ccUpdate call
    require(prep.normalizedReceived > 0, "No tokens received");
    ICCListing listingContract = ICCListing(listing);
    uint256 orderId = listingContract.getNextOrderId();

    // Prepare updates
    if (isBuy) {
        ICCListing.BuyOrderUpdate[] memory buyUpdates = new ICCListing.BuyOrderUpdate[](3);
        buyUpdates[0] = ICCListing.BuyOrderUpdate({
            structId: 0,
            orderId: orderId,
            makerAddress: prep.maker,
            recipientAddress: prep.recipient,
            status: 1,
            maxPrice: 0,
            minPrice: 0,
            pending: 0,
            filled: 0,
            amountSent: 0
        });
        buyUpdates[1] = ICCListing.BuyOrderUpdate({
            structId: 1,
            orderId: orderId,
            makerAddress: address(0),
            recipientAddress: address(0),
            status: 0,
            maxPrice: prep.maxPrice,
            minPrice: prep.minPrice,
            pending: 0,
            filled: 0,
            amountSent: 0
        });
        buyUpdates[2] = ICCListing.BuyOrderUpdate({
            structId: 2,
            orderId: orderId,
            makerAddress: address(0),
            recipientAddress: address(0),
            status: 0,
            maxPrice: 0,
            minPrice: 0,
            pending: prep.normalizedReceived,
            filled: 0,
            amountSent: 0
        });
        listingContract.ccUpdate(buyUpdates, new ICCListing.SellOrderUpdate[](0), new ICCListing.BalanceUpdate[](0), new ICCListing.HistoricalUpdate[](0));
    } else {
        ICCListing.SellOrderUpdate[] memory sellUpdates = new ICCListing.SellOrderUpdate[](3);
        sellUpdates[0] = ICCListing.SellOrderUpdate({
            structId: 0,
            orderId: orderId,
            makerAddress: prep.maker,
            recipientAddress: prep.recipient,
            status: 1,
            maxPrice: 0,
            minPrice: 0,
            pending: 0,
            filled: 0,
            amountSent: 0
        });
        sellUpdates[1] = ICCListing.SellOrderUpdate({
            structId: 1,
            orderId: orderId,
            makerAddress: address(0),
            recipientAddress: address(0),
            status: 0,
            maxPrice: prep.maxPrice,
            minPrice: prep.minPrice,
            pending: 0,
            filled: 0,
            amountSent: 0
        });
        sellUpdates[2] = ICCListing.SellOrderUpdate({
            structId: 2,
            orderId: orderId,
            makerAddress: address(0),
            recipientAddress: address(0),
            status: 0,
            maxPrice: 0,
            minPrice: 0,
            pending: prep.normalizedReceived,
            filled: 0,
            amountSent: 0
        });
        listingContract.ccUpdate(new ICCListing.BuyOrderUpdate[](0), sellUpdates, new ICCListing.BalanceUpdate[](0), new ICCListing.HistoricalUpdate[](0));
    }
}

    function _clearOrderData(
    address listing,
    uint256 orderId,
    bool isBuy
) internal {
    // Clears order data, refunds pending amounts, sets status to cancelled
    ICCListing listingContract = ICCListing(listing);
    (address maker, address recipient, uint8 status) = isBuy
        ? listingContract.getBuyOrderCore(orderId)
        : listingContract.getSellOrderCore(orderId);
    require(maker == msg.sender, "Only maker can cancel");
    (uint256 pending, uint256 filled, uint256 amountSent) = isBuy
        ? listingContract.getBuyOrderAmounts(orderId)
        : listingContract.getSellOrderAmounts(orderId);
    if (pending > 0 && (status == 1 || status == 2)) {
        address tokenAddress = isBuy ? listingContract.tokenB() : listingContract.tokenA();
        uint8 tokenDecimals = isBuy ? listingContract.decimalsB() : listingContract.decimalsA();
        uint256 refundAmount = denormalize(pending, tokenDecimals);
        if (tokenAddress == address(0)) {
            listingContract.transactNative(refundAmount, recipient);
        } else {
            listingContract.transactToken(tokenAddress, refundAmount, recipient);
        }
    }
    if (isBuy) {
        ICCListing.BuyOrderUpdate[] memory buyUpdates = new ICCListing.BuyOrderUpdate[](1);
        buyUpdates[0] = ICCListing.BuyOrderUpdate({
            structId: 0, // Core
            orderId: orderId,
            makerAddress: address(0),
            recipientAddress: address(0),
            status: 0, // cancelled
            maxPrice: 0,
            minPrice: 0,
            pending: 0,
            filled: 0,
            amountSent: 0
        });
        listingContract.ccUpdate(buyUpdates, new ICCListing.SellOrderUpdate[](0), new ICCListing.BalanceUpdate[](0), new ICCListing.HistoricalUpdate[](0));
    } else {
        ICCListing.SellOrderUpdate[] memory sellUpdates = new ICCListing.SellOrderUpdate[](1);
        sellUpdates[0] = ICCListing.SellOrderUpdate({
            structId: 0, // Core
            orderId: orderId,
            makerAddress: address(0),
            recipientAddress: address(0),
            status: 0, // cancelled
            maxPrice: 0,
            minPrice: 0,
            pending: 0,
            filled: 0,
            amountSent: 0
        });
        listingContract.ccUpdate(new ICCListing.BuyOrderUpdate[](0), sellUpdates, new ICCListing.BalanceUpdate[](0), new ICCListing.HistoricalUpdate[](0));
    }
}

    function _transferNative(
        address payable contractAddr,
        uint256 amountOut,
        address recipientAddress,
        bool isLiquidityContract
    ) internal returns (uint256 amountReceived, uint256 normalizedReceived) {
        // Transfers ETH, tracks received amount
        ICCLiquidity liquidityContract;
        ICCListing listing;
        if (isLiquidityContract) {
            liquidityContract = ICCLiquidity(contractAddr);
        } else {
            listing = ICCListing(contractAddr);
        }
        uint256 preBalance = recipientAddress.balance;
        bool success = true;
        if (isLiquidityContract) {
            try liquidityContract.transactNative(msg.sender, amountOut, recipientAddress) {
                // No return value expected
            } catch (bytes memory reason) {
                success = false;
                emit TransferFailed(msg.sender, address(0), amountOut, reason);
            }
            require(success, "Native transfer failed");
        } else {
            try listing.transactNative(amountOut, recipientAddress) {
                // No return value expected
            } catch (bytes memory reason) {
                success = false;
                emit TransferFailed(msg.sender, address(0), amountOut, reason);
            }
            require(success, "Native transfer failed");
        }
        uint256 postBalance = recipientAddress.balance;
        amountReceived = postBalance > preBalance ? postBalance - preBalance : 0;
        normalizedReceived = amountReceived > 0 ? normalize(amountReceived, 18) : 0;
    }

    function _transferToken(
        address contractAddr,
        address tokenAddress,
        uint256 amountOut,
        address recipientAddress,
        uint8 tokenDecimals,
        bool isLiquidityContract
    ) internal returns (uint256 amountReceived, uint256 normalizedReceived) {
        // Transfers ERC20 tokens, tracks received amount
        ICCLiquidity liquidityContract;
        ICCListing listing;
        if (isLiquidityContract) {
            liquidityContract = ICCLiquidity(contractAddr);
        } else {
            listing = ICCListing(contractAddr);
        }
        uint256 preBalance = IERC20(tokenAddress).balanceOf(recipientAddress);
        bool success = true;
        if (isLiquidityContract) {
            try liquidityContract.transactToken(msg.sender, tokenAddress, amountOut, recipientAddress) {
                // No return value expected
            } catch (bytes memory reason) {
                success = false;
                emit TransferFailed(msg.sender, tokenAddress, amountOut, reason);
            }
            require(success, "ERC20 transfer failed");
        } else {
            try listing.transactToken(tokenAddress, amountOut, recipientAddress) {
                // No return value expected
            } catch (bytes memory reason) {
                success = false;
                emit TransferFailed(msg.sender, tokenAddress, amountOut, reason);
            }
            require(success, "ERC20 transfer failed");
        }
        uint256 postBalance = IERC20(tokenAddress).balanceOf(recipientAddress);
        amountReceived = postBalance > preBalance ? postBalance - preBalance : 0;
        normalizedReceived = amountReceived > 0 ? normalize(amountReceived, tokenDecimals) : 0;
    }
}