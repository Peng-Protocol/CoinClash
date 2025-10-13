# CCLiquidRouter Contract Documentation

## Overview
The `CCLiquidRouter` contract (Solidity ^0.8.2) settles buy/sell orders using `ICCLiquidity`, inheriting `CCLiquidPartial` (v0.0.51). It integrates with `ICCListing`, `ICCLiquidity`, `IERC20`, and `IUniswapV2Pair`. Features a fee system (0.05% min at ≤1% liquidity usage, scaling to 0.10% at 2%, 0.50% at 10%, 50% max at 100%), user-specific settlement via `makerPendingOrdersView`, and gas-efficient iteration with `step`. Uses `ReentrancyGuard`. Fees are deducted from `pendingAmount`, recorded in `xFees`/`yFees`. Liquidity updates: buy orders increase `yLiquid` by `pendingAmount`, decrease `xLiquid` by `amountOut`; sell orders increase `xLiquid`, decrease `yLiquid`. Historical updates capture pre-settlement snapshots. Validates Uniswap V2 pair balances.

**SPDX License:** BSL 1.1 - Peng Protocol 2025

**Version:** 0.0.51 (updated 2025-10-13)

**Inheritance Tree:** `CCLiquidRouter` → `CCLiquidPartial` (v0.0.51) → `CCMainPartial` (v0.1.5)

**Compatibility:** `CCListingTemplate.sol` (v0.3.9), `ICCLiquidity.sol` (v0.0.5), `CCMainPartial.sol` (v0.1.5), `CCLiquidPartial.sol` (v0.0.51), `CCLiquidityTemplate.sol` (v0.1.20)

## Mappings
- None in `CCLiquidRouter`. Uses `ICCListing` view functions (`pendingBuyOrdersView`, `pendingSellOrdersView`, `makerPendingOrdersView`) for order tracking.

## Structs
- **HistoricalUpdateContext** (`CCLiquidRouter`): Stores `xBalance`, `yBalance`, `xVolume`, `yVolume` (uint256).
- **OrderContext** (`CCLiquidPartial`): Holds `listingContract` (ICCListing), `tokenIn`, `tokenOut` (address).
- **PrepOrderUpdateResult** (`CCLiquidPartial`): Includes `makerAddress`, `recipientAddress` (address), `status` (uint8), `amountReceived`, `normalizedReceived`, `amountSent`, `preTransferWithdrawn` (uint256).
- **BuyOrderUpdateContext** (`CCLiquidPartial`): Holds `makerAddress`, `recipient` (address), `status` (uint8), `amountReceived`, `normalizedReceived`, `amountSent`, `preTransferWithdrawn` (uint256).
- **SellOrderUpdateContext** (`CCLiquidPartial`): Mirrors `BuyOrderUpdateContext`.
- **OrderBatchContext** (`CCLiquidPartial`): Stores `listingAddress` (address), `isBuyOrder` (bool).
- **SwapImpactContext** (`CCLiquidPartial`): Holds `reserveIn`, `reserveOut`, `amountInAfterFee`, `price`, `amountOut` (uint256), `decimalsIn`, `decimalsOut` (uint8).
- **FeeContext** (`CCLiquidPartial`): Includes `feeAmount`, `netAmount`, `liquidityAmount` (uint256), `decimals` (uint8).
- **OrderProcessingContext** (`CCLiquidPartial`): Holds `maxPrice`, `minPrice`, `currentPrice`, `impactPrice` (uint256).
- **LiquidityUpdateContext** (`CCLiquidPartial`): Includes `pendingAmount`, `amountOut` (uint256), `isBuyOrder` (bool).
- **FeeCalculationContext** (`CCLiquidPartial`): Stores `outputLiquidityAmount`, `normalizedAmountSent`, `normalizedLiquidity` (uint256), `outputDecimals` (uint8).
- **LiquidityValidationContext** (`CCLiquidPartial`): Holds `normalizedPending`, `normalizedSettle`, `xLiquid`, `yLiquid` (uint256).
- **UniswapBalanceContext** (`CCLiquidPartial`): Stores `outputToken` (address), `normalizedUniswapBalance`, `internalLiquidity` (uint256).

## Formulas
Formulas in `CCLiquidPartial.sol` (v0.0.51) ensure 18-decimal precision.

1. **Current Price**:
   - **Formula**: `price = (normalize(balanceB, decimalsB) * 1e18) / normalize(balanceA, decimalsA)`.
   - **Used in**: `_computeCurrentPrice`, `_validateOrderPricing`, `_processSingleOrder`, `_createHistoricalUpdate`, `_executeOrderWithFees`.
   - **Description**: Calculates price from Uniswap V2 reserves, validated within 10% slippage.
   - **Usage**: Triggers in `settleBuy/SellLiquid` → `_processOrderBatch` → `_processSingleOrder` → `_validateOrderPricing`.

