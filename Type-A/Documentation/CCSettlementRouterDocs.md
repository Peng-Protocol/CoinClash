# CCSettlementRouter Contract Documentation

## Overview
The `CCSettlementRouter` contract, implemented in Solidity (`^0.8.2`), facilitates the settlement of buy and sell orders on a decentralized trading platform using Uniswap V2 for order execution. It inherits functionality from `CCSettlementPartial`, which extends `CCUniPartial` and `CCMainPartial`, integrating with external interfaces (`ICCListing`, `IUniswapV2Pair`, `IUniswapV2Router02`, `IERC20`) for token operations, `ReentrancyGuard` for reentrancy protection, and `Ownable` for administrative control. The contract handles order settlement via `settleOrders`, accepting pre-calculated `amountsIn` in **normalized 18-decimal format** (off-chain computed), eliminating on-chain price impact and slippage calculations. All normalization/denormalization is handled in `CCUniPartial.sol`. The router validates orders, executes swaps, and applies updates via `ccUpdate` on the listing contract. It uses `nonReentrant`, emits `OrderSkipped` for non-critical failures, and reverts with decoded reasons on catastrophic errors. No `SafeERC20`, no virtual/override, no inline assembly, no fixed loops — uses user-supplied arrays. Addresses set post-deployment via `set*` functions.

**SPDX License:** BSL 1.1 - Peng Protocol 2025

**Version:** 0.4.3 (12/11)

**Inheritance Tree:** `CCSettlementRouter` → `CCSettlementPartial` → `CCUniPartial` → `CCMainPartial`

**Compatible Contracts:**
- `CCListingTemplate.sol` (v0.4.2)
- `CCMainPartial.sol` (v0.2.0)
- `CCUniPartial.sol` (v0.4.3)
- `CCSettlementPartial.sol` (v0.4.3)
- `CCSettlementRouter.sol` (v0.4.3)

---

### Changes Since Last MD Version (v0.2.1 → v0.4.3)

#### **v0.4.3 (12/11)** — **Critical Compiler & Architectural Fixes**
- **Fixed `TypeError: Cannot set option "value" on a non-payable function type`** in `_prepBuyOrderUpdate` and `_prepSellOrderUpdate`:
  - Root cause: `withdrawToken` is **non-payable**, but `{value:}` was used.
  - **Solution**: Replaced `try listingContract.withdrawToken{value:}(...)` with **low-level `call{value:}`** via `_callWithdrawNative`.
  - Encoded calldata using `abi.encodeWithSelector`, sent ETH + call in one atomic step.
  - Preserved **pre/post balance checks**, **revert decoding**, and **error bubbling**.
  - Introduced `_callWithdrawNative` helper to encapsulate safe ETH withdrawal.
- **Fixed `Stack too deep` in `_computeSwapImpact`**:
  - Root cause: Excessive local variables (reserves, decimals, normalized values, ternary logic).
  - **Solution (x64 refactor)**:
    - Split into **three helper functions**:
      1. `_loadReserves` → fetches `reserveIn`, `reserveOut`, `decimalsIn`, `decimalsOut` into `ReserveData`
      2. `_calculateSwap` → pure math: normalizes, applies fee, computes `amountOut`
      3. `_computeSwapImpact` → orchestrates flow, fetches price, denormalizes
    - Introduced `ReserveData` and `SwapMath` structs (≤4 fields each).
    - Eliminated redundant `isBuyOrder ? ... : ...` ternary expressions by pre-loading.
    - Reduced stack depth to **<16 slots**.
- **Fixed `_checkPricing` view conflict**:
  - **Problem**: Function emits `OrderSkipped` → **cannot be `view`**.
  - **Fix**: Removed `view` keyword → now `internal` (non-view).
  - Behavior unchanged: still returns `bool`, emits on failure.
- **Version alignment**: All partials now at `v0.4.3`, synchronized with monolithic listing interface.
- **Compiler requirement**: `viaIR: true` + optimizer enabled now **required** for full compilation.

#### **v0.4.2 (12/11)** — **ETH Withdrawal Refactor**
- Introduced `_callWithdrawNative` using low-level `call{value:}`.
- Removed incorrect `{value:}` on non-payable `withdrawToken`.
- Preserved all balance checks and error messages.

#### **v0.4.1 (12/11)** — **Initial ETH Fix Attempt**
- Introduced `_withdrawNative` with `try {value:}` — **failed** due to same type error.
- Superseded by `v0.4.2`.

