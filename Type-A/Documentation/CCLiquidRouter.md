# CCLiquidRouter Contract Documentation

## Overview
The `CCLiquidRouter` contract (Solidity ^0.8.2) settles buy/sell orders using `ICCLiquidity`, inheriting `CCLiquidPartial` (v0.1.0). It integrates with `ICCListing`, `ICCLiquidity`, `IERC20`, and `IUniswapV2Pair`. Features a fee system (0.05% min at ≤1% liquidity usage, scaling to 0.10% at 2%, 0.50% at 10%, 50% max at 100%), user-specific settlement via `makerPendingOrdersView`, and gas-efficient iteration with `step`. Uses `ReentrancyGuard`. Fees are deducted from `pendingAmount`, recorded via `ccUpdate` on `ICCLiquidity`. Liquidity updates: buy orders increase input token liquidity, decrease output token liquidity; sell orders mirror. Historical updates capture pre-settlement snapshots **once per unique token pair per batch**. Validates Uniswap V2 pair balances. **Now operates in monolithic architecture with no per-pair assumptions; uses `startToken`/`endToken` from order data; queries Uniswap reserves directly; supports any token pair.**

**SPDX License:** BSL 1.1 - Peng Protocol 2025

**Version:** 0.1.0 (updated 2025-12-11)

**Inheritance Tree:** `CCLiquidRouter` → `CCLiquidPartial` (v0.1.0)

**Compatibility:** `CCListingTemplate.sol` (v0.4.2), `ICCLiquidity.sol` (v0.2.0), `CCLiquidRouter.sol` (v0.1.0), `CCLiquidPartial.sol` (v0.1.0), `CCLiquidityTemplate.sol` (v0.2.0)

## Mappings
- `processedPairsMap` (`CCLiquidPartial`): `bytes32 → bool`, tracks processed token pairs (`keccak256(abi.encodePacked(tokenIn, tokenOut))`) to ensure **one historical update per unique pair per batch**.

## Structs
- **OrderContext** (`CCLiquidPartial`): Holds `listingContract` (ICCListing), `liquidityContract` (ICCLiquidity), `tokenIn`, `tokenOut` (address), `decimalsIn`, `decimalsOut` (uint8).
- **SwapImpactContext** (`CCLiquidPartial`): Holds `reserveIn`, `reserveOut`, `decimalsIn`, `decimalsOut` (uint8), `amountInAfterFee`, `price`, `amountOut` (uint256).
- **FeeContext** (`CCLiquidPartial`): Includes `feeAmount`, `netAmount`, `liquidityAmount` (uint256), `decimals` (uint8).
- **OrderProcessingContext** (`CCLiquidPartial`): Holds `maxPrice`, `minPrice`, `currentPrice`, `impactPrice` (uint256).
- **LiquidityUpdateContext** (`CCLiquidPartial`): Includes `pendingAmount`, `amountOut` (uint256), `isBuyOrder` (bool), `tokenIn`, `tokenOut` (address), `decimalsIn`, `decimalsOut` (uint8).
- **LiquidityValidationContext** (`CCLiquidPartial`): Holds `normalizedPending`, `normalizedSettle`, `liquidIn`, `liquidOut` (uint256).
- **UniswapBalanceContext** (`CCLiquidPartial`): Holds `outputToken` (address), `normalizedUniswapBalance`, `internalLiquidity` (uint256).
- **OrderLoad** (`CCLiquidPartial`): Helper struct ≤4 fields: `addresses`, `amounts` (arrays), `status` (uint8).
- **OrderExtract** (`CCLiquidPartial`): Helper: `tokenIn`, `tokenOut` (address), `pendingAmount` (uint256).
- **PairValidation** (`CCLiquidPartial`): Helper: `pairAddress` (address), `liquidOut` (uint256).

## Formulas
Formulas in `CCLiquidPartial.sol` (v0.1.0) ensure 18-decimal precision.

1. **Current Price**:
   - **Formula**: `price = (normalize(balanceB, decimalsB) * 1e18) / normalize(balanceA, decimalsA)`.
   - **Used in**: `_computeCurrentPrice`, `_validateOrderPricing`, `_processSingleOrder`.
   - **Description**: Calculates price from Uniswap V2 reserves, validated within 10% slippage.
   - **Usage**: Triggers in `settleBuy/SellLiquid` → `_processOrderBatch` → `_processSingleOrder` → `_validateOrderPricing`.