2. **Swap Impact**:
   - **Formula**:
     - `amountInAfterFee = (inputAmount * 997) / 1000`.
     - `normalizedReserveIn/Out = normalize(reserveIn/Out, decimalsIn/Out)`.
     - `amountOut = (amountInAfterFee * normalizedReserveOut) / (normalizedReserveIn + amountInAfterFee)`.
     - `impactPrice = (normalizedReserveOut * 1e18) / normalizedReserveIn`.
   - **Used in**: `_computeSwapImpact`, `_validateOrderPricing`, `_computeSwapAmount`, `_prepBuy/SellOrderUpdate`.
   - **Description**: Simulates Uniswap V2 swap output and price impact.
   - **Usage**: Emits `PriceOutOfBounds` if invalid; used for liquidity checks.

3. **Fee Calculation**:
   - **Formula**:
     - `usagePercent = (amountIn * 1e18) / liquidityAmount`.
     - `feePercent = (usagePercent * 5e15) / 1e16` (0.05% per 1% usage).
     - `feePercent = max(5e14, min(5e17, feePercent))`.
     - `feeAmount = (amountIn * feePercent) / 1e18`, `netAmount = amountIn - feeAmount`.
   - **Used in**: `_computeFee` → `_getLiquidityData`, `_computeFeePercent`, `_finalizeFee`.
   - **Description**: Scales fees linearly (0.05% at ≤1%, 0.10% at 2%, 0.50% at 10%, 50% at 100%).
   - **Usage**: Emits `FeeDeducted` in `_executeOrderWithFees`.

4. **Buy Order Output**:
   - **Formula**: `amountOut (tokenA) ≈ netAmount (tokenB) / impactPrice`, denormalized.
   - **Used in**: `_computeSwapImpact`, `_prepBuyOrderUpdate`, `_processSingleOrder`, `executeSingleBuyLiquid`.
   - **Description**: Projects tokenA output; validates `xLiquid >= normalize(amountOut)`.

5. **Sell Order Output**:
   - **Formula**: `amountOut (tokenB) ≈ netAmount (tokenA) * impactPrice`, denormalized.
   - **Used in**: `_computeSwapImpact`, `_prepSellOrderUpdate`, `_processSingleOrder`, `executeSingleSellLiquid`.
   - **Description**: Projects tokenB output; validates `yLiquid >= normalize(amountOut)`.

6. **Normalization/Denormalization**:
   - **Normalize**: `normalize(amount, decimals) = decimals < 18 ? amount * 10^(18-decimals) : amount / 10^(decimals-18)`.
   - **Denormalize**: `denormalize(amount, decimals) = decimals < 18 ? amount / 10^(18-decimals) : amount * 10^(decimals-18)`.
   - **Used in**: `_computeSwapImpact`, `_computeCurrentPrice`, `_validateLiquidity`, `_checkUniswapBalance`, `_prepBuy/SellOrderUpdate`, `_computeFee`.

## External Functions
### settleBuyLiquid(address listingAddress, uint256 step)
- **Parameters**:
  - `listingAddress`: Address of `ICCListing` contract.
  - `step`: Starting index in `makerPendingOrdersView`.
- **Behavior**: Settles buy orders for `msg.sender`. Validates listing, checks `xBalance` via `volumeBalances(0)`, emits `InsufficientBalance` if zero. Calls `_createHistoricalUpdate` if orders exist, then `_processOrderBatch`. Emits `NoPendingOrders` or `UpdateFailed` as needed.
- **External Call Tree**:
  - `ICCListing.volumeBalances(0)`: Checks `xBalance`, `yBalance`.
  - `ICCListing.makerPendingOrdersView(msg.sender)`: Fetches order IDs.
  - `ICCListing.ccUpdate`: Updates historical data via `_createHistoricalUpdate`, `_executeOrderWithFees`.
  - `ICCListing.getBuyOrderAmounts/Pricing`: Validates amounts and pricing in `_processSingleOrder`.
  - `IUniswapV2Pair.balanceOf`, `ICCListing.tokenA/B`, `decimalsA/B`: Fetches reserves in `_getSwapReserves`, `_checkUniswapBalance`.
  - `ICCLiquidity.liquidityAmounts`: Validates `xLiquid`, `yLiquid` in `_validateLiquidity`.
  - `ICCLiquidity.ccUpdate`, `ICCListing.transactToken/Native`: Updates liquidity and transfers in `_prepareLiquidityUpdates`.
- **Emits**: `NoPendingOrders`, `InsufficientBalance`, `UpdateFailed`, `PriceOutOfBounds`, `UniswapLiquidityExcess`, `FeeDeducted`, `TokenTransferFailed`.
- **Graceful Degradation**: Skips invalid orders; returns `false` on non-critical errors.

### settleSellLiquid(address listingAddress, uint256 step)
- **Parameters**: Same as `settleBuyLiquid`.
- **Behavior**: Settles sell orders, validates `yBalance`. Mirrors buy logic with `SellOrderUpdate[]`.
- **External Call Tree**: Similar to `settleBuyLiquid`, using sell-specific functions.
- **Emits**: Same as `settleBuyLiquid`, sell-specific.
- **Graceful Degradation**: Identical.

## Internal Functions (CCLiquidRouter)
- **_createHistoricalUpdate**: Creates `HistoricalUpdate` with `volumeBalances(0)`, `prices(0)`, `xVolume`, `yVolume`. Calls `ICCListing.ccUpdate`. Triggered by `settleBuy/SellLiquid`.

