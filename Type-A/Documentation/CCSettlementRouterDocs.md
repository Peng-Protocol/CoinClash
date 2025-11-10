# CCSettlementRouter Contract Documentation

## Overview
The `CCSettlementRouter` contract, implemented in Solidity (`^0.8.2`), facilitates the settlement of buy and sell orders on a decentralized trading platform using Uniswap V2 for order execution. It inherits functionality from `CCSettlementPartial`, which extends `CCUniPartial` and `CCMainPartial`, integrating with external interfaces (`ICCListing`, `IUniswapV2Pair`, `IUniswapV2Router02`, `IERC20`) for token operations, `ReentrancyGuard` for reentrancy protection, and `Ownable` for administrative control. The contract handles order settlement via `settleOrders`, accepting pre-calculated `amountsIn` in **normalized 18-decimal format** (off-chain computed), eliminating on-chain price impact and slippage calculations. All normalization/denormalization is handled in `CCUniPartial.sol`. The router validates orders, executes swaps, and applies updates via `ccUpdate` on the listing contract. It uses `nonReentrant`, emits `OrderSkipped` for non-critical failures, and reverts with decoded reasons on catastrophic errors. No `SafeERC20`, no virtual/override, no inline assembly, no fixed loops — uses user-supplied arrays. Addresses set post-deployment via `set*` functions.

**SPDX License:** BSL 1.1 - Peng Protocol 2025

**Version:** 0.2.1 (10/11)

**Inheritance Tree:** `CCSettlementRouter` → `CCSettlementPartial` → `CCUniPartial` → `CCMainPartial`

**Compatible Contracts:**
- `CCListingTemplate.sol` (v0.3.9)
- `CCMainPartial.sol` (v0.1.5)
- `CCUniPartial.sol` (v0.2.1)
- `CCSettlementPartial.sol` (v0.2.0)

### Changes
- **v0.2.1 (10/11)**: **Critical Refactor (x64)** — Resolved `Stack too deep` in `_createOrderUpdates` by refactoring into **call-tree of helper functions** with **private structs** (`UpdateIds`, `UpdateAmounts`, `UpdateState`) limited to **4 fields each**. All logic preserved. Fixed `ParserError` by renaming `partial` → `buyPartial`/`sellPartial`. Added inline comments per helper. **No behavior change**.
- **v0.2.0 (Trimmed)**: **Major Off-Chain Calculation Shift** — Removed on-chain `_computeSwapAmount`, `_computeMaxAmountIn`, `_prepareSwapData`, `_prepareSellSwapData`, `_executeBuyTokenSwap`, `_executeSellTokenSwap`, `_executeBuyETHSwap`, `_executeSellETHSwapInternal`, `_finalizeTokenSwap`, `_executeTokenSwap`, `_prepBuyOrderUpdate`, `_prepSellOrderUpdate` from `CCUniPartial`. Removed `_processOrder`, `_validateOrderParams`, `_applyOrderUpdate`, `_prepareUpdateData`, `_updateFilledAndStatus` from `CCSettlementPartial`. Removed `_initSettlement`, `_processOrderBatch`, `SettlementState`, `OrderProcessContext`, `PrepOrderUpdateResult`. **Now**: `settleOrders` accepts `orderIds[]` and `amountsIn[]` (normalized 18-decimal, pre-calculated off-chain). `_processBuyOrder`/`_processSellOrder` denormalize `amountIn`, pull funds, execute swap via `_executePartialBuySwap`/`_executePartialSellSwap`, create updates via refactored `_createOrderUpdates`. Historical entry created once per call. **All price impact, slippage, tax handling now off-chain**.
- **v0.1.23**: Updated to reflect `CCUniPartial.sol` v0.1.27 (merged `_createBuyOrderUpdates`/`_createSellOrderUpdates` into `_createOrderUpdates`; inlined `prepResult` in swap execution; commented unused `amounts`), `CCSettlementPartial.sol` v0.1.22 (inlined `_extractPendingAmount`, merged `_updateFilledAndStatus`/`_prepareUpdateData`).
- **v0.1.22**: Patched `_validateOrder` to set `context.status = 0` on pricing failure; `_processOrderBatch` skips `status == 0`.
- **v0.1.21**: Fixed `amountSent` using pre-swap balance in `_executeOrderSwap`.
- **v0.1.20**: Fixed `_createOrderUpdates` to accumulate `amountSent` from prior state.
- **v0.1.19**: Restored `_computeCurrentPrice`, removed redundant denormalization in prep functions.
- **v0.1.18**: Made `_checkPricing` non-reverting, emit `OrderSkipped`.
- **v0.1.17**: Added `OrderSkipped` event, made `_applyOrderUpdate` view.
- **v0.1.16**: Moved prep functions to `CCUniPartial`, used `amountInReceived` for tax tokens.
- **v0.1.15**: Added allowance check (10^50), used post-transfer balance for `amountIn`.
- **v0.1.14**: Used live pair balances for reserves.
- **v0.1.13**: Refactored `settleOrders` with `SettlementState`, added tax handling.

