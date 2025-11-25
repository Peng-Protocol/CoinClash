// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.4.4 (25/11/2025)
// Changes:
// - Corrected buy order settlement path.

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
        address tokenA; // Output token for buy, input token for sell
        address tokenB; // Input token for buy, output token for sell
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
        address startToken;
        address endToken;
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
    
    struct ReserveData {
    uint256 reserveIn;
    uint256 reserveOut;
    uint8 decimalsIn;
    uint8 decimalsOut;
}

struct SwapMath {
    uint256 normalizedReserveIn;
    uint256 normalizedReserveOut;
    uint256 normalizedAmountIn;
    uint256 amountInAfterFee;
    uint256 normalizedAmountOut;
}
    
    event OrderSkipped(uint256 orderId, string reason);

    function _getTokenAndDecimals(bool isBuyOrder, SettlementContext memory settlementContext) internal pure returns (address tokenAddress, uint8 tokenDecimals) {
        tokenAddress = isBuyOrder ? settlementContext.tokenB : settlementContext.tokenA;
        tokenDecimals = isBuyOrder ? settlementContext.decimalsB : settlementContext.decimalsA;
        if (tokenAddress == address(0) && !isBuyOrder) revert("Invalid token address for sell order");
        if (tokenDecimals == 0) revert("Invalid token decimals");
    }

    function _callWithdrawNative(
    ICCListing listingContract,
    address tokenAddress,
    uint256 amountRequested,
    uint256 preBalance
) internal returns (uint256 amountSent) {
    // Encode the non-payable function call
    bytes memory data = abi.encodeWithSelector(
        listingContract.withdrawToken.selector,
        tokenAddress,
        amountRequested,
        address(this)
    );

    // Perform low-level call with ETH value
    (bool success, bytes memory result) = address(listingContract).call{value: amountRequested}(data);
    
    if (!success) {
        // Bubble up revert reason if available
        if (result.length > 0) {
            assembly {
                let resultData := add(result, 0x20)
                let resultLen := mload(result)
                revert(resultData, resultLen)
            }
        } else {
            revert("Native withdrawal failed: no reason");
        }
    }

    amountSent = address(this).balance - preBalance;
}

// (0.4.4) This function is now responsible for withdrawing the swap input token (Token B) from the Listing Template.
function _prepBuyOrderUpdate(
    address listingAddress,
    uint256 orderIdentifier,
    uint256 denormAmountIn, // Denormalized Token B amount
    SettlementContext memory settlementContext
) internal {
    // Set token context for withdrawal (Token B is the token being withdrawn from Listing)
    address tokenToWithdraw = settlementContext.tokenB; 
    
    // Perform the transfer from the Listing address (must have approved this Router)
    // to this contract (the Router) for the swap input.
    if (!IERC20(tokenToWithdraw).transferFrom(listingAddress, address(this), denormAmountIn)) {
        // Construct a specific revert message for clarity
        string memory errorMessage = string(abi.encodePacked("Token transfer failed for buy order ", uint2str(orderIdentifier), ": Listing withdrawal failed"));
        revert(errorMessage); 
    }
}

function _prepSellOrderUpdate(
    address listingAddress,
    uint256 orderIdentifier,
    uint256 amountReceived,
    SettlementContext memory settlementContext
) internal returns (uint256 amountSent) {
    ICCListing listingContract = ICCListing(listingAddress);
    
    // Get order amounts to verify pending
    (, , uint256[] memory amounts, uint8 orderStatus) = listingContract.getSellOrder(orderIdentifier);
    if (amounts[0] == 0) revert(string(abi.encodePacked("No pending amount for sell order ", uint2str(orderIdentifier))));
    if (orderStatus != 1) revert(string(abi.encodePacked("Invalid status for sell order ", uint2str(orderIdentifier), ": ", uint2str(orderStatus))));
    
    (address tokenAddress, ) = _getTokenAndDecimals(false, settlementContext);
    uint256 preBalance = tokenAddress == address(0) ? address(this).balance : IERC20(tokenAddress).balanceOf(address(this));
    
    if (tokenAddress == address(0)) {
        amountSent = _callWithdrawNative(listingContract, tokenAddress, amountReceived, preBalance);
    } else {
        try listingContract.withdrawToken(tokenAddress, amountReceived, address(this)) {
            amountSent = IERC20(tokenAddress).balanceOf(address(this)) - preBalance;
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Token transfer failed for sell order ", uint2str(orderIdentifier), ": ", reason)));
        }
    }
    if (amountSent == 0) revert(string(abi.encodePacked("No tokens received for sell order ", uint2str(orderIdentifier))));
}

    function _loadReserves(
    bool isBuyOrder,
    SettlementContext memory settlementContext
) internal view returns (ReserveData memory data) {
    // Load token addresses and decimals based on order direction
    // Buy: tokenB in, tokenA out | Sell: tokenA in, tokenB out
    data.decimalsIn = isBuyOrder ? settlementContext.decimalsB : settlementContext.decimalsA;
    data.decimalsOut = isBuyOrder ? settlementContext.decimalsA : settlementContext.decimalsB;

    address tokenIn = isBuyOrder ? settlementContext.tokenB : settlementContext.tokenA;
    address tokenOut = isBuyOrder ? settlementContext.tokenA : settlementContext.tokenB;

    // Fetch reserves from Uniswap V2 pair
    data.reserveIn = IERC20(tokenIn).balanceOf(settlementContext.uniswapV2Pair);
    data.reserveOut = IERC20(tokenOut).balanceOf(settlementContext.uniswapV2Pair);

    if (data.reserveIn == 0 || data.reserveOut == 0) revert("Zero reserves in Uniswap pair");
}

