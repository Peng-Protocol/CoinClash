# CCLiquidRouter Contract Documentation

## Overview
The `CCLiquidRouter` contract (Solidity ^0.8.2) facilitates settlement of buy/sell orders using `ICCLiquidity`, inheriting `CCLiquidPartial` (v0.0.54). It integrates with `ICCListing`, `ICCLiquidity`, `IERC20`, and `IUniswapV2Pair`. Key features include a dynamic fee system (0.01% min, 10% max, based on `normalizedAmountSent / normalizedLiquidity`), user-specific settlement via `makerPendingOrdersView`, and gas-efficient iteration with `step` (starting index for batch processing, e.g., `step=0` starts from first order, `step=10` skips first 10). Uses `ReentrancyGuard`. Fees are deducted from `pendingAmount` (net amount transferred), recorded in `xFees`/`yFees`, incentivizing liquidity provision by scaling with usage—higher liquidity lowers fees, reducing slippage. Liquidity updates: for buy orders, `pendingAmount` (tokenB) increases `yLiquid`, `amountOut` (tokenA) decreases `xLiquid`; for sell orders, `pendingAmount` (tokenA) increases `xLiquid`, `amountOut` (tokenB) decreases `yLiquid`. Historical updates capture pre-settlement snapshots to track volumes without double-counting.

**SPDX License:** BSL 1.1 - Peng Protocol 2025

**Version:** 0.0.26 (updated 2025-10-11)

**Inheritance Tree:** `CCLiquidRouter` → `CCLiquidPartial` (v0.0.54) → `CCMainPartial` (v0.1.5)

**Compatibility:** `CCListingTemplate.sol` (v0.3.9), `ICCLiquidity.sol` (v0.0.5), `CCMainPartial.sol` (v0.1.5), `CCLiquidPartial.sol` (v0.0.54), `CCLiquidityTemplate.sol` (v0.1.20)

## Mappings
- None in `CCLiquidRouter`. Relies on `ICCListing` view functions (`pendingBuyOrdersView`, `pendingSellOrdersView`, `makerPendingOrdersView`) for order tracking, returning user-specific `uint256` order IDs sorted by creation, enabling `step`-based slicing for gas control.

## Structs
- **HistoricalUpdateContext** (`CCLiquidRouter`): Stores `xBalance`, `yBalance`, `xVolume`, `yVolume` (uint256) for volume snapshots.
- **OrderContext** (`CCLiquidPartial`): Holds `listingContract` (ICCListing), `tokenIn`, `tokenOut` (address) for swap direction.
- **PrepOrderUpdateResult** (`CCLiquidPartial`): Includes `makerAddress`, `recipientAddress` (address), `status` (uint8), `amountReceived`, `normalizedReceived`, `amountSent`, `preTransferWithdrawn` (uint256).
- **BuyOrderUpdateContext** (`CCLiquidPartial`): Holds `makerAddress`, `recipient` (address), `status` (uint8), `amountReceived`, `normalizedReceived`, `amountSent`, `preTransferWithdrawn` (uint256) for buy orders.
- **SellOrderUpdateContext** (`CCLiquidPartial`): Mirrors `BuyOrderUpdateContext` for sell orders.
- **OrderBatchContext** (`CCLiquidPartial`): Stores `listingAddress` (address), `isBuyOrder` (bool) for batch processing.
- **SwapImpactContext** (`CCLiquidPartial`): Holds `reserveIn`, `reserveOut`, `amountInAfterFee`, `price`, `amountOut` (uint256), `decimalsIn`, `decimalsOut` (uint8).
- **FeeContext** (`CCLiquidPartial`): Includes `feeAmount`, `netAmount`, `liquidityAmount` (uint256), `decimals` (uint8).
- **OrderProcessingContext** (`CCLiquidPartial`): Holds `maxPrice`, `minPrice`, `currentPrice`, `impactPrice` (uint256).
- **LiquidityUpdateContext** (`CCLiquidPartial`): Includes `pendingAmount`, `amountOut` (uint256), `isBuyOrder` (bool).
- **FeeCalculationContext** (`CCLiquidPartial`): Stores `outputLiquidityAmount`, `normalizedAmountSent`, `normalizedLiquidity` (uint256), `outputDecimals` (uint8).
- **LiquidityValidationContext** (`CCLiquidPartial`, v0.0.48): Holds `normalizedPending`, `normalizedSettle`, `xLiquid`, `yLiquid` (uint256).
- **UniswapBalanceContext** (`CCLiquidPartial`, v0.0.48): Stores `outputToken` (address), `normalizedUniswapBalance`, `internalLiquidity` (uint256).