2. **Swap Impact**:
   - **Formula**:
     - `amountInAfterFee = (inputAmount * 997) / 1000`.
     - `amountOut = (amountInAfterFee * normalizedReserveOut) / (normalizedReserveIn + amountInAfterFee)`.
     - `impactPrice = (normalizedReserveOut * 1e18) / normalizedReserveIn`.
   - **Used in**: `_computeSwapImpact`, `_validateOrderPricing`, `_executeOrderWithFees`.
   - **Description**: Simulates Uniswap V2 swap output and price impact.
   - **Usage**: Emits `PriceOutOfBounds` if invalid; used for liquidity checks.

3. **Fee Calculation**:
   - **Formula**:
     - `usagePercent = (amountIn * 1e18) / liquidityAmount`.
     - `feePercent = (usagePercent * 5e15) / 1e16` (0.05% per 1% usage).
     - `feePercent = max(5e14, min(5e17, feePercent))`.
     - `feeAmount = (amountIn * feePercent) / 1e18`, `netAmount = amountIn - feeAmount`.
   - **Used in**: `_computeFeePercent`, `_computeFee`, `_executeOrderWithFees`.
   - **Description**: Scales fees linearly (0.05% at ≤1%, 0.10% at 2%, 0.50% at 10%, 50% at 100%).
   - **Usage**: Emits `FeeDeducted` in `_executeOrderWithFees`.

4. **Buy Order Output**:
   - **Formula**: `amountOut (tokenOut) ≈ netAmount (tokenIn) * impactPrice`, denormalized.
   - **Used in**: `_computeSwapImpact`, `_processSingleOrder`, `_executeOrderWithFees`.
   - **Description**: Projects output; validates `liquidOut >= normalize(amountOut)`.

5. **Sell Order Output**:
   - **Formula**: `amountOut (tokenOut) ≈ netAmount (tokenIn) / impactPrice`, denormalized.
   - **Used in**: `_computeSwapImpact`, `_processSingleOrder`, `_executeOrderWithFees`.
   - **Description**: Projects output; validates `liquidOut >= normalize(amountOut)`.

6. **Normalization/Denormalization**:
   - **Normalize**: `normalize(amount, decimals) = decimals < 18 ? amount * 10^(18-decimals) : amount / 10^(decimals-18)`.
   - **Denormalize**: `denormalize(amount, decimals) = decimals < 18 ? amount / 10^(18-decimals) : amount * 10^(decimals-18)`.
   - **Used in**: `_computeSwapImpact`, `_computeCurrentPrice`, `_validateLiquidity`, `_checkUniswapBalance`, `_prepareLiquidityUpdates`, `_computeFee`.

## External Functions
### settleBuyLiquid(uint256 step)
- **Parameters**:
  - `step`: Starting index in `makerPendingOrdersView`.
- **Behavior**: Settles buy orders for `msg.sender`. Validates `listingAddress`. Fetches pending orders. Emits `NoPendingOrders` if none. Calls `_processOrderBatch(true, step)`. Emits `UpdateFailed` on failure.
- **External Call Tree**:
  - `ICCListing.makerPendingOrdersView(msg.sender)`: Fetches order IDs.
  - `ICCListing.getBuyOrder`: Loads order data in `_loadOrderContext`.
  - `IUniswapV2Factory.getPair`: Validates pair in `_validatePairAndLiquidity`.
  - `ICCLiquidity.liquidityAmounts`: Validates input/output liquidity.
  - `ICCListing.ccUpdate`: Updates historical data (once per pair), order status.
  - `ICCListing.transactToken/Native`: Transfers output token to recipient.
  - `ICCLiquidity.ccUpdate`: Updates liquidity and fees.
- **Emits**: `NoPendingOrders`, `UpdateFailed`, `PriceOutOfBounds`, `UniswapLiquidityExcess`, `FeeDeducted`, `TokenTransferFailed`, `InsufficientBalance`.
- **Graceful Degradation**: Skips invalid/settled orders; returns `false` on non-critical errors.

### settleSellLiquid(uint256 step)
- **Parameters**: Same as `settleBuyLiquid`.
- **Behavior**: Settles sell orders. Mirrors buy logic with `isBuyOrder = false`.
- **External Call Tree**: Identical to `settleBuyLiquid`, using sell-specific paths.
- **Emits**: Same as `settleBuyLiquid`.
- **Graceful Degradation**: Identical.