function _calculateSwap(
    uint256 amountIn,
    ReserveData memory reserves
) internal pure returns (uint256 normalizedAmountOut) {
    SwapMath memory m;
    m.normalizedReserveIn = normalize(reserves.reserveIn, reserves.decimalsIn);
    m.normalizedReserveOut = normalize(reserves.reserveOut, reserves.decimalsOut);
    m.normalizedAmountIn = normalize(amountIn, reserves.decimalsIn);
    m.amountInAfterFee = (m.normalizedAmountIn * 997) / 1000;
    m.normalizedAmountOut = (m.amountInAfterFee * m.normalizedReserveOut) / (m.normalizedReserveIn + m.amountInAfterFee);
    normalizedAmountOut = m.normalizedAmountOut;
}

function _computeSwapImpact(
    uint256 amountIn,
    bool isBuyOrder,
    SettlementContext memory settlementContext
) internal view returns (uint256 price, uint256 amountOut) {
    // Step 1: Load reserves and decimals
    ReserveData memory reserves = _loadReserves(isBuyOrder, settlementContext);

    // Step 2: Perform swap math
    uint256 normalizedAmountOut = _calculateSwap(amountIn, reserves);

    // Step 3: Get price from listing
    address tokenInAddr = isBuyOrder ? settlementContext.tokenB : settlementContext.tokenA;
    address tokenOutAddr = isBuyOrder ? settlementContext.tokenA : settlementContext.tokenB;
    ICCListing listingContract = ICCListing(settlementContext.uniswapV2Pair);
    price = listingContract.prices(tokenInAddr, tokenOutAddr);
    if (price == 0) revert("Invalid listing price");

    // Step 4: Denormalize output
    amountOut = denormalize(normalizedAmountOut, reserves.decimalsOut);
}

    // (0.4.4)