## Formulas
Formulas in `CCLiquidPartial.sol` (v0.0.54) govern settlement, pricing, and fees, ensuring 18-decimal precision.

1. **Current Price**:
   - **Formula**: `price = listingContract.prices(0)`.
   - **Used in**: `_computeCurrentPrice` (called by `_validateOrderPricing` in `_processSingleOrder`), `_createHistoricalUpdate`, `_executeOrderWithFees`.
   - **Description**: Fetches price from `ICCListing.prices(0)` (Uniswap V2 reserves, `(balanceB * 1e18) / balanceA`), validated within `[minPrice, maxPrice]` (10% slippage). Try-catch ensures graceful failure.
   - **Usage**: Triggers in `settleBuy/SellLiquid` → `_processOrderBatch` → `_processSingleOrder` → `_validateOrderPricing`; emits `PriceOutOfBounds` if invalid.

2. **Swap Impact**:
   - **Formula**:
     - `amountInAfterFee = (inputAmount * 997) / 1000` (0.3% Uniswap fee).
     - `normalizedReserveIn/Out = normalize(reserveIn/Out, decimalsIn/Out)`.
     - `amountOut = (amountInAfterFee * normalizedReserveOut) / (normalizedReserveIn + amountInAfterFee)`.
     - `impactPrice = (normalizedReserveOut * 1e18) / normalizedReserveIn`.
   - **Used in**: `_computeSwapImpact` (called by `_validateOrderPricing`, `_computeSwapAmount`, `_prepBuy/SellOrderUpdate` in `_processSingleOrder`).
   - **Description**: Simulates post-fee output and price impact using Uniswap V2 pair reserves (`balanceOf`, token0-aware). Validates `impactPrice` against `[minPrice, maxPrice]`.
   - **Usage**: Emits `PriceOutOfBounds` if invalid; `amountOut` used for liquidity checks.

3. **Buy Order Output**:
   - **Formula**: `amountOut (tokenA) ≈ netAmount (tokenB) / impactPrice`, denormalized.
   - **Used in**: `_computeSwapImpact`, `_prepBuyOrderUpdate` → `_processSingleOrder` → `executeSingleBuyLiquid`.
   - **Description**: Projects tokenA output for buy orders; validates `xLiquid >= normalize(amountOut)`.

4. **Sell Order Output**:
   - **Formula**: `amountOut (tokenB) ≈ netAmount (tokenA) * impactPrice`, denormalized.
   - **Used in**: `_computeSwapImpact`, `_prepSellOrderUpdate` → `_processSingleOrder` → `executeSingleSellLiquid`.
   - **Description**: Projects tokenB output for sell orders; validates `yLiquid >= normalize(amountOut)`.

5. **Normalization/Denormalization**:
   - **Formula**:
     - Normalize: `if (decimals == 18) amount; else if (decimals < 18) amount * 10^(18 - decimals); else amount / 10^(decimals - 18)`.
   - **Used in**: `_prepareLiquidityUpdates`, `_computeSwapImpact`, `_prepBuy/SellOrderUpdate`.
   - **Description**: Ensures 18-decimal precision for calculations.

6. **Fee Calculation**:
   - **Formula**:
     - `feePercent = (amountIn * 1e18) / liquidityAmount`, clamped [0.01%, 10%].
     - `feeAmount = (amountIn * feePercent) / 1e18`.
     - `netAmount = amountIn - feeAmount`.
   - **Used in**: `_computeFee` (`_getLiquidityData`, `_computeFeePercent`, `_finalizeFee`).
   - **Description**: Scales fees with liquidity usage; recorded in `xFees`/`yFees`.

## External Functions
### settleBuyLiquid(address listingAddress, uint256 step)
- **Parameters**:
  - `listingAddress`: Address of `ICCListing` contract.
  - `step`: Starting index for order processing (gas control).