## Internal Functions (CCLiquidPartial, v0.0.51)
- **_validateOrderPricing**: Validates price within 10% slippage; emits `PriceOutOfBounds`. Called by `_processSingleOrder`.
- **_validateLiquidity**: Checks `xLiquid`/`yLiquid`; emits `InsufficientBalance`. Called by `_processSingleOrder`.
- **_checkUniswapBalance**: Ensures Uniswap balance ≤ `xLiquid`/`yLiquid`; emits `UniswapLiquidityExcess`. Called by `_processSingleOrder`.
- **_executeOrder**: Calls `_executeOrderWithFees`. Called by `_processSingleOrder`.
- **_computeAmountSent**: Captures pre-transfer balance. Called by `_prepBuy/SellOrderUpdate`.
- **_updateFees**: Updates `xFees`/`yFees` via `ccUpdate`. Called by `_executeOrderWithFees`.
- **_prepBuyOrderUpdate**: Prepares buy order data; computes `amountSent`. Called by `executeSingleBuyLiquid`.
- **_prepSellOrderUpdate**: Prepares sell order data. Called by `executeSingleSellLiquid`.
- **_getSwapReserves**: Fetches Uniswap pair reserves. Called by `_computeSwapImpact`.
- **_computeCurrentPrice**: Calculates price from reserves. Called by `_validateOrderPricing`.
- **_computeSwapImpact**: Calculates `amountOut`, `impactPrice`. Called by `_validateOrderPricing`, `_computeSwapAmount`.
- **_getTokenAndDecimals**: Retrieves token/decimals. Called by `_computeFee`, `_prepBuy/SellOrderUpdate`.
- **_computeFee**: Coordinates fee calculation. Called by `_processSingleOrder`.
- **_computeFeePercent**: Calculates fee (0.05%-50%). Called by `_computeFee`.
- **_computeSwapAmount**: Calculates post-fee `amountOut`. Called by `_executeOrderWithFees`.
- **_toSingleUpdateArray**: Wraps update for `ccUpdate`. Called by `_prepareLiquidityUpdates`.
- **_prepareLiquidityUpdates**: Transfers input, updates liquidity/fees. Called by `_executeOrderWithFees`.
- **_executeOrderWithFees**: Manages fees, liquidity, history; executes order. Called by `_processSingleOrder`.
- **_processSingleOrder**: Validates pricing, liquidity, Uniswap balance; processes order. Called by `_processOrderBatch`.
- **_processOrderBatch**: Iterates orders, skips settled ones. Called by `settleBuy/SellLiquid`.
- **_finalizeUpdates**: Resizes update arrays. Called by `executeSingleBuy/SellLiquid`.
- **uint2str**: Converts uint to string. Called by error emissions.
- **executeSingleBuyLiquid**: Executes buy order via `ccUpdate`. Called by `_executeOrderWithFees`.
- **executeSingleSellLiquid**: Executes sell order via `ccUpdate`. Called by `_executeOrderWithFees`.

## Security Measures
- **Reentrancy Protection**: `nonReentrant` on `settleBuy/SellLiquid`.
- **Listing Validation**: `onlyValidListing` checks `ICCAgent.isValidListing` with try-catch.
- **Safe Transfers**: Pre/post balance checks in `_prepBuy/SellOrderUpdate`. Uses `transactToken/Native`.
- **Safety**:
  - Explicit casts, no inline assembly, public state via view functions.
  - Avoids reserved keywords, `virtual`/`override`.
  - Graceful degradation with events (`NoPendingOrders`, `InsufficientBalance`, `PriceOutOfBounds`, `UniswapLiquidityExcess`, `UpdateFailed`, `TokenTransferFailed`).
  - Skips settled orders, validates `step`, checks liquidity and Uniswap balance.
  - Struct-based `ccUpdate` calls.
  - Reverts on critical failures in `_executeOrderWithFees`, `_prepareLiquidityUpdates`.

## Key Insights
- Relies on `ICCLiquidity` for updates, uses Uniswap V2 reserves for pricing.
- Completes partial orders (status 2) set by `CCListingTemplate`.
- Uses `balanceOf` for accurate reserves.
- Zero/failed operations return `false`; `amountSent` is cumulative.
- `step` user-managed; historical updates avoid double-counting.
- Fees scale with liquidity usage, incentivizing pool growth.
- Restricts liquid settlement if Uniswap v2 LP Balance for the output token is grearter than the liquidity template balance.

### Critical vs Non-Critical Issues
- **Critical Errors**:
  - **Invalid Listing/Configuration**: `onlyValidListing` must pass; `agent` required.
  - **Failed Updates/Transfers**: `_prepareLiquidityUpdates` reverts on failure.
- **Non-Critical Errors**:
  - **Invalid Pricing**: Emits `PriceOutOfBounds`, skips order.
  - **Insufficient Liquidity**: Emits `InsufficientBalance`, skips order.
  - **Uniswap Balance Excess**: Emits `UniswapLiquidityExcess`, skips order.
