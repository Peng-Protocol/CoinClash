/*
 SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
 Version: 0.1.0 (11/12/2025)
 Changes:
 - v0.1.0 (11/12): Complete refactor for monolithic architecture. Removed per-pair assumptions.
   Updated to work with CCListingTemplate v0.4.2 and CCLiquidityTemplate v0.2.0.
   Moved all interfaces from CCMainPartial. Orders now use startToken/endToken.
   Removed volumeBalances calls (now queries Uniswap pair directly).
   Updated fee computation to use token-specific liquidity amounts.
*/

pragma solidity ^0.8.2;

import "../imports/IERC20.sol";
import "../imports/ReentrancyGuard.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}

interface ICCListing {
    struct BuyOrderUpdate {
        uint8 structId;
        uint256 orderId;
        address[] addresses;
        uint256[] prices;
        uint256[] amounts;
        uint8 status;
    }

    struct SellOrderUpdate {
        uint8 structId;
        uint256 orderId;
        address[] addresses;
        uint256[] prices;
        uint256[] amounts;
        uint8 status;
    }
    
    struct HistoricalUpdate {
        address tokenA;
        address tokenB;
        uint256 price;
        uint256 xBalance;
        uint256 yBalance;
        uint256 xVolume;
        uint256 yVolume;
        uint256 timestamp;
    }

    struct HistoricalData {
        uint256 price;
        uint256 xBalance;
        uint256 yBalance;
        uint256 xVolume;
        uint256 yVolume;
        uint256 timestamp;
    }

    function prices(address tokenA, address tokenB) external view returns (uint256);
    function uniswapV2Factory() external view returns (address);
    function makerPendingOrdersView(address maker) external view returns (uint256[] memory);
    function getBuyOrder(uint256 orderId) external view returns (address[] memory addresses, uint256[] memory prices_, uint256[] memory amounts, uint8 status);
    function getSellOrder(uint256 orderId) external view returns (address[] memory addresses, uint256[] memory prices_, uint256[] memory amounts, uint8 status);
    function getHistoricalDataView(address tokenA, address tokenB, uint256 index) external view returns (HistoricalData memory);
    function historicalDataLengthView(address tokenA, address tokenB) external view returns (uint256);
    function transactToken(address token, uint256 amount, address recipient) external;
    function transactNative(uint256 amount, address recipient) external payable;
    function ccUpdate(
        BuyOrderUpdate[] calldata buyUpdates,
        SellOrderUpdate[] calldata sellUpdates,
        HistoricalUpdate[] calldata historicalUpdates
    ) external;
    function withdrawToken(address token, uint256 amount, address recipient) external;
}

interface ICCLiquidity {
    struct UpdateType {
        uint8 updateType;
        address token;
        uint256 index;
        uint256 value;
        address addr;
        address recipient;
    }

    function liquidityAmounts(address token) external view returns (uint256);
    function liquidityDetailsView(address token) external view returns (uint256 liquid, uint256 fees, uint256 feesAcc);
    function ccUpdate(address depositor, UpdateType[] memory updates) external;
    function transactToken(address depositor, address token, uint256 amount, address recipient) external;
    function transactNative(address depositor, uint256 amount, address recipient) external;
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract CCLiquidPartial is ReentrancyGuard {
    address internal listingAddress;

    struct OrderContext {
        ICCListing listingContract;
        ICCLiquidity liquidityContract;
        address tokenIn;
        address tokenOut;
        uint8 decimalsIn;
        uint8 decimalsOut;
    }

    struct SwapImpactContext {
        uint256 reserveIn;
        uint256 reserveOut;
        uint8 decimalsIn;
        uint8 decimalsOut;
        uint256 amountInAfterFee;
        uint256 price;
        uint256 amountOut;
    }

    struct FeeContext {
        uint256 feeAmount;
        uint256 netAmount;
        uint256 liquidityAmount;
        uint8 decimals;
    }

    struct OrderProcessingContext {
        uint256 maxPrice;
        uint256 minPrice;
        uint256 currentPrice;
        uint256 impactPrice;
    }

    struct LiquidityUpdateContext {
        uint256 pendingAmount;
        uint256 amountOut;
        bool isBuyOrder;
        address tokenIn;
        address tokenOut;
        uint8 decimalsIn;
        uint8 decimalsOut;
    }

    struct LiquidityValidationContext {
        uint256 normalizedPending;
        uint256 normalizedSettle;
        uint256 liquidIn;
        uint256 liquidOut;
    }

    struct UniswapBalanceContext {
        address outputToken;
        uint256 normalizedUniswapBalance;
        uint256 internalLiquidity;
    }

    event FeeDeducted(address indexed listingAddress, uint256 orderId, bool isBuyOrder, uint256 feeAmount, uint256 netAmount);
    event PriceOutOfBounds(address indexed listingAddress, uint256 orderId, uint256 impactPrice, uint256 maxPrice, uint256 minPrice);
    event TokenTransferFailed(address indexed listingAddress, uint256 orderId, address token, string reason);
    event UpdateFailed(address indexed listingAddress, string reason);
    event InsufficientBalance(address indexed listingAddress, uint256 required, uint256 available);
    event UniswapLiquidityExcess(address indexed listingAddress, uint256 orderId, bool isBuyOrder, uint256 uniswapBalance, uint256 internalLiquidity);
    event NoPendingOrders(address indexed listingAddress, bool isBuyOrder);
    
    mapping(bytes32 => bool) internal processedPairsMap;

    function normalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        else if (decimals < 18) return amount * 10 ** (uint256(18) - uint256(decimals));
        else return amount / 10 ** (uint256(decimals) - uint256(18));
    }