- **Behavior**: Settles buy orders (tokenB in, tokenA out) for `msg.sender`. Validates `onlyValidListing`, checks `yBalance > 0` (`volumeBalances(0)`). If `pendingOrders.length > 0`, creates historical snapshot. Processes orders via `_processOrderBatch`. Status: 3 (filled if `pending <= 0`), 2 (partial), 0 (cancelled).
- **Internal Call Flow**:
  - `onlyValidListing` → `makerPendingOrdersView` → check `yBalance`.
  - If orders: `_createHistoricalUpdate` (`volumeBalances(0)`, `prices(0)`, last `HistoricalData`).
  - `_processOrderBatch` → `_collectOrderIdentifiers` → loop: `getBuyOrderAmounts` → `_processSingleOrder`:
    - `_validateOrderPricing` (`_computeCurrentPrice`, `_computeSwapImpact`).
    - `_validateLiquidity`: Checks `yLiquid >= normalize(pendingAmount)`, `xLiquid >= normalize(amountOut)`.
    - `_checkUniswapBalance`: Ensures Uniswap LP output token balance ≤ `xLiquid`/`yLiquid`.
    - `_computeFee` → `_prepBuyOrderUpdate` (pre/post balance for `amountSent`).
    - `_executeOrder` → `_executeOrderWithFees`: Emits `FeeDeducted`; updates liquidity (`_prepareLiquidityUpdates`); snapshots history; calls `executeSingleBuyLiquid`.
- **Emits**: `NoPendingOrders`, `InsufficientBalance`, `UpdateFailed`, `PriceOutOfBounds`, `FeeDeducted`, `UniswapLiquidityExcess`.
- **Graceful Degradation**: Skips invalid orders (pricing/liquidity/Uniswap balance) with events; try-catch in `ccUpdate`.

### settleSellLiquid(address listingAddress, uint256 step)
- **Parameters**: As above.
- **Behavior**: Settles sell orders (tokenA in, tokenB out). Validates `xBalance > 0`. Mirrors buy logic with `SellOrderUpdate[]`.
- **Internal Call Flow**: Similar to `settleBuyLiquid`, using `getSellOrderAmounts/Core`, updating `xLiquid+/yLiquid-/xFees+`, calling `executeSingleSellLiquid`.
- **Emits**: As above, sell-specific.
- **Graceful Degradation**: Identical.

## Internal Functions (CCLiquidRouter)
### _createHistoricalUpdate(address listingAddress, ICCListing listingContract)
- **Behavior**: Creates `HistoricalUpdate` snapshot using `volumeBalances(0)`, `prices(0)`, and last `HistoricalData` (`xVolume`, `yVolume`). Called pre-batch in `settleBuy/SellLiquid` if orders exist.
- **Call Tree**: `settleBuy/SellLiquid` → `_createHistoricalUpdate` → `ccUpdate`.
- **External Interaction**: Updates `ICCListing` via `ccUpdate` with `HistoricalUpdate[]`.
- **Details**: Uses `HistoricalUpdateContext` to manage ≤4 variables, avoiding stack issues. Try-catch emits `UpdateFailed` on error.