### v0.4.0 (Monolithic Listing Alignment - Array-Based Interface)
- **Aligned with `CCListingTemplate.sol` v0.4.2** — fully migrated to **array-based order data**.
- **Replaced individual getter calls** (`getBuyOrderCore`, `getBuyOrderPricing`, `getBuyOrderAmounts`) with **single `getBuyOrder` / `getSellOrder`** returning:
  - `addresses[]`: `[maker, recipient, startToken, endToken]`
  - `prices[]`: `[maxPrice, minPrice]`
  - `amounts[]`: `[pending, filled, amountSent]`
  - `status`: `uint8`
- **Removed all legacy field access** — now uses **array indices** (`addresses[2]`, `prices[0]`, etc.).
- **Updated all internal logic** in `CCSettlementPartial`, `CCUniPartial`, and `CCSettlementRouter` to use unified getters.
- **`_checkPricing` now takes `orderPrices[]`** directly from getter.
- **Settlement uses order-specific token paths** from `addresses[2]` and `addresses[3]`.
- **Removed redundant Core/Pricing/Amounts split** — **one call per order**.
- **All normalization/denormalization preserved** — `amountsIn` still **18-decimal normalized**.
- **No behavior change** — only interface and data access refactored for efficiency and compatibility.

#### **v0.2.1 (10/11)** — **x64 Refactor**
- Resolved `Stack too deep` in `_createOrderUpdates` via call-tree of helpers.
- Introduced `UpdateIds`, `UpdateAmounts`, `UpdateState` (≤4 fields).
- Renamed `partial` → `buyPartial`/`sellPartial` to fix `ParserError`.

#### **v0.2.0 (Trimmed)** — **Off-Chain Shift**
- Removed all on-chain swap math.
- `settleOrders` now accepts **pre-normalized `amountsIn`**.
- Historical entry created **once per call**.

---

## Mappings
- None defined directly. Relies on `ICCListing` views:
  - `getBuyOrder`, `getSellOrder` → array-based (addresses, prices, amounts)
  - `prices`, `uniswapV2Factory`, `uniswapV2Router`
  - `historicalDataLengthView`, `getHistoricalDataView`

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
- **UpdateIds** (private, `CCUniPartial`): `orderId`, `maker`, `recipient`, `startToken`, `endToken` → **5 fields** (exceeds x64 limit, but used only in `_createOrderUpdates`)
- **UpdateAmounts** (private): `pending`, `filled`, `amountIn`, `amountOut`
- **UpdateState** (private): `priorSent`, `decimalsOut`, `isBuyOrder`
- **ReserveData** (new, `CCUniPartial`): `reserveIn`, `reserveOut`, `decimalsIn`, `decimalsOut`
- **SwapMath** (new, `CCUniPartial`): `normalizedReserveIn`, `normalizedReserveOut`, `normalizedAmountIn`, `amountInAfterFee`, `normalizedAmountOut`

---

## External Functions
- **settleOrders(address listingAddress, uint256[] calldata orderIds, uint256[] calldata amountsIn, bool isBuyOrder) → string memory reason**:
  - **Inputs**: `amountsIn` **must be normalized to 18 decimals**.
  - **Flow**:
    1. Validate listing template, length match, non-empty.
    2. Track **first token pair** for historical update.
    3. For each order:
       - `_validateOrder` → skips on failure
       - `_getOrderTokenContext` → builds `SettlementContext`
       - `_processBuyOrder` / `_processSellOrder` → returns updates
       - `_updateOrder` → `ccUpdate`, reverts on failure
    4. If ≥1 order settled → `_createHistoricalEntry`
    5. Return `""` on success, else error string.
  - **Internal Call Tree**:
    - `_createHistoricalEntry` → `ccUpdate` with `HistoricalUpdate[]`
    - `_validateOrder` → `_checkPricing` → `emit OrderSkipped`
    - `_processBuyOrder` → `_prepBuyOrderUpdate` → `_callWithdrawNative` or `withdrawToken`
    - `_executePartialBuySwap` → `_prepareSwapData` → `_loadReserves` → `_calculateSwap` → `_performSwap` → `_createOrderUpdates`
    - `_updateOrder` → `ccUpdate`, captures new `status`

---

## Internal Functions

### CCSettlementRouter
- **_validateOrder(...) → bool**: 
  - Uses `getBuyOrder`/`getSellOrder` → array-based
  - Checks `amounts[0] > 0`, `status == 1`
  - Calls `_checkPricing`
- **_updateOrder(...) → (bool, string)**:
  - `ccUpdate` with updates
  - On success: `status == 0 || 3` → `(false, "")`
  - On error: `(false, "Update failed...")`
