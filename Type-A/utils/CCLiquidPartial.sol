// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.1.7 (04/12/2025)
// Changes: 
// - v0.1.7 (04)12): Fixed impact price direction. 
// - v0.1.6 (02/12): Fixed _executeSingleBuyLiquid and _executeSingleSellLiquid to withdraw from LIQUIDITY template
// - Added liquidity update to deduct the settled amount from liquids
// v0.1.5 (02/12): Fixed interface and calls, no longer using transactToken, instead withdrawToken. 
// - v0.1.4 (02/12): Used correct liquidity template address, not address(this). 
// - 01/12/2025: Added correct impact price restriction. 
// - 30/11/2025: Resolved stack too deep in _executeSingleBuyLiquid and _executeSingleSellLiquid
// - 30/11/2025: Fixed double-normalization in liquidity validation and updates.
// - Added support for partially filled orders (status 2).
// - Implemented split updates (StructID 2 & 0) to prevent overwriting.
// - Corrected state calculation for pending/filled/sent amounts.

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
    function withdrawToken(address token, uint256 amount, address recipient) external;
    function ccUpdate(
        BuyOrderUpdate[] calldata buyUpdates,
        SellOrderUpdate[] calldata sellUpdates,
        HistoricalUpdate[] calldata historicalUpdates
    ) external;
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
    function withdrawToken(address token, uint256 amount, address recipient) external;
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract CCLiquidPartial is ReentrancyGuard {
    address internal listingAddress;
    
    // --- Structs for Calculation & Stack Management ---

    struct ExecutionState {
        uint256 orderId;
        address[] addresses;
        uint256[] amounts;
        uint8 currentStatus;
        uint256 amountIn;  // Normalized
        uint256 amountOut; // Normalized
        uint256 newPending;
        uint256 newFilled;
        uint256 newSent;
        uint8 newStatus;
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

    struct OrderLoad {
        address[] addresses;
        uint256[] amounts;
        uint8 status;
    }

    struct OrderExtract {
        address tokenIn;
        address tokenOut;
        uint256 pendingAmount;
    }

    struct PairValidation {
        address pairAddress;
        uint256 liquidOut;
    }
    
    struct OrderValidationContext {
    uint256 orderIdentifier;
    bool isBuyOrder;
    address tokenIn;
    address tokenOut;
    address pairAddress;
    uint256 normalizedPending;
}

struct OrderExecutionContext {
    uint256 orderIdentifier;
    bool isBuyOrder;
    address tokenIn;
    address tokenOut;
    address pairAddress;
    uint256 normalizedPending;
    uint256 amountOut;
}

    event FeeDeducted(address indexed listingAddress, uint256 orderId, bool isBuyOrder, uint256 feeAmount, uint256 netAmount);
    event PriceOutOfBounds(address indexed listingAddress, uint256 orderId, uint256 impactPrice, uint256 maxPrice, uint256 minPrice);
    event TokenTransferFailed(address indexed listingAddress, uint256 orderId, address token, string reason);
    event UpdateFailed(address indexed listingAddress, string reason);
    event InsufficientBalance(address indexed listingAddress, uint256 required, uint256 available);
    event UniswapLiquidityExcess(address indexed listingAddress, uint256 orderId, bool isBuyOrder, uint256 uniswapBalance, uint256 internalLiquidity);
    event NoPendingOrders(address indexed listingAddress, bool isBuyOrder);
    
    mapping(bytes32 => bool) internal processedPairsMap;
    
// Liquidity variable 
address internal liquidityAddress;

// Liquidity  setter (owner-only)
function setLiquidityAddress(address _liquidityAddress) external onlyOwner {
    require(_liquidityAddress != address(0), "Invalid liquidity address");
    liquidityAddress = _liquidityAddress;
}

function liquidityAddressView() external view returns (address) {
        return liquidityAddress;
    }

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

    // Standard swap output calculation for execution
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
    
    uint256 normalizedPending = context.pendingAmount;
    uint256 normalizedSettle = context.amountOut;
    FeeContext memory feeContext = _computeFee(liquidityContract, context.tokenIn, context.pendingAmount);
    uint256 normalizedFee = feeContext.feeAmount; 

    require(liquidIn >= normalizedPending, "Insufficient input liquidity");
    require(liquidOut >= normalizedSettle, "Insufficient output liquidity");

    // Update incoming liquidity (add)
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

    // Update outgoing liquidity (subtract)
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

    // Update fees
    _updateFees(liquidityContract, context.tokenIn, normalizedFee);

    // **FIX: Transfer from Listing -> Liquidity using withdrawToken**
    ICCListing listingContract = ICCListing(listingAddress);
    uint256 denormPending = denormalize(context.pendingAmount, context.decimalsIn);
    
    // Use listing's withdrawToken to transfer to liquidity template
    try listingContract.withdrawToken(context.tokenIn, denormPending, address(liquidityContract)) {} catch Error(string memory reason) {
        revert(string(abi.encodePacked("Transfer from listing to liquidity failed: ", reason)));
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
        
        try listingContract.ccUpdate(
            new ICCListing.BuyOrderUpdate[](0), 
            new ICCListing.SellOrderUpdate[](0), 
            _toHistoricalArray(update)
        ) {
        } catch Error(string memory reason) {
            emit UpdateFailed(listingAddress, string(abi.encodePacked("Historical update failed: ", reason)));
        }
    }

    function _toHistoricalArray(ICCListing.HistoricalUpdate memory update) private pure returns (ICCListing.HistoricalUpdate[] memory) {
        ICCListing.HistoricalUpdate[] memory updates = new ICCListing.HistoricalUpdate[](1);
        updates[0] = update;
        return updates;
    }

    function _executeOrderWithFees(uint256 orderIdentifier, bool isBuyOrder, FeeContext memory feeContext, address tokenIn, address tokenOut, address pairAddress) private returns (bool success) {
        ICCListing listingContract = ICCListing(listingAddress);
        ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress);
        
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
        
        if (isBuyOrder) {
            success = _executeSingleBuyLiquid(orderIdentifier, feeContext.netAmount, amountOut, liquidityContext.decimalsOut);
        } else {
            success = _executeSingleSellLiquid(orderIdentifier, feeContext.netAmount, amountOut, liquidityContext.decimalsOut);
        }
        require(success, "Order execution failed");
    }

    // --- HELPER: Calculate New State (Pending, Filled, Sent) ---
    function _calculateNewState(ExecutionState memory state) private pure {
        state.newPending = state.amounts[0] > state.amountIn ? state.amounts[0] - state.amountIn : 0;
        state.newFilled = state.amounts[1] + state.amountIn;
        state.newSent = state.amounts[2] + state.amountOut;
        state.newStatus = state.newPending == 0 ? 3 : 2;
    }

    // --- HELPER: Create Buy Updates ---
    function _createBuyUpdates(ExecutionState memory state) private pure returns (ICCListing.BuyOrderUpdate[] memory updates) {
        updates = new ICCListing.BuyOrderUpdate[](2);
        
        updates[0] = ICCListing.BuyOrderUpdate({
            structId: 2,
            orderId: state.orderId,
            addresses: state.addresses,
            prices: new uint256[](0),
            amounts: new uint256[](3),
            status: 0
        });
        updates[0].amounts[0] = state.newPending;
        updates[0].amounts[1] = state.newFilled;
        updates[0].amounts[2] = state.newSent;

        updates[1] = ICCListing.BuyOrderUpdate({
            structId: 0,
            orderId: state.orderId,
            addresses: state.addresses,
            prices: new uint256[](0),
            amounts: new uint256[](0),
            status: state.newStatus
        });
    }

    // --- HELPER: Create Sell Updates ---
    function _createSellUpdates(ExecutionState memory state) private pure returns (ICCListing.SellOrderUpdate[] memory updates) {
        updates = new ICCListing.SellOrderUpdate[](2);
        
        updates[0] = ICCListing.SellOrderUpdate({
            structId: 2,
            orderId: state.orderId,
            addresses: state.addresses,
            prices: new uint256[](0),
            amounts: new uint256[](3),
            status: 0
        });
        updates[0].amounts[0] = state.newPending;
        updates[0].amounts[1] = state.newFilled;
        updates[0].amounts[2] = state.newSent;

        updates[1] = ICCListing.SellOrderUpdate({
            structId: 0,
            orderId: state.orderId,
            addresses: state.addresses,
            prices: new uint256[](0),
            amounts: new uint256[](0),
            status: state.newStatus
        });
    }

// --- FIXED (0.1.6): Buy Order Settlement ---
function _executeSingleBuyLiquid(
    uint256 orderIdentifier, 
    uint256 amountIn, 
    uint256 amountOut,
    uint8 decimalsOut
) internal returns (bool success) {
    ICCListing listingContract = ICCListing(listingAddress);
    ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress);
    
    ExecutionState memory state;
    state.orderId = orderIdentifier;
    state.amountIn = amountIn;
    state.amountOut = amountOut;

    (state.addresses, , state.amounts, state.currentStatus) = listingContract.getBuyOrder(orderIdentifier);
    if (state.currentStatus != 1 && state.currentStatus != 2) return false;
    
    address recipient = state.addresses.length > 1 ? state.addresses[1] : state.addresses[0];
    address tokenOut = state.addresses.length > 3 ? state.addresses[3] : address(0);
    uint256 denormAmountOut = denormalize(amountOut, decimalsOut);

    // FIX: Withdraw from LIQUIDITY template, not listing
    try liquidityContract.withdrawToken(tokenOut, denormAmountOut, recipient) {
        // FIX: Update liquidity to deduct settled amount
        uint256 currentLiquid = liquidityContract.liquidityAmounts(tokenOut);
        require(currentLiquid >= amountOut, "Insufficient liquidity for settlement");
        
        ICCLiquidity.UpdateType memory liquidUpdate = ICCLiquidity.UpdateType({
            updateType: 0,
            token: tokenOut,
            index: 0,
            value: currentLiquid - amountOut, // Deduct settled amount
            addr: address(this),
            recipient: address(0)
        });
        
        try liquidityContract.ccUpdate(address(this), _toSingleUpdateArray(liquidUpdate)) {
            // Update order state
            _calculateNewState(state);
            ICCListing.BuyOrderUpdate[] memory updates = _createBuyUpdates(state);
            
            listingContract.ccUpdate(updates, new ICCListing.SellOrderUpdate[](0), new ICCListing.HistoricalUpdate[](0));
            return true;
        } catch Error(string memory reason) {
            emit UpdateFailed(listingAddress, string(abi.encodePacked("Liquidity update failed: ", reason)));
            return false;
        }
    } catch Error(string memory reason) {
        emit TokenTransferFailed(listingAddress, orderIdentifier, tokenOut, reason);
        return false;
    }
}