    function denormalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        else if (decimals < 18) return amount / 10 ** (uint256(18) - uint256(decimals));
        else return amount * 10 ** (uint256(decimals) - uint256(18));
    }

    function setListingAddress(address _listingAddress) external onlyOwner {
        require(_listingAddress != address(0), "Invalid listing address");
        listingAddress = _listingAddress;
    }

    function listingAddressView() external view returns (address) {
        return listingAddress;
    }

    function _getTokenDecimals(address token) private view returns (uint8) {
        return token == address(0) ? 18 : IERC20(token).decimals();
    }

    function _getSwapReserves(address tokenIn, address tokenOut, address pairAddress) private view returns (SwapImpactContext memory context) {
        require(pairAddress != address(0), "Uniswap V2 pair not set");
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        address token0 = pair.token0();
        bool isToken0In = tokenIn == token0;
        
        context.reserveIn = tokenIn == address(0) ? address(pairAddress).balance : IERC20(tokenIn).balanceOf(pairAddress);
        context.reserveOut = tokenOut == address(0) ? address(pairAddress).balance : IERC20(tokenOut).balanceOf(pairAddress);
        context.decimalsIn = _getTokenDecimals(tokenIn);
        context.decimalsOut = _getTokenDecimals(tokenOut);
    }

    function _computeCurrentPrice(address tokenA, address tokenB, address pairAddress) private view returns (uint256 price) {
        uint256 balanceA = tokenA == address(0) ? address(pairAddress).balance : IERC20(tokenA).balanceOf(pairAddress);
        uint256 balanceB = tokenB == address(0) ? address(pairAddress).balance : IERC20(tokenB).balanceOf(pairAddress);
        balanceA = normalize(balanceA, _getTokenDecimals(tokenA));
        balanceB = normalize(balanceB, _getTokenDecimals(tokenB));
        return balanceA == 0 ? 0 : (balanceB * 1e18) / balanceA;
    }

    function _computeSwapImpact(address tokenIn, address tokenOut, uint256 amountIn, address pairAddress) private view returns (uint256 price, uint256 amountOut) {
        SwapImpactContext memory context = _getSwapReserves(tokenIn, tokenOut, pairAddress);
        uint256 amountInWithFee = (amountIn * 997) / 1000;
        context.amountInAfterFee = amountInWithFee;
        context.price = context.reserveIn == 0 ? 0 : (context.reserveOut * 1e18) / context.reserveIn;
        amountOut = (context.reserveOut * amountInWithFee) / (context.reserveIn + amountInWithFee);
        price = context.price;
    }

    function _computeFeePercent(uint256 amountIn, uint256 liquidityAmount) private pure returns (uint256 feePercent) {
        uint256 usagePercent = (amountIn * 1e18) / (liquidityAmount == 0 ? 1 : liquidityAmount);
        feePercent = (usagePercent * 5e15) / 1e16;
        if (feePercent < 5e14) feePercent = 5e14;
        if (feePercent > 5e17) feePercent = 5e17;
    }

    function _computeFee(ICCLiquidity liquidityContract, address token, uint256 amountIn) private view returns (FeeContext memory feeContext) {
        uint256 liquidityAmount = liquidityContract.liquidityAmounts(token);
        uint8 decimals = _getTokenDecimals(token);
        uint256 feePercent = _computeFeePercent(amountIn, liquidityAmount);
        feeContext.feeAmount = (amountIn * feePercent) / 1e18;
        feeContext.netAmount = amountIn - feeContext.feeAmount;
        feeContext.decimals = decimals;
        feeContext.liquidityAmount = liquidityAmount;
    }

    function _toSingleUpdateArray(ICCLiquidity.UpdateType memory update) private pure returns (ICCLiquidity.UpdateType[] memory) {
        ICCLiquidity.UpdateType[] memory updates = new ICCLiquidity.UpdateType[](1);
        updates[0] = update;
        return updates;
    }

    function _updateFees(ICCLiquidity liquidityContract, address token, uint256 normalizedFee) private {
        ICCLiquidity.UpdateType memory update = ICCLiquidity.UpdateType({
            updateType: 1,
            token: token,
            index: 0,
            value: normalizedFee,
            addr: address(this),
            recipient: address(0)
        });
        try liquidityContract.ccUpdate(address(this), _toSingleUpdateArray(update)) {} catch Error(string memory reason) {
            revert(string(abi.encodePacked("Fee update failed: ", reason)));
        }
    }

    function _prepareLiquidityUpdates(ICCLiquidity liquidityContract, LiquidityUpdateContext memory context, address pairAddress) private {
        uint256 liquidIn = liquidityContract.liquidityAmounts(context.tokenIn);
        uint256 liquidOut = liquidityContract.liquidityAmounts(context.tokenOut);
        
        uint256 normalizedPending = normalize(context.pendingAmount, context.decimalsIn);
        uint256 normalizedSettle = normalize(context.amountOut, context.decimalsOut);
        
        FeeContext memory feeContext = _computeFee(liquidityContract, context.tokenIn, context.pendingAmount);
        uint256 normalizedFee = normalize(feeContext.feeAmount, context.decimalsIn);

        require(liquidIn >= normalizedPending, "Insufficient input liquidity");
        require(liquidOut >= normalizedSettle, "Insufficient output liquidity");

        ICCLiquidity.UpdateType memory update = ICCLiquidity.UpdateType({
            updateType: 0,
            token: context.tokenIn,
            index: 0,
            value: liquidIn + normalizedPending,
            addr: address(this),
            recipient: address(0)
        });
        try liquidityContract.ccUpdate(address(this), _toSingleUpdateArray(update)) {} catch Error(string memory reason) {
            revert(string(abi.encodePacked("Incoming liquidity update failed: ", reason)));
        }

        update = ICCLiquidity.UpdateType({
            updateType: 0,
            token: context.tokenOut,
            index: 0,
            value: liquidOut - normalizedSettle,
            addr: address(this),
            recipient: address(0)
        });
        try liquidityContract.ccUpdate(address(this), _toSingleUpdateArray(update)) {} catch Error(string memory reason) {
            revert(string(abi.encodePacked("Outgoing liquidity update failed: ", reason)));
        }

        _updateFees(liquidityContract, context.tokenIn, normalizedFee);

        ICCListing listingContract = ICCListing(listingAddress);
        if (context.tokenIn == address(0)) {
            try listingContract.transactNative(context.pendingAmount, address(liquidityContract)) {} catch Error(string memory reason) {
                revert(string(abi.encodePacked("Native transfer failed: ", reason)));
            }
        } else {
            try listingContract.transactToken(context.tokenIn, context.pendingAmount, address(liquidityContract)) {} catch Error(string memory reason) {
                revert(string(abi.encodePacked("Token transfer failed: ", reason)));
            }
        }
    }

    function _createHistoricalUpdate(ICCListing listingContract, ICCLiquidity liquidityContract, address tokenA, address tokenB, address pairAddress) private {
        uint256 xBalance = tokenA == address(0) ? address(pairAddress).balance : IERC20(tokenA).balanceOf(pairAddress);
        uint256 yBalance = tokenB == address(0) ? address(pairAddress).balance : IERC20(tokenB).balanceOf(pairAddress);
        
        uint256 historicalLength = listingContract.historicalDataLengthView(tokenA, tokenB);
        uint256 xVolume = 0;
        uint256 yVolume = 0;
        
        if (historicalLength > 0) {
            ICCListing.HistoricalData memory historicalData = listingContract.getHistoricalDataView(tokenA, tokenB, historicalLength - 1);
            xVolume = historicalData.xVolume;
            yVolume = historicalData.yVolume;
        }
        
        ICCListing.HistoricalUpdate memory update = ICCListing.HistoricalUpdate({
            tokenA: tokenA,
            tokenB: tokenB,
            price: listingContract.prices(tokenA, tokenB),
            xBalance: xBalance,
            yBalance: yBalance,
            xVolume: xVolume,
            yVolume: yVolume,
            timestamp: block.timestamp
        });
        
        ICCListing.BuyOrderUpdate[] memory buyUpdates = new ICCListing.BuyOrderUpdate[](0);
        ICCListing.SellOrderUpdate[] memory sellUpdates = new ICCListing.SellOrderUpdate[](0);
        ICCListing.HistoricalUpdate[] memory historicalUpdates = new ICCListing.HistoricalUpdate[](1);
        historicalUpdates[0] = update;
        
        try listingContract.ccUpdate(buyUpdates, sellUpdates, historicalUpdates) {
        } catch Error(string memory reason) {
            emit UpdateFailed(listingAddress, string(abi.encodePacked("Historical update failed: ", reason)));
        }
    }

    function _executeOrderWithFees(uint256 orderIdentifier, bool isBuyOrder, FeeContext memory feeContext, address tokenIn, address tokenOut, address pairAddress) private returns (bool success) {
        ICCListing listingContract = ICCListing(listingAddress);
        ICCLiquidity liquidityContract = ICCLiquidity(address(this)); // Assuming liquidity is managed here
        
        emit FeeDeducted(listingAddress, orderIdentifier, isBuyOrder, feeContext.feeAmount, feeContext.netAmount);
        
        (, uint256 amountOut) = _computeSwapImpact(tokenIn, tokenOut, feeContext.netAmount, pairAddress);
        
        LiquidityUpdateContext memory liquidityContext = LiquidityUpdateContext({
            pendingAmount: feeContext.netAmount,
            amountOut: amountOut,
            isBuyOrder: isBuyOrder,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            decimalsIn: _getTokenDecimals(tokenIn),
            decimalsOut: _getTokenDecimals(tokenOut)
        });
        
        _prepareLiquidityUpdates(liquidityContract, liquidityContext, pairAddress);
        _createHistoricalUpdate(listingContract, liquidityContract, tokenIn, tokenOut, pairAddress);
        
        success = isBuyOrder ? _executeSingleBuyLiquid(orderIdentifier) : _executeSingleSellLiquid(orderIdentifier);
        require(success, "Order execution failed");
    }

    function _executeSingleBuyLiquid(uint256 orderIdentifier) internal returns (bool success) {
        ICCListing listingContract = ICCListing(listingAddress);
        (address[] memory addresses, , uint256[] memory amounts, uint8 status) = listingContract.getBuyOrder(orderIdentifier);
        
        if (status != 1) return false;
        
        address recipient = addresses.length > 1 ? addresses[1] : addresses[0];
        address tokenOut = addresses.length > 3 ? addresses[3] : address(0);
        uint256 amountOut = amounts.length > 1 ? amounts[1] : 0;
        
        try listingContract.transactToken(tokenOut, amountOut, recipient) {
            ICCListing.BuyOrderUpdate[] memory buyUpdates = new ICCListing.BuyOrderUpdate[](1);
            buyUpdates[0] = ICCListing.BuyOrderUpdate({
                structId: 0,
                orderId: orderIdentifier,
                addresses: addresses,
                prices: new uint256[](0),
                amounts: amounts,
                status: 2
            });
            
            listingContract.ccUpdate(buyUpdates, new ICCListing.SellOrderUpdate[](0), new ICCListing.HistoricalUpdate[](0));
            return true;
        } catch Error(string memory reason) {
            emit TokenTransferFailed(listingAddress, orderIdentifier, tokenOut, reason);
            return false;
        }
    }

    function _executeSingleSellLiquid(uint256 orderIdentifier) internal returns (bool success) {
        ICCListing listingContract = ICCListing(listingAddress);
        (address[] memory addresses, , uint256[] memory amounts, uint8 status) = listingContract.getSellOrder(orderIdentifier);
        
        if (status != 1) return false;
        
        address recipient = addresses.length > 1 ? addresses[1] : addresses[0];
        address tokenOut = addresses.length > 3 ? addresses[3] : address(0);
        uint256 amountOut = amounts.length > 1 ? amounts[1] : 0;
        
        try listingContract.transactToken(tokenOut, amountOut, recipient) {
            ICCListing.SellOrderUpdate[] memory sellUpdates = new ICCListing.SellOrderUpdate[](1);
            sellUpdates[0] = ICCListing.SellOrderUpdate({
                structId: 0,
                orderId: orderIdentifier,
                addresses: addresses,
                prices: new uint256[](0),
                amounts: amounts,
                status: 2
            });
            
            listingContract.ccUpdate(new ICCListing.BuyOrderUpdate[](0), sellUpdates, new ICCListing.HistoricalUpdate[](0));
            return true;
        } catch Error(string memory reason) {
            emit TokenTransferFailed(listingAddress, orderIdentifier, tokenOut, reason);
            return false;
        }
    }

    function _validateLiquidity(ICCLiquidity liquidityContract, address tokenIn, address tokenOut, uint256 pendingAmount, uint256 amountOut) private returns (LiquidityValidationContext memory context) {
        context.liquidIn = liquidityContract.liquidityAmounts(tokenIn);
        context.liquidOut = liquidityContract.liquidityAmounts(tokenOut);
        context.normalizedPending = normalize(pendingAmount, _getTokenDecimals(tokenIn));
        context.normalizedSettle = normalize(amountOut, _getTokenDecimals(tokenOut));

        if (context.liquidIn < context.normalizedPending) {
            emit InsufficientBalance(listingAddress, context.normalizedPending, context.liquidIn);
            return context;
        }
        if (context.liquidOut < context.normalizedSettle) {
            emit InsufficientBalance(listingAddress, context.normalizedSettle, context.liquidOut);
            return context;
        }
    }

    function _checkUniswapBalance(address tokenOut, uint256 orderIdentifier, bool isBuyOrder, address pairAddress, LiquidityValidationContext memory validationContext) private returns (bool valid) {
        UniswapBalanceContext memory context;
        context.outputToken = tokenOut;
        context.normalizedUniswapBalance = tokenOut == address(0) ? address(pairAddress).balance : IERC20(tokenOut).balanceOf(pairAddress);
        context.normalizedUniswapBalance = normalize(context.normalizedUniswapBalance, _getTokenDecimals(tokenOut));
        context.internalLiquidity = validationContext.liquidOut;
        
        if (context.normalizedUniswapBalance > context.internalLiquidity) {
            emit UniswapLiquidityExcess(listingAddress, orderIdentifier, isBuyOrder, context.normalizedUniswapBalance, context.internalLiquidity);
            return false;
        }
        return true;
    }

    function _validateOrderPricing(address tokenA, address tokenB, uint256 pendingAmount, address tokenIn, address tokenOut, address pairAddress) private view returns (OrderProcessingContext memory context) {
        context.currentPrice = _computeCurrentPrice(tokenA, tokenB, pairAddress);
        (, context.impactPrice) = _computeSwapImpact(tokenIn, tokenOut, pendingAmount, pairAddress);
        context.maxPrice = (context.currentPrice * 110) / 100;
        context.minPrice = (context.currentPrice * 90) / 100;
        
        if (context.impactPrice > context.maxPrice || context.impactPrice < context.minPrice || context.impactPrice == 0) {
            context.impactPrice = 0;
        }
    }

    function _processSingleOrder(ICCLiquidity liquidityContract, uint256 orderIdentifier, bool isBuyOrder, uint256 pendingAmount, address tokenIn, address tokenOut, address tokenA, address tokenB, address pairAddress) internal returns (bool success) {
        OrderProcessingContext memory pricingContext = _validateOrderPricing(tokenA, tokenB, pendingAmount, tokenIn, tokenOut, pairAddress);
        
        if (pricingContext.impactPrice == 0) {
            emit PriceOutOfBounds(listingAddress, orderIdentifier, pricingContext.impactPrice, pricingContext.maxPrice, pricingContext.minPrice);
            return false;
        }

        (, uint256 amountOut) = _computeSwapImpact(tokenIn, tokenOut, pendingAmount, pairAddress);
        LiquidityValidationContext memory validationContext = _validateLiquidity(liquidityContract, tokenIn, tokenOut, pendingAmount, amountOut);
        
        if (validationContext.normalizedPending == 0 || validationContext.normalizedSettle == 0) {
            return false;
        }

        if (!_checkUniswapBalance(tokenOut, orderIdentifier, isBuyOrder, pairAddress, validationContext)) {
            return false;
        }

        FeeContext memory feeContext = _computeFee(liquidityContract, tokenIn, pendingAmount);
        return _executeOrderWithFees(orderIdentifier, isBuyOrder, feeContext, tokenIn, tokenOut, pairAddress);
    }
    