## Internal Functions (CCLiquidRouter)
- None beyond inheritance.

## Internal Functions (CCLiquidPartial, v0.1.0)
- **_createHistoricalUpdate**: Creates `HistoricalUpdate` with current reserves, price, volume. Called once per unique pair via `_handleHistoricalOnce`.
- **_validateOrderPricing**: Validates price within 10% slippage; returns `impactPrice = 0` if invalid.
- **_validateLiquidity**: Checks `liquidIn >= normalizedPending`, `liquidOut >= normalizedSettle`.
- **_checkUniswapBalance**: Ensures `normalizedUniswapBalance ≤ internalLiquidity`.
- **_executeOrderWithFees**: Deducts fee, computes `amountOut`, updates liquidity/fees/history, executes transfer.
- **_computeFee**, **_computeFeePercent**: Calculate dynamic fee based on usage.
- **_computeSwapImpact**: Returns `price`, `amountOut` using Uniswap constant product.
- **_getTokenDecimals**: Returns 18 for native, else `IERC20.decimals()`.
- **_getSwapReserves**: Fetches reserves from pair.
- **_computeCurrentPrice**: Calculates price from reserves.
- **_toSingleUpdateArray**: Wraps single `UpdateType` for `ccUpdate`.
- **_updateFees**: Sends fee update to `ICCLiquidity`.
- **_prepareLiquidityUpdates**: Updates input/output liquidity, transfers input token.
- **_executeSingleBuyLiquid**: Transfers output, updates order status to 2.
- **_executeSingleSellLiquid**: Mirrors buy.
- **_processSingleOrder**: Validates pricing, liquidity, Uniswap balance; executes with fees.
- **_markPairProcessed**, **_isPairProcessed**: Track processed pairs.
- **_loadOrderContext**: Loads order data into `OrderLoad`.
- **_extractOrderTokens**: Extracts `tokenIn`, `tokenOut`, `pendingAmount`.
- **_validatePairAndLiquidity**: Gets pair, checks output liquidity.
- **_handleHistoricalOnce**: Ensures one historical update per pair.
- **_processOrderBatch**: Iterates from `step`, loads, validates, processes orders.

## Security Measures
- **Reentrancy Protection**: `nonReentrant` on `settleBuy/SellLiquid`.
- **Listing Validation**: Requires `listingAddress != 0`.
- **Safe Transfers**: `try/catch` with revert on failure; pre/post balance checks via `transactToken/Native`.
- **Safety**:
  - Explicit casts, no inline assembly, no `virtual`/`override`.
  - Graceful degradation with events.
  - Skips settled orders, validates `step`, checks liquidity and Uniswap balance.
  - **One historical update per pair per batch** via `processedPairsMap`.
  - Reverts on critical failures in `_prepareLiquidityUpdates`, `_updateFees`.
  - Uses helper structs ≤4 fields for gas efficiency.

## Key Insights
- **Monolithic design**: No per-pair assumptions; works with any `startToken`/`endToken`.
- **Direct Uniswap queries**: Uses `balanceOf` on pair for reserves.
- **Historical update optimization**: One per unique pair per batch.
- **Dynamic fees**: Based on token-specific liquidity usage.
- **Order data**: Uses `addresses[2] = startToken`, `addresses[3] = endToken`, `amounts[0] = pendingAmount`.
- **Zero/failed operations**: Return `false`; `success` is cumulative.
- **Step control**: User-managed iteration starting point.
- **Restricts settlement** if Uniswap balance of output token > internal liquidity.

### Critical vs Non-Critical Issues
- **Critical Errors**:
  - **Invalid Listing**: `listingAddress == 0`.
  - **Failed Updates/Transfers**: `_prepareLiquidityUpdates`, `_updateFees` revert.
  - **Factory not set**: Reverts in `_processOrderBatch`.
- **Non-Critical Errors**:
  - **Invalid Pricing**: Emits `PriceOutOfBounds`, skips.
  - **Insufficient Liquidity**: Emits `InsufficientBalance`, skips.
  - **Uniswap Balance Excess**: Emits `UniswapLiquidityExcess`, skips.
  - **Pair not found**: Emits `UpdateFailed`, skips.