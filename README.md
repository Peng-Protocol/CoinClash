# Overview
CoinClash is a decentralized limit-order trading platform built on Uniswap V2 for price discovery and swap execution. The system supports **range-bound orders**, **partial fills**, **dynamic fee scaling**, and **per-pair historical data** while maintaining gas-efficient batch processing. All core functionality is now consolidated into a **monolithic architecture** centered on `CCListingTemplate` and `CCLiquidityTemplate`, eliminating multi-contract agents and per-listing proxies.

## System Summary
The platform operates through a **single `CCListingTemplate`** per token pair, which serves as the canonical order book and state tracker. Users interact via **four specialized routers**:

| Router | Purpose |
|--------|---------|
| `CCOrderRouter` | Create, cancel, and batch-cancel limit orders |
| `CCSettlementRouter` | Settle pending orders using Uniswap V2 swaps with pre-normalized `amountsIn` |
| `CCLiquidRouter` | Settle orders using internal liquidity with dynamic fees (0.05% → 50%) |
| `CCLiquidityRouter` | Deposit, withdraw, claim fees, and reassign depositor slots |

`CCListingTemplate` stores:
- Buy/sell orders in array-based structs (`addresses[]`, `prices[]`, `amounts[]`)
- Pending order ID arrays (`_pendingBuyOrders`, `_pendingSellOrders`)
- Maker-specific pending lists (`makerPendingOrders`)
- Per-pair historical data (`_historicalData[tokenA][tokenB]`)
- Real-time price via direct `IERC20.balanceOf` on the Uniswap V2 pair

`CCLiquidityTemplate` manages:
- Token-agnostic liquidity pools keyed by `address token`
- Slot-based depositor tracking with normalized allocations
- Fee accumulation and pro-rata claims
- Emergency withdrawal via `withdrawToken`

All amounts are **normalized to 1e18** using `normalize()` / `denormalize()` helpers. Transfers use **pre/post balance checks** to support tax-on-transfer tokens. External calls are wrapped in `try/catch` with detailed event emissions for **graceful degradation**.

*Pending*: The following contracts implement leverage trading via AAVE "debt looping". They are under active development and not yet functional.
- `UAEntryDriver`
- `UAExitDriver`
- `UALiquidationDriver`
- `UAExecutionDriver`
- `UAStorage`

---

# CCListingTemplate

## Description
The `CCListingTemplate` is the **central state authority** for a token pair. It tracks orders, volumes, and historical snapshots using **array-based order structs** and **per-pair mappings**. Price is derived live from the Uniswap V2 pair via `balanceOf`.

## Key Features
- **Array-Based Orders**:  
  ```solidity
  addresses: [maker, recipient, startToken, endToken]
  prices:    [maxPrice, minPrice]
  amounts:   [pending, filled, amountSent]
  ```
- **Status Codes**:  
  `0` = cancelled, `1` = pending, `2` = partial, `3` = filled
- **Volume Tracking**:  
  `xVolume` = cumulative `amountSent` (output token)  
  `yVolume` = cumulative `filled` (input token)
- **Historical Data**:  
  Appended via `HistoricalUpdate[]` in `ccUpdate`. One entry per settlement batch per pair.
- **Price Query**:  
  ```solidity
  price = (normalize(balanceB, decimalsB) * 1e18) / normalize(balanceA, decimalsA)
  ```
- **Pagination**:  
  `makerPendingOrdersView`, `pendingBuyOrdersView` support `step` + `maxIterations`

---

# CCOrderRouter

## Description
User-facing interface for **order creation and cancellation**. Transfers funds to the router, validates Uniswap pair liquidity, and submits batch updates to `CCListingTemplate`.

## Key Functions
- `createBuyOrder()` / `createSellOrder()` → payable, supports ETH or ERC20
- `clearSingleOrder(orderId, isBuy)`
- `clearOrders(maxIterations)` → batch cancel from `makerPendingOrdersView`

## Flow
1. Validate pair exists + reserves > 0
2. Transfer input → router (pre/post balance)
3. Normalize received amount
4. Build 3 `BuyOrderUpdate` structs
5. `ccUpdate()` → order ID from `nextOrderId`

---

# CCSettlementRouter

## Description
Settles orders using **Uniswap V2 swaps** with **off-chain pre-calculated `amountsIn`** (18-decimal normalized). No on-chain slippage math — all impact validation uses available Uniswap v2 balances.

