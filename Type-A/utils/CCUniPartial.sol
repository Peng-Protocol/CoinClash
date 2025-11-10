// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.2.1 (10/11)
// Changes:
// - (10/11) Refactored _createOrderUpdates into a call-tree of small helper functions using structs. 
// - Removed _computeMaxAmountIn (off-chain calculation)
// - Consolidated _createOrderUpdates (merged buy/sell logic)
// - Removed PrepOrderUpdateResult struct (inline logic)
// - Simplified swap execution with unified _performSwap
// - Removed _prepareTokenSwap (redundant)
// - Removed separate ETH swap functions (consolidated)
// - MAINTAINED: All normalize/denormalize conversions (critical for decimal handling)

import "./CCMainPartial.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory amounts);
    function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts);
}

contract CCUniPartial is CCMainPartial {
    struct SwapContext {
        ICCListing listingContract;
        address makerAddress;
        address recipientAddress;
        uint8 status;
        address tokenIn;
        address tokenOut;
        uint8 decimalsIn;
        uint8 decimalsOut;
        uint256 denormAmountIn;
        uint256 denormAmountOutMin;
        uint256 price;
        uint256 expectedAmountOut;
    }

    struct SettlementContext {
        address tokenA;
        address tokenB;
        uint8 decimalsA;
        uint8 decimalsB;
        address uniswapV2Pair;
    }

    struct OrderContext {
        uint256 orderId;
        uint256 pending;
        uint8 status;
        ICCListing.BuyOrderUpdate[] buyUpdates;
        ICCListing.SellOrderUpdate[] sellUpdates;
    }
    
    struct UpdateIds {
        uint256 orderId;
        address maker;
        address recipient;
    }
    
    struct UpdateAmounts {
        uint256 pending;
        uint256 filled;
        uint256 amountIn;
        uint256 amountOut;
    }

    struct UpdateState {
        uint256 priorSent;
        uint8 decimalsOut;
        bool isBuyOrder;
    }
    
    event OrderSkipped(uint256 orderId, string reason);

    function _getTokenAndDecimals(bool isBuyOrder, SettlementContext memory settlementContext) internal pure returns (address tokenAddress, uint8 tokenDecimals) {
        tokenAddress = isBuyOrder ? settlementContext.tokenB : settlementContext.tokenA;
        tokenDecimals = isBuyOrder ? settlementContext.decimalsB : settlementContext.decimalsA;
        if (tokenAddress == address(0) && !isBuyOrder) revert("Invalid token address for sell order");
        if (tokenDecimals == 0) revert("Invalid token decimals");
    }

    function _prepBuyOrderUpdate(address listingAddress, uint256 orderIdentifier, uint256 amountReceived, SettlementContext memory settlementContext) internal returns (uint256 amountSent) {
        ICCListing listingContract = ICCListing(listingAddress);
        (uint256 pending,,) = listingContract.getBuyOrderAmounts(orderIdentifier);
        if (pending == 0) revert(string(abi.encodePacked("No pending amount for buy order ", uint2str(orderIdentifier))));
        (address tokenAddress, ) = _getTokenAndDecimals(true, settlementContext);
        (, , uint8 orderStatus) = listingContract.getBuyOrderCore(orderIdentifier);
        if (orderStatus != 1) revert(string(abi.encodePacked("Invalid status for buy order ", uint2str(orderIdentifier), ": ", uint2str(orderStatus))));
        
        uint256 preBalance = tokenAddress == address(0) ? address(this).balance : IERC20(tokenAddress).balanceOf(address(this));
        
        if (tokenAddress == address(0)) {
            try listingContract.transactNative{value: amountReceived}(amountReceived, address(this)) {
                amountSent = address(this).balance - preBalance;
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("Native transfer failed for buy order ", uint2str(orderIdentifier), ": ", reason)));
            }
        } else {
            try listingContract.transactToken(tokenAddress, amountReceived, address(this)) {
                amountSent = IERC20(tokenAddress).balanceOf(address(this)) - preBalance;
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("Token transfer failed for buy order ", uint2str(orderIdentifier), ": ", reason)));
            }
        }
        if (amountSent == 0) revert(string(abi.encodePacked("No tokens received for buy order ", uint2str(orderIdentifier))));
    }

    function _prepSellOrderUpdate(address listingAddress, uint256 orderIdentifier, uint256 amountReceived, SettlementContext memory settlementContext) internal returns (uint256 amountSent) {
        ICCListing listingContract = ICCListing(listingAddress);
        (uint256 pending,,) = listingContract.getSellOrderAmounts(orderIdentifier);
        if (pending == 0) revert(string(abi.encodePacked("No pending amount for sell order ", uint2str(orderIdentifier))));
        (address tokenAddress, ) = _getTokenAndDecimals(false, settlementContext);
        (, , uint8 orderStatus) = listingContract.getSellOrderCore(orderIdentifier);
        if (orderStatus != 1) revert(string(abi.encodePacked("Invalid status for sell order ", uint2str(orderIdentifier), ": ", uint2str(orderStatus))));
        
        uint256 preBalance = tokenAddress == address(0) ? address(this).balance : IERC20(tokenAddress).balanceOf(address(this));
        
        if (tokenAddress == address(0)) {
            try listingContract.transactNative{value: amountReceived}(amountReceived, address(this)) {
                amountSent = address(this).balance - preBalance;
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("Native transfer failed for sell order ", uint2str(orderIdentifier), ": ", reason)));
            }
        } else {
            try listingContract.transactToken(tokenAddress, amountReceived, address(this)) {
                amountSent = IERC20(tokenAddress).balanceOf(address(this)) - preBalance;
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("Token transfer failed for sell order ", uint2str(orderIdentifier), ": ", reason)));
            }
        }
        if (amountSent == 0) revert(string(abi.encodePacked("No tokens received for sell order ", uint2str(orderIdentifier))));
    }

    function _computeSwapImpact(uint256 amountIn, bool isBuyOrder, SettlementContext memory settlementContext) internal view returns (uint256 price, uint256 amountOut) {
        uint8 decimalsIn = isBuyOrder ? settlementContext.decimalsB : settlementContext.decimalsA;
        uint8 decimalsOut = isBuyOrder ? settlementContext.decimalsA : settlementContext.decimalsB;
        uint256 reserveIn = IERC20(isBuyOrder ? settlementContext.tokenB : settlementContext.tokenA).balanceOf(settlementContext.uniswapV2Pair);
        uint256 reserveOut = IERC20(isBuyOrder ? settlementContext.tokenA : settlementContext.tokenB).balanceOf(settlementContext.uniswapV2Pair);
        
        if (reserveIn == 0 || reserveOut == 0) revert("Zero reserves in Uniswap pair");
        
        // Normalize to 18 decimals for calculation
        uint256 normalizedReserveIn = normalize(reserveIn, decimalsIn);
        uint256 normalizedReserveOut = normalize(reserveOut, decimalsOut);
        uint256 normalizedAmountIn = normalize(amountIn, decimalsIn);
        uint256 amountInAfterFee = (normalizedAmountIn * 997) / 1000;
        uint256 normalizedAmountOut = (amountInAfterFee * normalizedReserveOut) / (normalizedReserveIn + amountInAfterFee);
        
        price = ICCListing(settlementContext.uniswapV2Pair).prices(0);
        if (price == 0) revert("Invalid listing price");
        
        // Denormalize back to actual token decimals
        amountOut = denormalize(normalizedAmountOut, decimalsOut);
    }

    function _prepareSwapData(address listingAddress, uint256 orderIdentifier, uint256 amountIn, SettlementContext memory settlementContext) internal view returns (SwapContext memory context, address[] memory path) {
        ICCListing listingContract = ICCListing(listingAddress);
        (context.makerAddress, context.recipientAddress, context.status) = listingContract.getBuyOrderCore(orderIdentifier);
        context.listingContract = listingContract;
        context.tokenIn = settlementContext.tokenB;
        context.tokenOut = settlementContext.tokenA;
        context.decimalsIn = settlementContext.decimalsB;
        context.decimalsOut = settlementContext.decimalsA;
        
        // Denormalize amountIn from 18 decimals to actual token decimals
        context.denormAmountIn = denormalize(amountIn, context.decimalsIn);
        
        (context.price, context.expectedAmountOut) = _computeSwapImpact(context.denormAmountIn, true, settlementContext);
        context.denormAmountOutMin = context.expectedAmountOut * 95 / 100;
        
        path = new address[](2);
        path[0] = context.tokenIn;
        path[1] = context.tokenOut;
    }

    function _prepareSellSwapData(address listingAddress, uint256 orderIdentifier, uint256 amountIn, SettlementContext memory settlementContext) internal view returns (SwapContext memory context, address[] memory path) {
        ICCListing listingContract = ICCListing(listingAddress);
        (context.makerAddress, context.recipientAddress, context.status) = listingContract.getSellOrderCore(orderIdentifier);
        context.listingContract = listingContract;
        context.tokenIn = settlementContext.tokenA;
        context.tokenOut = settlementContext.tokenB;
        context.decimalsIn = settlementContext.decimalsA;
        context.decimalsOut = settlementContext.decimalsB;
        
        // Denormalize amountIn from 18 decimals to actual token decimals
        context.denormAmountIn = denormalize(amountIn, context.decimalsIn);
        
        (context.price, context.expectedAmountOut) = _computeSwapImpact(context.denormAmountIn, false, settlementContext);
        context.denormAmountOutMin = context.expectedAmountOut * 95 / 100;
        
        path = new address[](2);
        path[0] = context.tokenIn;
        path[1] = context.tokenOut;
    }

    function _performSwap(SwapContext memory context, address[] memory path, bool isETHIn, bool isETHOut) internal returns (uint256 amountOut) {
        uint256 preBalanceOut = isETHOut ? context.recipientAddress.balance : IERC20(context.tokenOut).balanceOf(context.recipientAddress);
        
        if (isETHIn && !isETHOut) {
            try IUniswapV2Router02(uniswapV2Router).swapExactETHForTokens{value: context.denormAmountIn}(context.denormAmountOutMin, path, context.recipientAddress, block.timestamp + 15) returns (uint256[] memory) {
                amountOut = IERC20(context.tokenOut).balanceOf(context.recipientAddress) - preBalanceOut;
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("ETH->Token swap failed: ", reason)));
            }
        } else if (!isETHIn && isETHOut) {
            try IUniswapV2Router02(uniswapV2Router).swapExactTokensForETH(context.denormAmountIn, context.denormAmountOutMin, path, context.recipientAddress, block.timestamp + 15) returns (uint256[] memory) {
                amountOut = context.recipientAddress.balance - preBalanceOut;
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("Token->ETH swap failed: ", reason)));
            }
        } else {
            try IUniswapV2Router02(uniswapV2Router).swapExactTokensForTokens(context.denormAmountIn, context.denormAmountOutMin, path, context.recipientAddress, block.timestamp + 15) returns (uint256[] memory) {
                amountOut = IERC20(context.tokenOut).balanceOf(context.recipientAddress) - preBalanceOut;
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("Token swap failed: ", reason)));
            }
        }
        if (amountOut == 0) revert("No tokens received in swap");
    }

    // Helper 1: compute new pending & status
    function _computePendingAndStatus(uint256 pending, uint256 amountIn) 
        internal pure returns (uint256 newPending, uint8 newStatus) 
    {
        newPending = pending > amountIn ? pending - amountIn : 0;
        newStatus = newPending == 0 ? 3 : 2; // 3 = filled, 2 = partial
    }

    // Helper 2: normalize output amount
    function _normalizeOut(uint256 amountOut, uint8 decimalsOut) 
        internal pure returns (uint256 normalized) 
    {
        normalized = normalize(amountOut, decimalsOut);
    }

    // Helper 3: build single BuyOrderUpdate (structId 2)
    function _buildBuyPartial(
        UpdateIds memory ids,
        UpdateAmounts memory amounts,
        UpdateState memory state,
        uint256 newPending,
        uint8 newStatus
    ) internal pure returns (ICCListing.BuyOrderUpdate memory upd) {
        upd.structId = 2;
        upd.orderId = ids.orderId;
        upd.makerAddress = ids.maker;
        upd.recipientAddress = ids.recipient;
        upd.status = 1;
        upd.maxPrice = 0;
        upd.minPrice = 0;
        upd.pending = newPending;
        upd.filled = amounts.filled + amounts.amountIn;
        upd.amountSent = state.priorSent + _normalizeOut(amounts.amountOut, state.decimalsOut);
    }

    // Helper 4: build single BuyOrderUpdate (structId 0) - terminal
    function _buildBuyTerminal(UpdateIds memory ids, uint8 newStatus) 
        internal pure returns (ICCListing.BuyOrderUpdate memory upd) 
    {
        upd.structId = 0;
        upd.orderId = ids.orderId;
        upd.makerAddress = ids.maker;
        upd.recipientAddress = ids.recipient;
        upd.status = newStatus;
        upd.maxPrice = 0;
        upd.minPrice = 0;
        upd.pending = 0;
        upd.filled = 0;
        upd.amountSent = 0;
    }

    // Helper 5: assemble final buy arrays
    function _assembleBuyUpdates(
        ICCListing.BuyOrderUpdate memory buyPartial,
        ICCListing.BuyOrderUpdate memory buyTerminal
    ) internal pure returns (ICCListing.BuyOrderUpdate[] memory buyUpdates) {
        buyUpdates = new ICCListing.BuyOrderUpdate[](2);
        buyUpdates[0] = buyPartial;
        buyUpdates[1] = buyTerminal;
    }

    // Helper 6: build single SellOrderUpdate (structId 2)
    function _buildSellPartial(
        UpdateIds memory ids,
        UpdateAmounts memory amounts,
        UpdateState memory state,
        uint256 newPending,
        uint8 newStatus
    ) internal pure returns (ICCListing.SellOrderUpdate memory upd) {
        upd.structId = 2;
        upd.orderId = ids.orderId;
        upd.makerAddress = ids.maker;
        upd.recipientAddress = ids.recipient;
        upd.status = 1;
        upd.maxPrice = 0;
        upd.minPrice = 0;
        upd.pending = newPending;
        upd.filled = amounts.filled + amounts.amountIn;
        upd.amountSent = state.priorSent + _normalizeOut(amounts.amountOut, state.decimalsOut);
    }

    // Helper 7: build single SellOrderUpdate (structId 0) - terminal
    function _buildSellTerminal(UpdateIds memory ids, uint8 newStatus) 
        internal pure returns (ICCListing.SellOrderUpdate memory upd) 
    {
        upd.structId = 0;
        upd.orderId = ids.orderId;
        upd.makerAddress = ids.maker;
        upd.recipientAddress = ids.recipient;
        upd.status = newStatus;
        upd.maxPrice = 0;
        upd.minPrice = 0;
        upd.pending = 0;
        upd.filled = 0;
        upd.amountSent = 0;
    }

    // Helper 8: assemble final sell arrays
    function _assembleSellUpdates(
        ICCListing.SellOrderUpdate memory sellPartial,
        ICCListing.SellOrderUpdate memory sellTerminal
    ) internal pure returns (ICCListing.SellOrderUpdate[] memory sellUpdates) {
        sellUpdates = new ICCListing.SellOrderUpdate[](2);
        sellUpdates[0] = sellPartial;
        sellUpdates[1] = sellTerminal;
    }

    /**
     * @dev Refactored _createOrderUpdates - call tree eliminates stack-too-deep
     *       All logic identical to previous monolithic version
     */
    function _createOrderUpdates(
        uint256 orderIdentifier,
        address makerAddress,
        address recipient,
        uint256 pendingAmount,
        uint256 filled,
        uint256 amountIn,
        uint256 amountOut,
        uint256 priorAmountSent,
        bool isBuyOrder,
        uint8 decimalsOut
    ) internal pure returns (
        ICCListing.BuyOrderUpdate[] memory buyUpdates,
        ICCListing.SellOrderUpdate[] memory sellUpdates
    ) {
        // Step 1: Group inputs
        UpdateIds memory ids = UpdateIds(orderIdentifier, makerAddress, recipient);
        UpdateAmounts memory amounts = UpdateAmounts(pendingAmount, filled, amountIn, amountOut);
        UpdateState memory state = UpdateState(priorAmountSent, decimalsOut, isBuyOrder);

        // Step 2: Compute pending & status
        (uint256 newPending, uint8 newStatus) = _computePendingAndStatus(pendingAmount, amountIn);

        if (isBuyOrder) {
            // Buy path
            ICCListing.BuyOrderUpdate memory buyPartial = _buildBuyPartial(ids, amounts, state, newPending, newStatus);
            ICCListing.BuyOrderUpdate memory buyTerminal = _buildBuyTerminal(ids, newStatus);
            buyUpdates = _assembleBuyUpdates(buyPartial, buyTerminal);
            sellUpdates = new ICCListing.SellOrderUpdate[](0);
        } else {
            // Sell path
            ICCListing.SellOrderUpdate memory sellPartial = _buildSellPartial(ids, amounts, state, newPending, newStatus);
            ICCListing.SellOrderUpdate memory sellTerminal = _buildSellTerminal(ids, newStatus);
            sellUpdates = _assembleSellUpdates(sellPartial, sellTerminal);
            buyUpdates = new ICCListing.BuyOrderUpdate[](0);
        }
    }

    function _executePartialBuySwap(address listingAddress, uint256 orderIdentifier, uint256 amountIn, uint256 pendingAmount, SettlementContext memory settlementContext) internal returns (ICCListing.BuyOrderUpdate[] memory buyUpdates) {
        (SwapContext memory context, address[] memory path) = _prepareSwapData(listingAddress, orderIdentifier, amountIn, settlementContext);
        if (context.price == 0) {
            emit OrderSkipped(orderIdentifier, "Zero price in swap data");
            return new ICCListing.BuyOrderUpdate[](0);
        }
        
        uint256 amountOut = _performSwap(context, path, context.tokenIn == address(0), context.tokenOut == address(0));
        (, uint256 filled, uint256 priorAmountSent) = context.listingContract.getBuyOrderAmounts(orderIdentifier);
        (buyUpdates,) = _createOrderUpdates(orderIdentifier, context.makerAddress, context.recipientAddress, pendingAmount, filled, amountIn, amountOut, priorAmountSent, true, context.decimalsOut);
    }

    function _executePartialSellSwap(address listingAddress, uint256 orderIdentifier, uint256 amountIn, uint256 pendingAmount, SettlementContext memory settlementContext) internal returns (ICCListing.SellOrderUpdate[] memory sellUpdates) {
        (SwapContext memory context, address[] memory path) = _prepareSellSwapData(listingAddress, orderIdentifier, amountIn, settlementContext);
        if (context.price == 0) {
            emit OrderSkipped(orderIdentifier, "Zero price in swap data");
            return new ICCListing.SellOrderUpdate[](0);
        }
        
        _prepSellOrderUpdate(listingAddress, orderIdentifier, context.denormAmountIn, settlementContext);
        uint256 amountOut = _performSwap(context, path, context.tokenIn == address(0), context.tokenOut == address(0));
        (, uint256 filled, uint256 priorAmountSent) = context.listingContract.getSellOrderAmounts(orderIdentifier);
        (,sellUpdates) = _createOrderUpdates(orderIdentifier, context.makerAddress, context.recipientAddress, pendingAmount, filled, amountIn, amountOut, priorAmountSent, false, context.decimalsOut);
    }

    function uint2str(uint256 _i) internal pure returns (string memory str) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        str = string(bstr);
    }
}