// --- FIXED (0.1.6): Sell Order Settlement ---
function _executeSingleSellLiquid(
    uint256 orderIdentifier, 
    uint256 amountIn, 
    uint256 amountOut,
    uint8 decimalsOut
) internal returns (bool success) {
    ICCListing listingContract = ICCListing(listingAddress);
    ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress);
    
    ExecutionState memory state;
    state.orderId = orderIdentifier;
    state.amountIn = amountIn;
    state.amountOut = amountOut;

    (state.addresses, , state.amounts, state.currentStatus) = listingContract.getSellOrder(orderIdentifier);
    if (state.currentStatus != 1 && state.currentStatus != 2) return false;

    address recipient = state.addresses.length > 1 ? state.addresses[1] : state.addresses[0];
    address tokenOut = state.addresses.length > 3 ? state.addresses[3] : address(0);
    uint256 denormAmountOut = denormalize(amountOut, decimalsOut);

    // FIX: Withdraw from LIQUIDITY template, not listing
    try liquidityContract.withdrawToken(tokenOut, denormAmountOut, recipient) {
        // FIX: Update liquidity to deduct settled amount
        uint256 currentLiquid = liquidityContract.liquidityAmounts(tokenOut);
        require(currentLiquid >= amountOut, "Insufficient liquidity for settlement");
        
        ICCLiquidity.UpdateType memory liquidUpdate = ICCLiquidity.UpdateType({
            updateType: 0,
            token: tokenOut,
            index: 0,
            value: currentLiquid - amountOut, // Deduct settled amount
            addr: address(this),
            recipient: address(0)
        });
        
        try liquidityContract.ccUpdate(address(this), _toSingleUpdateArray(liquidUpdate)) {
            // Update order state
            _calculateNewState(state);
            ICCListing.SellOrderUpdate[] memory updates = _createSellUpdates(state);

            listingContract.ccUpdate(new ICCListing.BuyOrderUpdate[](0), updates, new ICCListing.HistoricalUpdate[](0));
            return true;
        } catch Error(string memory reason) {
            emit UpdateFailed(listingAddress, string(abi.encodePacked("Liquidity update failed: ", reason)));
            return false;
        }
    } catch Error(string memory reason) {
        emit TokenTransferFailed(listingAddress, orderIdentifier, tokenOut, reason);
        return false;
    }
}

    function _validateLiquidity(ICCLiquidity liquidityContract, address tokenIn, address tokenOut, uint256 pendingAmount, uint256 amountOut) private returns (LiquidityValidationContext memory context) {
        context.liquidIn = liquidityContract.liquidityAmounts(tokenIn);
        context.liquidOut = liquidityContract.liquidityAmounts(tokenOut);
        context.normalizedPending = pendingAmount;
        context.normalizedSettle = amountOut;

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

// --- FIXED(0.1.7): Calculate Impact Price ---
// --- FIXED: Calculate Impact Price (Follows Exact Formula) ---
function _calculateImpactPrice(
    address tokenA, 
    address tokenB, 
    address pairAddress, 
    uint256 amountIn,  // NORMALIZED (1e18)
    bool isBuyOrder
) private view returns (uint256) {
    // Load reserves (normalized to 1e18)
    uint256 rA = normalize(
        tokenA == address(0) ? address(pairAddress).balance : IERC20(tokenA).balanceOf(pairAddress),
        _getTokenDecimals(tokenA)
    );
    uint256 rB = normalize(
        tokenB == address(0) ? address(pairAddress).balance : IERC20(tokenB).balanceOf(pairAddress),
        _getTokenDecimals(tokenB)
    );
    
    if (rA == 0 || rB == 0) return 0;
    
    // Get current price using prices(tokenA, tokenB) - NEVER flip tokens
    ICCListing listingContract = ICCListing(listingAddress);
    uint256 currentPrice = listingContract.prices(tokenA, tokenB); // Returns tokenB/tokenA
    
    if (currentPrice == 0) return 0;
    
    uint256 impactResA;
    uint256 impactResB;
    
    if (isBuyOrder) {
        // Buy: Input TokenB -> Output TokenA
        // Formula:
        // [TokenB] swap amount / current price = [TokenA] output
        // [TokenA] Liquidity - [TokenA] output = [TokenA] impact
        // [TokenB] Liquidity + [TokenB] swap amount = [TokenB] impact
        // Impact Price = [TokenB] impact / [TokenA] impact
        
        uint256 estimatedOutA = (amountIn * 1e18) / currentPrice; // amountIn is TokenB
        impactResA = rA > estimatedOutA ? rA - estimatedOutA : 1;
        impactResB = rB + amountIn;
        
    } else {
        // Sell: Input TokenA -> Output TokenB
        // Formula:
        // [TokenA] swap amount * price = [TokenB] output
        // [TokenB] Liquidity - [TokenB] output = [TokenB] impact
        // [TokenA] Liquidity + [TokenA] swap amount = [TokenA] impact
        // Impact Price = [TokenB] impact / [TokenA] impact
        
        uint256 estimatedOutB = (amountIn * currentPrice) / 1e18; // amountIn is TokenA
        impactResB = rB > estimatedOutB ? rB - estimatedOutB : 1;
        impactResA = rA + amountIn;
    }
    
    // Impact Price = ImpactResB / ImpactResA
    return (impactResB * 1e18) / impactResA;
}

// --- UPDATED (0.1.7): Validate against Order Constraints ---
function _validateOrderPricing(
    uint256 orderId,
    ICCListing listingContract,
    address tokenA, 
    address tokenB, 
    uint256 amountIn,  // NOW RECEIVES NORMALIZED AMOUNT
    bool isBuyOrder, 
    address pairAddress
) private view returns (bool) {
    // 1. Calculate Impact Price (now expects normalized input)
    uint256 impactPrice = _calculateImpactPrice(tokenA, tokenB, pairAddress, amountIn, isBuyOrder);
    
    if (impactPrice == 0) {
        return false;
    }

    // 2. Load Order Limits
    uint256[] memory prices;
    if (isBuyOrder) {
        (, prices, , ) = listingContract.getBuyOrder(orderId);
    } else {
        (, prices, , ) = listingContract.getSellOrder(orderId);
    }

    // 3. Verify Bounds (maxPrice = prices[0], minPrice = prices[1])
    if (impactPrice > prices[0] || impactPrice < prices[1]) {
        return false;
    }

    return true;
}

// (0.1.7)
    function _processSingleOrder(
    ICCLiquidity liquidityContract, 
    uint256 orderIdentifier, 
    bool isBuyOrder, 
    uint256 pendingAmount,
    address tokenIn, 
    address tokenOut, 
    address tokenA, 
    address tokenB, 
    address pairAddress
) internal returns (bool success) {
    // Step 1: Normalize and validate pricing
    OrderValidationContext memory ctx = OrderValidationContext({
        orderIdentifier: orderIdentifier,
        isBuyOrder: isBuyOrder,
        tokenIn: tokenIn,
        tokenOut: tokenOut,
        pairAddress: pairAddress,
        normalizedPending: normalize(pendingAmount, _getTokenDecimals(tokenIn))
    });
    
    if (!_validatePricingStep(ctx, tokenA, tokenB)) {
        return false;
    }
    
    // Step 2: Execute order
    return _executeOrderStep(liquidityContract, ctx);
}

function _validatePricingStep(
    OrderValidationContext memory ctx,
    address tokenA,
    address tokenB
) private returns (bool) {
    ICCListing listingContract = ICCListing(listingAddress);
    
    if (!_validateOrderPricing(
        ctx.orderIdentifier,
        listingContract,
        tokenA,
        tokenB,
        ctx.normalizedPending,
        ctx.isBuyOrder,
        ctx.pairAddress
    )) {
        emit PriceOutOfBounds(listingAddress, ctx.orderIdentifier, 0, 0, 0);
        return false;
    }
    
    return true;
}

function _executeOrderStep(
    ICCLiquidity liquidityContract,
    OrderValidationContext memory ctx
) private returns (bool) {
    // Compute swap output
    (, uint256 amountOut) = _computeSwapImpact(
        ctx.tokenIn,
        ctx.tokenOut,
        ctx.normalizedPending,
        ctx.pairAddress
    );
    
    // Validate liquidity
    LiquidityValidationContext memory validationContext = _validateLiquidity(
        liquidityContract,
        ctx.tokenIn,
        ctx.tokenOut,
        ctx.normalizedPending,
        amountOut
    );
    
    if (validationContext.normalizedPending == 0 || validationContext.normalizedSettle == 0) {
        return false;
    }
    
    if (!_checkUniswapBalance(
        ctx.tokenOut,
        ctx.orderIdentifier,
        ctx.isBuyOrder,
        ctx.pairAddress,
        validationContext
    )) {
        return false;
    }
    
    // Execute with fees
    FeeContext memory feeContext = _computeFee(
        liquidityContract,
        ctx.tokenIn,
        ctx.normalizedPending
    );
    
    return _executeOrderWithFees(
        ctx.orderIdentifier,
        ctx.isBuyOrder,
        feeContext,
        ctx.tokenIn,
        ctx.tokenOut,
        ctx.pairAddress
    );
}
    
    function _markPairProcessed(address tokenIn, address tokenOut) private {
        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));
        processedPairsMap[pairKey] = true;
    }

    function _isPairProcessed(address tokenIn, address tokenOut) private view returns (bool) {
        bytes32 pairKey = keccak256(abi.encodePacked(tokenIn, tokenOut));
        return processedPairsMap[pairKey];
    }

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

    function _extractOrderTokens(
        OrderLoad memory load
    ) private pure returns (OrderExtract memory extract) {
        if (load.addresses.length < 4) return extract;
        extract.pendingAmount = load.amounts.length > 0 ? load.amounts[0] : 0;
        if (extract.pendingAmount == 0) return extract;
        extract.tokenIn = load.addresses[2]; 
        extract.tokenOut = load.addresses[3]; 
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
            OrderLoad memory load = _loadOrderContext(listingContract, orderIdentifiers[i], isBuyOrder);
            
            if (load.status != 1 && load.status != 2) continue;

            OrderExtract memory extract = _extractOrderTokens(load);
            if (extract.pendingAmount == 0) continue;

            PairValidation memory validation = _validatePairAndLiquidity(
                factory,
                extract.tokenIn,
                extract.tokenOut,
                liquidityContract
            );
            if (validation.pairAddress == address(0) || validation.liquidOut == 0) continue;

            _handleHistoricalOnce(
                listingContract,
                liquidityContract,
                extract.tokenIn,
                extract.tokenOut,
                validation.pairAddress
            );

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