## Internal Functions (CCLiquidPartial, v0.0.54)
- **_validateOrderPricing(address, bool, uint256)**: Validates price within 10% slippage; emits `PriceOutOfBounds` if invalid.
- **_validateLiquidity(address, uint256, bool, uint256)**: Checks `xLiquid`/`yLiquid` sufficiency; emits `InsufficientBalance`. Non-view due to external calls.
- **_checkUniswapBalance(address, uint256, bool, LiquidityValidationContext)**: Ensures Uniswap LP output token balance ≤ `xLiquid`/`yLiquid`; emits `UniswapLiquidityExcess`. Non-view.
- **_executeOrder(address, uint256, bool, uint256, uint256, FeeContext)**: Calls `_executeOrderWithFees`.
- **_computeAmountSent(address)**: Captures pre-transfer balance.
- **_updateFees(address, uint256, bool)**: Updates `xFees`/`yFees` via `ccUpdate`.
- **_prepBuyOrderUpdate(address, uint256, uint256, uint256)**: Prepares buy order data; computes `amountSent` via pre/post balance.
- **_prepSellOrderUpdate(address, uint256, uint256, uint256)**: Prepares sell order data; mirrors buy logic.
- **_getSwapReserves**: Fetches Uniswap pair reserves; token0-aware.
- **_computeCurrentPrice**: Fetches `prices(0)` with try-catch.
- **_computeSwapImpact**: Calculates `amountOut`, `impactPrice`.
- **_getTokenAndDecimals**: Retrieves token/decimals by order type.
- **_computeFee**: Uses `_getLiquidityData`, `_computeFeePercent`, `_finalizeFee`.
- **_computeSwapAmount**: Calculates post-fee `amountOut`.
- **_toSingleUpdateArray**: Wraps `UpdateType` for `ccUpdate`.
- **_prepareLiquidityUpdates**: Transfers input, updates liquidity/fees.
- **_executeOrderWithFees**: Manages fees, liquidity, history; executes single order.
- **_processSingleOrder**: Validates, computes fees, executes; skips non-critical issues.
- **_processOrderBatch(address, bool, uint256)**: Loops over order IDs; aggregates success.
- **_finalizeUpdates**: Resizes update arrays.
- **uint2str**: Converts uint to string for errors.
- **executeSingleBuyLiquid(address, uint256)**: Executes buy order; updates `BuyOrderUpdate[]` via `ccUpdate`.
- **executeSingleSellLiquid(address, uint256)**: Executes sell order; updates `SellOrderUpdate[]`.

## Security Measures
- **Reentrancy Protection**: `nonReentrant` on `settleBuy/SellLiquid`.
- **Listing Validation**: `onlyValidListing` try-catch checks `isValidListing`, ensuring non-zero addresses and distinct tokens.
- **Safe Transfers**: Pre/post `balanceOf`/`.balance` in `_prepBuy/SellOrderUpdate` for exact `amountSent`. Ensures `transactToken/Native` from `CCListingTemplate` to `CCLiquidityTemplate` before updating `x/yLiquid`.
- **Safety**:
  - Explicit casts (e.g., `ICCListing(listingAddress)`).
  - No inline assembly; array resizing via Solidity.
  - Public state via view functions; no fixed iteration caps (uses `step`).
  - Graceful degradation: Skips invalid orders (pricing/liquidity/Uniswap balance) with events (`PriceOutOfBounds`, `InsufficientBalance`, `UniswapLiquidityExcess`); try-catch in `ccUpdate` emits `UpdateFailed` with reason.
  - No nested self-references in structs; dependencies computed first.
  - Fee bounds (0.01%-10%) prevent abuse.
  - `step` bounds-checked against `pendingOrders.length`.

## Key Insights 
- Relies on `ICCLiquidity` for updates, not direct swaps; assumes `transact*` handles approvals.
- Completes partial orders (status 2) but doesn't create; assumes `CCListingTemplate` sets initial pending amounts.
- Uses `balanceOf` for reserves (not `getReserves`) for non-pair token accuracy.
- Zero/failed operations return false, no revert; `amountSent` is cumulative.
- Depositor fixed to `this`; `step` user-managed for batch resumption.
- Historical updates at batch start and per-order execution avoid double-counting volumes.
- Fees scale with liquidity usage, incentivizing pool growth (doubling pool halves max fee).
- Restricts liquid settlement if Uniswap v2 LP Balance for the output token is grearter than the liquidity template balance.

## Critical vs Non-Critical Issues
- **Critical Errors**:
  - **Invalid Listing/Configuration**: `onlyValidListing` at `CCAgent` must pass; `Agent` required.
  - **Failed Liquidity/Fee Updates**: `_prepareLiquidityUpdates` reverts on `ccUpdate` failure.
  - **Failed Token Transfers**: `_prepareLiquidityUpdates` reverts on `transactToken/Native` failure.
- **Non-Critical Errors**:
  - **Invalid Pricing**: `_validateOrderPricing` emits `PriceOutOfBounds`, skips order.
  - **Insufficient Liquidity**: `_validateLiquidity` emits `InsufficientBalance`, skips order.
  - **Uniswap Balance Excess**: `_checkUniswapBalance` emits `UniswapLiquidityExcess`, skips order.
  - **No Pending Orders**: `settleBuy/SellLiquid` emits `NoPendingOrders`, returns.