## Mappings
- None defined directly. Relies on `ICCListing` views: `getBuyOrderCore`, `getSellOrderAmounts`, `getBuyOrderPricing`, `prices`, `volumeBalances`, `historicalDataLengthView`, `getHistoricalDataView`.

## Structs
- **OrderContext** (`CCSettlementRouter`): 
  - `orderId` (uint256)
  - `buyUpdates` (ICCListing.BuyOrderUpdate[])
  - `sellUpdates` (ICCListing.SellOrderUpdate[])
  - `status` (uint8) — updated post-`ccUpdate`
- **SettlementContext** (`CCUniPartial`): 
  - `tokenA`, `tokenB` (address)
  - `decimalsA`, `decimalsB` (uint8)
  - `uniswapV2Pair` (address)
- **SwapContext** (`CCUniPartial`): 
  - `listingContract` (ICCListing)
  - `makerAddress`, `recipientAddress` (address)
  - `status` (uint8)
  - `tokenIn`, `tokenOut` (address)
  - `decimalsIn`, `decimalsOut` (uint8)
  - `denormAmountIn`, `denormAmountOutMin` (uint256)
  - `price`, `expectedAmountOut` (uint256)
- **UpdateIds** (private, `CCUniPartial`): `orderId`, `maker`, `recipient` — max 4 fields
- **UpdateAmounts** (private, `CCUniPartial`): `pending`, `filled`, `amountIn`, `amountOut` — max 4 fields
- **UpdateState** (private, `CCUniPartial`): `priorSent`, `decimalsOut`, `isBuyOrder` — max 4 fields