function _prepareBuySwapData(
    address listingAddress,
    uint256 orderIdentifier,
    uint256 amountIn, // Normalized amount of Token B (Swap Input)
    address[] memory addresses,
    SettlementContext memory settlementContext
) internal view returns (SwapContext memory context, address[] memory path) {
    // addresses[2] = Token A (Output), addresses[3] = Token B (Input)
    context.listingContract = ICCListing(listingAddress);
    context.makerAddress = addresses[0];
    context.recipientAddress = addresses[1];
    
    // SWAP DIRECTION: Token B -> Token A (Buy order: pay B, receive A)
    context.tokenIn = addresses[3];  // Token B
    context.tokenOut = addresses[2]; // Token A

    context.decimalsIn = settlementContext.decimalsB;
    context.decimalsOut = settlementContext.decimalsA;

    // Denormalize input amount for actual transfer/swap
    context.denormAmountIn = denormalize(amountIn, context.decimalsIn); 

    // === FIXED: Use correct on-chain swap impact calculation ===
    (context.price, context.expectedAmountOut) = _computeSwapImpact(
        context.denormAmountIn, true, settlementContext);

    if (context.price == 0) {
        revert("Invalid price from swap impact calculation");
    }

    // Apply 5% slippage tolerance (95% of expected)
    context.denormAmountOutMin = context.expectedAmountOut * 95 / 100;

    // Simple direct path: Token B → Token A
    path = new address[](2);
    path[0] = context.tokenIn;
    path[1] = context.tokenOut;
}

    function _prepareSellSwapData(
        address listingAddress,
        uint256 orderIdentifier,
        uint256 amountIn,
        address[] memory addresses,
        SettlementContext memory settlementContext
    ) internal view returns (SwapContext memory context, address[] memory path) {
        ICCListing listingContract = ICCListing(listingAddress);
        
        // addresses[0] = maker, addresses[1] = recipient
        context.makerAddress = addresses[0];
        context.recipientAddress = addresses[1];
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
        // Get router from listing template
        address router = ICCListing(listingTemplate).uniswapV2Router();
        require(router != address(0), "Router not set");
        
        uint256 preBalanceOut = isETHOut ? context.recipientAddress.balance : IERC20(context.tokenOut).balanceOf(context.recipientAddress);
        
        if (isETHIn && !isETHOut) {
            try IUniswapV2Router02(router).swapExactETHForTokens{value: context.denormAmountIn}(context.denormAmountOutMin, path, context.recipientAddress, block.timestamp + 15) returns (uint256[] memory) {
                amountOut = IERC20(context.tokenOut).balanceOf(context.recipientAddress) - preBalanceOut;
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("ETH->Token swap failed: ", reason)));
            }
        } else if (!isETHIn && isETHOut) {
            try IUniswapV2Router02(router).swapExactTokensForETH(context.denormAmountIn, context.denormAmountOutMin, path, context.recipientAddress, block.timestamp + 15) returns (uint256[] memory) {
                amountOut = context.recipientAddress.balance - preBalanceOut;
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("Token->ETH swap failed: ", reason)));
            }
        } else {
            try IUniswapV2Router02(router).swapExactTokensForTokens(context.denormAmountIn, context.denormAmountOutMin, path, context.recipientAddress, block.timestamp + 15) returns (uint256[] memory) {
                amountOut = IERC20(context.tokenOut).balanceOf(context.recipientAddress) - preBalanceOut;
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("Token swap failed: ", reason)));
            }
        }
        if (amountOut == 0) revert("No tokens received in swap");
    }

    function _computePendingAndStatus(uint256 pending, uint256 amountIn) 
        internal pure returns (uint256 newPending, uint8 newStatus) 
    {
        newPending = pending > amountIn ? pending - amountIn : 0;
        newStatus = newPending == 0 ? 3 : 2; // 3 = filled, 2 = partial
    }

    function _normalizeOut(uint256 amountOut, uint8 decimalsOut) 
        internal pure returns (uint256 normalized) 
    {
        normalized = normalize(amountOut, decimalsOut);
    }

    function _buildBuyUpdate(
        uint8 structId,
        UpdateIds memory ids,
        UpdateAmounts memory amounts,
        UpdateState memory state,
        uint256 newPending,
        uint8 newStatus
    ) internal pure returns (ICCListing.BuyOrderUpdate memory upd) {
        upd.structId = structId;
        upd.orderId = ids.orderId;
        
        // Build addresses array: [maker, recipient, startToken, endToken]
        upd.addresses = new address[](4);
        upd.addresses[0] = ids.maker;
        upd.addresses[1] = ids.recipient;
        upd.addresses[2] = ids.startToken;
        upd.addresses[3] = ids.endToken;
        
        // Build prices array: [maxPrice, minPrice]
        upd.prices = new uint256[](2);
        upd.prices[0] = 0;
        upd.prices[1] = 0;
        
        if (structId == 2) {
            // Amounts update: [pending, filled, amountSent]
            upd.amounts = new uint256[](3);
            upd.amounts[0] = newPending;
            upd.amounts[1] = amounts.filled + amounts.amountIn;
            upd.amounts[2] = state.priorSent + _normalizeOut(amounts.amountOut, state.decimalsOut);
            upd.status = 1;
        } else {
            // Status update only
            upd.amounts = new uint256[](3);
            upd.amounts[0] = 0;
            upd.amounts[1] = 0;
            upd.amounts[2] = 0;
            upd.status = newStatus;
        }
    }

    function _buildSellUpdate(
        uint8 structId,
        UpdateIds memory ids,
        UpdateAmounts memory amounts,
        UpdateState memory state,
        uint256 newPending,
        uint8 newStatus
    ) internal pure returns (ICCListing.SellOrderUpdate memory upd) {
        upd.structId = structId;
        upd.orderId = ids.orderId;
        
        // Build addresses array: [maker, recipient, startToken, endToken]
        upd.addresses = new address[](4);
        upd.addresses[0] = ids.maker;
        upd.addresses[1] = ids.recipient;
        upd.addresses[2] = ids.startToken;
        upd.addresses[3] = ids.endToken;
        
        // Build prices array: [maxPrice, minPrice]
        upd.prices = new uint256[](2);
        upd.prices[0] = 0;
        upd.prices[1] = 0;
        
        if (structId == 2) {
            // Amounts update: [pending, filled, amountSent]
            upd.amounts = new uint256[](3);
            upd.amounts[0] = newPending;
            upd.amounts[1] = amounts.filled + amounts.amountIn;
            upd.amounts[2] = state.priorSent + _normalizeOut(amounts.amountOut, state.decimalsOut);
            upd.status = 1;
        } else {
            // Status update only
            upd.amounts = new uint256[](3);
            upd.amounts[0] = 0;
            upd.amounts[1] = 0;
            upd.amounts[2] = 0;
            upd.status = newStatus;
        }
    }

    function _createOrderUpdates(
        uint256 orderIdentifier,
        address[] memory addresses,
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
        // Extract from addresses array: [maker, recipient, startToken, endToken]
        UpdateIds memory ids = UpdateIds(
            orderIdentifier,
            addresses[0],
            addresses[1],
            addresses[2],
            addresses[3]
        );
        UpdateAmounts memory amounts = UpdateAmounts(pendingAmount, filled, amountIn, amountOut);
        UpdateState memory state = UpdateState(priorAmountSent, decimalsOut, isBuyOrder);

        (uint256 newPending, uint8 newStatus) = _computePendingAndStatus(pendingAmount, amountIn);

        if (isBuyOrder) {
            buyUpdates = new ICCListing.BuyOrderUpdate[](2);
            buyUpdates[0] = _buildBuyUpdate(2, ids, amounts, state, newPending, newStatus); // Amounts update
            buyUpdates[1] = _buildBuyUpdate(0, ids, amounts, state, newPending, newStatus); // Status update
            sellUpdates = new ICCListing.SellOrderUpdate[](0);
        } else {
            sellUpdates = new ICCListing.SellOrderUpdate[](2);
            sellUpdates[0] = _buildSellUpdate(2, ids, amounts, state, newPending, newStatus); // Amounts update
            sellUpdates[1] = _buildSellUpdate(0, ids, amounts, state, newPending, newStatus); // Status update
            buyUpdates = new ICCListing.BuyOrderUpdate[](0);
        }
    }
 