//  (0.1.2)
  function _markPairProcessed(address tokenIn, address tokenOut) private {
        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));
        processedPairsMap[pairKey] = true;
    }

    function _isPairProcessed(address tokenIn, address tokenOut) private view returns (bool) {
        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));
        return processedPairsMap[pairKey];
    }

    /// Loads raw order data into a minimal struct (≤4 fields).
    struct OrderLoad {
        address[] addresses;
        uint256[] amounts;
        uint8 status;
    }

    /// Loads a single order from listing contract.
    function _loadOrderContext(
        ICCListing listingContract,
        uint256 orderId,
        bool isBuyOrder
    ) private view returns (OrderLoad memory load) {
        if (isBuyOrder) {
            (load.addresses, , load.amounts, load.status) = listingContract.getBuyOrder(orderId);
        } else {
            (load.addresses, , load.amounts, load.status) = listingContract.getSellOrder(orderId);
        }
    }

    /// Validates order structure and extracts tokenIn/tokenOut/pendingAmount.
    struct OrderExtract {
        address tokenIn;
        address tokenOut;
        uint256 pendingAmount;
    }

    function _extractOrderTokens(
        OrderLoad memory load
    ) private pure returns (OrderExtract memory extract) {
        if (load.addresses.length < 4) return extract; // zero values → skip
        extract.pendingAmount = load.amounts.length > 0 ? load.amounts[0] : 0;
        if (extract.pendingAmount == 0) return extract;
        extract.tokenIn = load.addresses[2];   // startToken
        extract.tokenOut = load.addresses[3];  // endToken
    }

    /// Validates pair existence and output liquidity.
    struct PairValidation {
        address pairAddress;
        uint256 liquidOut;
    }

    function _validatePairAndLiquidity(
        address factory,
        address tokenIn,
        address tokenOut,
        ICCLiquidity liquidityContract
    ) private returns (PairValidation memory validation) {
        validation.pairAddress = IUniswapV2Factory(factory).getPair(tokenIn, tokenOut);
        if (validation.pairAddress == address(0)) {
            emit UpdateFailed(listingAddress, "Pair not found");
            return validation;
        }
        validation.liquidOut = liquidityContract.liquidityAmounts(tokenOut);
        if (validation.liquidOut == 0) {
            emit InsufficientBalance(listingAddress, 1, validation.liquidOut);
        }
    }

    /// Handles historical update once per unique pair in the batch.
    function _handleHistoricalOnce(
        ICCListing listingContract,
        ICCLiquidity liquidityContract,
        address tokenIn,
        address tokenOut,
        address pairAddress
    ) private {
        if (!_isPairProcessed(tokenIn, tokenOut)) {
            _createHistoricalUpdate(listingContract, liquidityContract, tokenIn, tokenOut, pairAddress);
            _markPairProcessed(tokenIn, tokenOut);
        }
    }

    function _processOrderBatch(ICCLiquidity liquidityContract, bool isBuyOrder, uint256 step) internal returns (bool success) {
        ICCListing listingContract = ICCListing(listingAddress);
        uint256[] memory orderIdentifiers = listingContract.makerPendingOrdersView(msg.sender);
        
        if (orderIdentifiers.length == 0 || step >= orderIdentifiers.length) {
            return false;
        }

        address factory = listingContract.uniswapV2Factory();
        require(factory != address(0), "Factory not set");
        
        for (uint256 i = step; i < orderIdentifiers.length; i++) {
            // 1. Load order
            OrderLoad memory load = _loadOrderContext(listingContract, orderIdentifiers[i], isBuyOrder);
            if (load.status != 1) continue; // only pending orders

            // 2. Extract tokens & amount
            OrderExtract memory extract = _extractOrderTokens(load);
            if (extract.pendingAmount == 0) continue;

            // 3. Validate pair & liquidity
            PairValidation memory validation = _validatePairAndLiquidity(
                factory,
                extract.tokenIn,
                extract.tokenOut,
                liquidityContract
            );
            if (validation.pairAddress == address(0) || validation.liquidOut == 0) continue;

            // 4. Historical update (once per pair)
            _handleHistoricalOnce(
                listingContract,
                liquidityContract,
                extract.tokenIn,
                extract.tokenOut,
                validation.pairAddress
            );

            // 5. Execute single order
            if (_processSingleOrder(
                liquidityContract,
                orderIdentifiers[i],
                isBuyOrder,
                extract.pendingAmount,
                extract.tokenIn,
                extract.tokenOut,
                extract.tokenIn,
                extract.tokenOut,
                validation.pairAddress
            )) {
                success = true;
            }
        }
    }
}