## External Functions
- **settleOrders(address listingAddress, uint256[] calldata orderIds, uint256[] calldata amountsIn, bool isBuyOrder) → string memory reason** (`CCSettlementRouter`):
  - **Inputs**: `orderIds` and `amountsIn` must match in length. `amountsIn` **must be in 18-decimal normalized format** (off-chain calculated).
  - **Flow**:
    1. Validate `uniswapV2Router`, length match, non-empty.
    2. Fetch `SettlementContext` from listing.
    3. Call `_createHistoricalEntry` → one `HistoricalUpdate` with current `price`, `xBalance`, `yBalance`, `xVolume`, `yVolume`.
    4. For each order:
       - Skip if `_validateOrder` fails (emits `OrderSkipped`)
       - Call `_processBuyOrder` or `_processSellOrder` → returns `buyUpdates`/`sellUpdates`
       - Call `_updateOrder` → `ccUpdate` with updates
       - Revert on `ccUpdate` failure
    5. Return empty string if ≥1 order settled, else error.
  - **Internal Call Tree**:
    - `_createHistoricalEntry` → `volume`ccUpdate` with `HistoricalUpdate[]`
    - `_validateOrder` → checks `pending > 0`, `status == 1`, `_checkPricing`
    - `_checkPricing` → validates `currentPrice` in `[minPrice, maxPrice]`, emits `OrderSkipped` if not
    - `_processBuyOrder` → denormalizes `amountIn`, pulls funds via `transact*`, calls `_executePartialBuySwap`
    - `_processSellOrder` → denormalizes `amountIn`, pulls funds, calls `_executePartialSellSwap`
    - `_executePartialBuySwap` → `_prepareSwapData` → `_computeSwapImpact` → `_performSwap` → `_createOrderUpdates`
    - `_executePartialSellSwap` → `_prepareSellSwapData` → `_computeSwapImpact` → `_performSwap` → `_createOrderUpdates`
    - `_createOrderUpdates` → **call-tree**: `_computePendingAndStatus` → `_normalizeOut` → `_buildBuyPartial`/`_buildSellPartial` → `_buildBuyTerminal`/`_buildSellTerminal` → `_assembleBuyUpdates`/`_assembleSellUpdates`
    - `_updateOrder` → `ccUpdate` with `buyUpdates` or `sellUpdates`, captures new `status`

## Internal Functions

### CCSettlementRouter
- **_validateOrder(address listingAddress, uint256 orderId, bool isBuyOrder, ICCListing listingContract) → bool**: 
  - Fetches `pending`, `status` via `getBuyOrderAmounts`/`getSellOrderCore`
  - Returns `false` and emits `OrderSkipped` if `pending == 0` or `status != 1`
  - Calls `_checkPricing`, returns `false` on failure
- **_updateOrder(ICCListing listingContract, OrderContext memory context, bool isBuyOrder) → (bool success, string memory reason)**:
  - Calls `ccUpdate` with `buyUpdates` or `sellUpdates`
  - On success: fetches new `status`, returns `(false, "")` if `status == 0 || 3`
  - On catch: returns `(false, "Update failed for order X: reason")`
- **_createHistoricalEntry(ICCListing listingContract)**:
  - Fetches `volumeBalances(0)` → `xBalance`, `yBalance` (normalized)
  - Fetches `prices(0)` → `price`
  - If `historicalDataLengthView() > 0`: fetches last `HistoricalData` → `xVolume`, `yVolume`
  - Builds `HistoricalUpdate[]` with current values + `block.timestamp`
  - Calls `ccUpdate` with `historicalUpdates`, reverts on failure

### CCSettlementPartial
- **_checkPricing(address listingAddress, uint256 orderIdentifier, bool isBuyOrder) → bool**:
  - Fetches `maxPrice`, `minPrice` via `getBuyOrderPricing`/`getSellOrderPricing`
  - Fetches `currentPrice = prices(0)`
  - Emits `OrderSkipped` and returns `false` if `currentPrice == 0` or out of bounds
- **_processBuyOrder(...) → ICCListing.BuyOrderUpdate[]**:
  - Validates router, `pending > 0`, `status == 1`, `amountIn > 0`
  - Denormalizes `amountIn` → `denormalize(amountIn, decimalsB)`
  - Calls `_prepBuyOrderUpdate` → pulls funds via `transactNative`/`transactToken`, captures `amountSent`
  - Calls `_executePartialBuySwap` → returns updates
- **_processSellOrder(...) → ICCListing.SellOrderUpdate[]**:
  - Same as buy, but for sell side
  - Calls `_prepSellOrderUpdate` before swap

### CCUniPartial
- **_getTokenAndDecimals(bool isBuyOrder, SettlementContext memory settlementContext) → (address, uint8)**: Returns `tokenB/decimalsB` (buy) or `tokenA/decimalsA` (sell)
- **_prepBuyOrderUpdate(...) → uint256 amountSent**:
  - Validates `pending > 0`, `status == 1`
  - Captures `preBalance` of token/ETH
  - Calls `transactNative{value}` or `transactToken`
  - Returns `postBalance - preBalance`, reverts if zero
- **_prepSellOrderUpdate(...) → uint256 amountSent**: Same for sell side
- **_computeSwapImpact(uint256 amountIn, bool isBuyOrder, SettlementContext memory settlementContext) → (uint256 price, uint256 amountOut)**:
  - Fetches live reserves via `IERC20.balanceOf(uniswapV2Pair)`
  - Normalizes reserves and `amountIn` to 18 decimals
  - Applies 0.3% fee: `amountInAfterFee = amountIn * 997 / 1000`
  - Computes `amountOut` via constant product
  - Returns `price = prices(0)`, `amountOut` denormalized
  (Used to calculate a safe `amountOutMin` that can be set for slippage protection during the swap).
- **_prepareSwapData(...) → (SwapContext memory, address[] memory path)**:
  - Fetches `maker`, `recipient`, `status`
  - Sets `tokenIn = tokenB`, `tokenOut = tokenA`, decimals
  - Denormalizes `amountIn`
  - Calls `_computeSwapImpact` → `price`, `expectedAmountOut`
  - Sets `denormAmountOutMin = expectedAmountOut * 95 / 100`
  - Builds `path = [tokenB, tokenA]`
- **_prepareSellSwapData(...) → (SwapContext memory, address[] memory path)**: Same for sell side, `path = [tokenA, tokenB]`
- **_performSwap(SwapContext memory context, address[] memory path, bool isETHIn, bool isETHOut) → uint256 amountOut**:
  - Captures `preBalanceOut`
  - Executes correct Uniswap call (`swapExactETHForTokens`, `swapExactTokensForETH`, or `swapExactTokensForTokens`)
  - Returns `postBalance - preBalance`, reverts if zero
- **_createOrderUpdates(...) → (buyUpdates[], sellUpdates[])**:
  - **Call Tree (x64)**:
    1. Group inputs into `UpdateIds`, `UpdateAmounts`, `UpdateState`
    2. `_computePendingAndStatus` → `newPending`, `newStatus`
    3. If buy: `_buildBuyPartial` → `buyPartial`, `_buildBuyTerminal` → `buyTerminal`, `_assembleBuyUpdates`
    4. If sell: `_buildSellPartial` → `sellPartial`, `_buildSellTerminal` → `sellTerminal`, `_assembleSellUpdates`
  - Normalizes `amountOut` via `_normalizeOut`
  - Sets `status = 3` if `newPending == 0`, else `2`
- **_executePartialBuySwap(...) → buyUpdates[]**:
  - Calls `_prepareSwapData`
  - Calls `_performSwap`
  - Fetches `filled`, `priorAmountSent`
  - Calls `_createOrderUpdates`
- **_executePartialSellSwap(...) → sellUpdates[]**:
  - Calls `_prepSellOrderUpdate` first
  - Then same as buy swap
- **uint2str(uint256 _i) → string memory**: For error messages

## Key Calculations
- **All swap amounts pre-calculated off-chain in 18-decimal format**
- **No on-chain price impact or slippage calculation**
- **Normalization**:
  - `normalize(value, decimals) = value * 10^(18 - decimals)`
  - `denormalize(value, decimals) = value / 10^(18 - decimals)`
- **Swap Impact (for validation only)**:
  - Used in `_computeSwapImpact` to estimate `amountOut` and set `amountOutMin = 95%`
  - Not used to limit `amountIn` — off-chain responsibility
  - **`amountOutMin = expectedAmountOut * 95 / 100` means:  
“Accept no less than **95% of the expected output** from the Uniswap swap — if the actual amount received is lower, **revert the entire transaction**.”**

## Token Flow
- **Buy Order**:
  1. Off-chain: compute `amountIn` (tokenB, normalized)
  2. `settleOrders` → `_processBuyOrder` → denormalize → `transact*` → pull to router
  3. `_executePartialBuySwap` → `swapExact*` → send tokenA to recipient
  4. `amountOut` measured via balance diff
  5. `_createOrderUpdates` → normalize `amountOut` → `amountSent`
- **Sell Order**:
  1. Pull tokenA → swap → send tokenB/ETH to recipient
  2. `amountSent` = actual received (post-tax)

## Key Interactions
- **Uniswap V2**:
  - `amountIn`: denormalized from `amountsIn[i]`
  - `amountOutMin`: `expectedAmountOut * 95 / 100` (from `_computeSwapImpact`)
  - `path`: 2-element array
  - `to`: `recipientAddress`
  - `deadline`: `block.timestamp + 15`
- **ICCListing**:
  - **Views**: All `get*`, `prices`, `volumeBalances`, `historicalDataLengthView`, `getHistoricalDataView`
  - **Updates**: `ccUpdate` called **twice per call**:
    - Once for `HistoricalUpdate`
    - Once per successful order for `BuyOrderUpdate[]` or `SellOrderUpdate[]`
  - **Transfers**: `transactNative`/`transactToken` pull funds to router
- **ICCAgent**: `onlyValidListing` modifier

## Limitations and Assumptions
- **Off-Chain Calculation Required**: `amountsIn` must respect:
  - Price bounds
  - Reserve constraints
  - Slippage tolerance
  - Tax-on-transfer
  - Convert to **18-decimal normalized**
- **No On-Chain Validation of `amountsIn`**: Assumes correct input
- **Historical Entry**: Created once per `settleOrders` call, even if no orders settle
- **Partial Fills**: Supported via multiple calls with updated `amountsIn`
- **Tax Tokens**: Handled via pre/post balance checks in `_prep*OrderUpdate`
- **ETH**: Treated as `address(0)`, balance via `address(this).balance`

## Additional Details
- **Reentrancy**: `nonReentrant` on `settleOrders`
- **Gas**: No loops with fixed bounds — full array processing
- **Error Handling**:
  - `OrderSkipped`: Non-critical (zero pending, bad price, zero amount)
  - Revert: Missing router, length mismatch, `ccUpdate` fail, zero received
- **Status**:
  - `1` = active
  - `2` = partially filled
  - `3` = filled
  - `0` = invalid/terminal
- **ccUpdate**:
  - **Historical**: `structId` not checked — assumed correct
  - **Order Updates**: Two updates per order:
    - `structId = 2`: volatile fields (`pending`, `filled`, `amountSent`)
    - `structId = 0`: terminal status
- **AmountSent**: Cumulative, normalized to 18 decimals
- **No `try` for internal calls** — only external `ccUpdate`, `transact*`, Uniswap
- **All mappings/arrays properly named in params**
- **Graceful degradation**: Skip orders, only revert on system failure