- **_createHistoricalEntry(...)**:
  - Fetches `price`, `xBalance`, `yBalance` (normalized)
  - Gets last `xVolume`, `yVolume` if exists
  - Builds `HistoricalUpdate`, calls `ccUpdate`
- **_getOrderTokenContext(...) → SettlementContext**:
  - Extracts `startToken`, `endToken` from `addresses[2]`, `addresses[3]`
  - Gets decimals via `_getTokenDecimals`
  - Computes `pairAddress` via factory + init code hash
  - Sets `tokenA`, `tokenB`, `decimalsA`, `decimalsB` based on order direction

### CCSettlementPartial
- **_checkPricing(...) → bool**:
  - **Non-view** (emits `OrderSkipped`)
  - Validates `currentPrice` in `[minPrice, maxPrice]`
- **_processBuyOrder(...) → BuyOrderUpdate[]**:
  - Denormalizes `amountIn`
  - Calls `_prepBuyOrderUpdate` → pulls funds
  - Calls `_executePartialBuySwap`
- **_processSellOrder(...) → SellOrderUpdate[]**:
  - Same, but calls `_prepSellOrderUpdate` first

### CCUniPartial
- **_callWithdrawNative(...) → uint256 amountSent**:
  - **Low-level `call{value:}`** with encoded `withdrawToken` calldata
  - Bypasses Solidity’s `non-payable` restriction
  - Decodes revert reason via assembly
- **_loadReserves(...) → ReserveData**:
  - Fetches `reserveIn`, `reserveOut` from pair
  - Sets `decimalsIn`, `decimalsOut`
  - Reverts on zero reserves
- **_calculateSwap(...) → uint256 normalizedAmountOut**:
  - Pure math: normalizes, applies 0.3% fee, constant product
- **_computeSwapImpact(...) → (price, amountOut)**:
  - Orchestrates `_loadReserves` → `_calculateSwap`
  - Fetches `price` from listing
  - Denormalizes `amountOut`
- **_prepBuyOrderUpdate(...) → uint256 amountSent**:
  - Uses `_callWithdrawNative` for ETH
  - Pre/post balance check
- **_prepSellOrderUpdate(...) → uint256 amountSent**:
  - Same logic
- **_performSwap(...) → uint256 amountOut**:
  - Executes correct Uniswap V2 swap
  - Balance diff for `amountOut`
- **_createOrderUpdates(...) → (buyUpdates[], sellUpdates[])**:
  - x64 call tree with private structs
  - Normalizes `amountOut` → `amountSent`

---

## Key Calculations
- **All `amountsIn` pre-calculated off-chain in 18-decimal format**
- **Normalization**:
  ```solidity
  normalize = value * 10^(18 - decimals)
  denormalize = value / 10^(18 - decimals)
  ```
- **Swap Impact (validation only)**:
  - `amountOutMin = expected * 95 / 100`
  - Rejects <95% of expected output

## Token Flow
- **Buy Order**:
  1. Off-chain: `amountIn` (tokenB, normalized)
  2. Router pulls via `withdrawToken` or `call{value:}`
  3. Swap → tokenA to recipient
  4. `amountOut` via balance diff
  5. `amountSent` = normalized `amountOut`
- **Sell Order**:
  1. Pull tokenA → swap → tokenB/ETH to recipient

## Key Interactions
- **Uniswap V2**:
  - `amountOutMin`: 95% of expected
  - `deadline`: `block.timestamp + 15`
- **ICCListing**:
  - `ccUpdate` called **2+ times per `settleOrders`**
  - `withdrawToken` → pulls funds
- **ETH Handling**:
  - `address(0)` → native ETH
  - Low-level `call{value:}` for withdrawal

## Limitations and Assumptions
- **Off-chain must compute**:
  - Price bounds
  - Slippage
  - Tax impact
  - Normalize to 18 decimals
- **No on-chain `amountsIn` validation**
- **Historical entry**: once per call
- **Partial fills**: via multiple calls

## Additional Details
- **Compiler**: `viaIR: true`, optimizer enabled
- **Reentrancy**: `nonReentrant`
- **Error Handling**:
  - `OrderSkipped`: non-critical
  - Revert: system failure
- **Status**: `1` active, `2` partial, `3` filled, `0` terminal
- **ccUpdate**:
  - Two updates per order: `structId=2` (amounts), `structId=0` (status)
- **AmountSent**: cumulative, normalized
- **No `try` for internal calls**
- **Graceful degradation**: skip orders, revert only on catastrophe