// ADJUSTED (0.4.4) _executePartialBuySwap (Logic replaced to mirror Sell Order flow)
  // – correct tuple unpacking
    function _executePartialBuySwap(
        address listingAddress,
        uint256 orderIdentifier,
        uint256 amountIn,          // Normalized amount of Token B (Swap Input)
        uint256 pendingAmount,     // Normalized pending amount of Token B
        address[] memory addresses,
        uint256[] memory amounts,
        SettlementContext memory settlementContext
    ) internal returns (ICCListing.BuyOrderUpdate[] memory buyUpdates) {

        settlementContext.tokenA = addresses[2]; 
        settlementContext.tokenB = addresses[3]; 

        (SwapContext memory context, address[] memory path) = _prepareBuySwapData(
            listingAddress, 
            orderIdentifier, 
            amountIn,
            addresses, 
            settlementContext
        );
        
        if (context.price == 0) {
            emit OrderSkipped(orderIdentifier, "Zero price in swap data");
            return new ICCListing.BuyOrderUpdate[](0);
        }
        
        _prepBuyOrderUpdate(listingAddress, orderIdentifier, context.denormAmountIn, settlementContext); 

        uint256 amountOut = _performSwap(
            context, 
            path, 
            context.tokenIn == address(0), 
            context.tokenOut == address(0) 
        );
        
        // FIXED: correctly unpack only the buy updates (discard sell updates)
        (buyUpdates, ) = _createOrderUpdates(
            orderIdentifier,
            addresses,
            pendingAmount,
            amounts[1],      // filled
            amountIn,
            amountOut,
            amounts[2],      // priorAmountSent
            true,            // isBuyOrder
            context.decimalsOut
        );
    }

    function _executePartialSellSwap(
        address listingAddress,
        uint256 orderIdentifier,
        uint256 amountIn,
        uint256 pendingAmount,
        address[] memory addresses,
        uint256[] memory amounts,
        SettlementContext memory settlementContext
    ) internal returns (ICCListing.SellOrderUpdate[] memory sellUpdates) {
        (SwapContext memory context, address[] memory path) = _prepareSellSwapData(listingAddress, orderIdentifier, amountIn, addresses, settlementContext);
        if (context.price == 0) {
            emit OrderSkipped(orderIdentifier, "Zero price in swap data");
            return new ICCListing.SellOrderUpdate[](0);
        }
        
        _prepSellOrderUpdate(listingAddress, orderIdentifier, context.denormAmountIn, settlementContext);
        uint256 amountOut = _performSwap(context, path, context.tokenIn == address(0), context.tokenOut == address(0));
        
        // amounts[1] = filled, amounts[2] = priorAmountSent
        (,sellUpdates) = _createOrderUpdates(
            orderIdentifier,
            addresses,
            pendingAmount,
            amounts[1],
            amountIn,
            amountOut,
            amounts[2],
            false,
            context.decimalsOut
        );
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