## Key Interactions
- Pulls funds via `withdrawToken` or low-level `call{value:}` (ETH)
- Executes `swapExactTokensForTokens` with `amountOutMin = expected * 95 / 100`
- Updates order via `ccUpdate` (Amounts + Status)
- Creates one `HistoricalUpdate` per unique pair per batch

- **Pagination:** Processes exact IDs — no iteration caps.

- **Partial Fills:**
  - Limited by `maxAmountIn` = min(pending, price-adjusted, reserveIn)
  - `amountSent` = post-swap balance diff (recipient)
  - Status → `2` if `pending > 0`

---

# CCLiquidRouter

## Description
Settles orders using **internal liquidity** (CCLiquidityTemplate) with **dynamic fees** based on usage percent:
- ≤1% → 0.05%
- 2% → 0.10%
- 10% → 0.50%
- 100% → 50% max

## Key Interactions
- Validates price within 10% of Uniswap
- Checks `liquidIn ≥ pending`, `liquidOut ≥ expectedOut`
- Ensures `uniswapBalance(output) ≤ internalLiquidity` (The internal liquidity must be greater than the Uni-v2 liquidity for liquid settlement to execute).
- Deducts fee → `ICCLiquidity.ccUpdate(updateType=1)`
- Transfers output → recipient
- Updates order + historical data

- **Pagination:** Iterates `makerPendingOrdersView` from `step`.

- Token agnostic, settles all pending orders for all orders of various pairs.

---

# CCLiquidityRouter

## Description
Manages **liquidity deposits, withdrawals, and fee claims** in `CCLiquidityTemplate`. Fully **token-agnostic** — no x/y duality.

## Key Functions
- `depositNativeToken`, `depositToken`
- `withdraw(listing, token, compensationToken, outputAmount, compensationAmount, index)`
- `claimFees(token, liquidityIndex)`
- `changeDepositor(token, slotIndex, newDepositor)`

## Compensation Logic
- `compensationAmount` converted to primary token equivalent using `ICCListing.prices()`
- Total allocation deduction = `output + (comp * 1e18 / price)`
- Actual transfers are independent (denormalized)

---

# Deployment & Upgrades

## Initial Deployment
1. Deploy `CCListingTemplate` and `CCLiquidityTemplate` for all pairs.
2. Set `uniswapV2Factory`, deploy and set `registryAddress`, `globalizerAddress` via owner functions
3. Deploy and set routers via `addRouter()`. 
4. Setup `CCListingTemplate` and `CCLiquidityTemplate` addresses in routers. 

## Upgrades
- **Router reset**: Routers can be added or removed freely by the contract owner to adjust their functionality. 

No proxy patterns. 

---

# Security & Design Principles

- **Reentrancy**: `nonReentrant` on all external entrypoints
- **Graceful Degradation**: `try/catch` + detailed events, never silent fail
- **No SafeERC20**: Direct calls + balance checks
- **No Virtual/Override**
- **No Inline Assembly**
- **User-Controlled Loops**: `maxIterations`, `step`
- **Pre/Post Balance Checks**: Tax token compatible
- **Explicit Casting**
- **Normalized Accounting**: All internal math in 1e18

---

# Token Flow Examples

## Buy Order (TokenB → TokenA)
1. User sends TokenB → `CCOrderRouter`
2. `CCSettlementRouter` pulls via `withdrawToken`
3. Swap on Uniswap: TokenB → TokenA
4. TokenA sent to recipient
5. `amountSent` = balance diff
6. `ccUpdate`: `filled += input`, `amountSent += output`, `pending -= input`

## Liquidity Withdrawal with Compensation
1. User requests 100 normalized TokenA + 50 normalized TokenB
2. Price: 1 TokenB = 2 TokenA → 50 TokenB = 100 TokenA equiv
3. Total deduction: 200 normalized
4. Transfer 100 TokenA + 50 TokenB independently
5. `ccUpdate(updateType=2)` deducts 200 from slot

---

# Pagination & Gas Control

| View | Pagination |
|------|------------|
| `makerPendingOrdersView` | `step` + implicit length |
| `clearOrders(maxIterations)` | User caps |
| `settleBuyLiquid(step)` | Starts at index `step` |
| `getListingsByLister` | `maxIterations` |

All loops respect user limits. No fixed caps.

---

# Events & Indexing

All events indexed by:
- `token` (liquidity)
- `maker`, `orderId` (orders)
- `depositor`, `slotIndex` (slots)