# Overview
CoinClash is a decentralized limit-order trading platform built on Uniswap V2 for price discovery and swap execution. The system supports **range-bound orders**, **partial fills**, **dynamic fee scaling**, and **per-pair historical data** while maintaining gas-efficient batch processing. All core functionality is now consolidated into a **monolithic architecture** centered on `CCListingTemplate`, eliminating multi-contract agents and per-listing proxies.

# Type-A : Range Orders
The platform operates through a **single `CCListingTemplate`** per token pair, which serves as the canonical order book and state tracker. Users interact via **four specialized routers**:

| Router | Purpose |
|--------|---------|
| `CCOrderRouter` | Create, cancel, and batch-cancel limit orders |
| `CCSettlementRouter` | Settle pending orders using Uniswap V2 swaps with pre-normalized `amountsIn` |

`CCListingTemplate` stores:
- Buy/sell orders in array-based structs (`addresses[]`, `prices[]`, `amounts[]`)
- Pending order ID arrays (`_pendingBuyOrders`, `_pendingSellOrders`)
- Maker-specific pending lists (`makerPendingOrders`)
- Per-pair historical data (`_historicalData[tokenA][tokenB]`)
- Real-time price via direct `IERC20.balanceOf` on the Uniswap V2 pair

All amounts are **normalized to 1e18** using `normalize()` / `denormalize()` helpers. Transfers use **pre/post balance checks** to support tax-on-transfer tokens. External calls are wrapped in `try/catch` with detailed event emissions for **graceful degradation**.

---

## CCListingTemplate

### Description
The `CCListingTemplate` is the **central state authority** for a token pair. It tracks orders, volumes, and historical snapshots using **array-based order structs** and **per-pair mappings**. Price is derived live from the Uniswap V2 pair via `balanceOf`.

### Key Features
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

## CCOrderRouter

### Description
User-facing interface for **order creation and cancellation**. Transfers funds to the router, validates Uniswap pair liquidity, and submits batch updates to `CCListingTemplate`.

### Key Functions
- `createBuyOrder()` / `createSellOrder()` → payable, supports ETH or ERC20
- `clearSingleOrder(orderId, isBuy)`
- `clearOrders(maxIterations)` → batch cancel from `makerPendingOrdersView`

### Flow
1. Validate pair exists + reserves > 0
2. Transfer input → router (pre/post balance)
3. Normalize received amount
4. Build 3 `BuyOrderUpdate` structs
5. `ccUpdate()` → order ID from `nextOrderId`

---

## CCSettlementRouter

### Description
Settles orders using **Uniswap V2 swaps** with **off-chain pre-calculated `amountsIn`** (18-decimal normalized). No on-chain slippage math — all impact validation uses available Uniswap v2 balances.

### Key Interactions
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

## Deployment & Upgrades

### Initial Deployment
1. Deploy `CCListingTemplate` for all pairs.
2. Set `uniswapV2Factory`, deploy and set `registryAddress`, `globalizerAddress` via owner functions
3. Deploy and set routers via `addRouter()`. 
4. Setup `CCListingTemplate` addresses in routers. 

### Upgrades
- **Router reset**: Routers can be added or removed freely by the contract owner to adjust their functionality. 

No proxy patterns. 

---

## Security & Design Principles

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

## Token Flow Examples

## Buy Order (TokenB → TokenA)
1. User sends TokenB → `CCOrderRouter`
2. `CCSettlementRouter` pulls via `withdrawToken`
3. Swap on Uniswap: TokenB → TokenA
4. TokenA sent to recipient
5. `amountSent` = balance diff
6. `ccUpdate`: `filled += input`, `amountSent += output`, `pending -= input`

---

## Pagination & Gas Control

| View | Pagination |
|------|------------|
| `makerPendingOrdersView` | `step` + implicit length |
| `clearOrders(maxIterations)` | User caps |

All loops respect user limits. No fixed caps.

---

## Events & Indexing

All events indexed by:
- `maker`, `orderId` (orders)

---

# Type-B : Debt-Looping Suite

### Description

Type-B is a gas-optimized, monolithic debt-looping system for Aave V3 + Uniswap V2 pairs. It enables users to instantly leverage up or unwind positions in a single transaction without the need for flash loans. The suite supports dynamic asset pairs through a single driver and a dedicated limit order executor.

### Key Components

* **`UADriver`**: The core execution engine. It is a monolithic contract that automates the borrow → swap → supply cycle.
  * **Dynamic Pairs**: It handles any valid Aave/Uniswap asset pair dynamically.
  * **`executeLoop()`**: Performs a one-transaction leveraged entry with user-defined minimum Health Factor (HF) and slippage.
  * **`unwindLoop()`**: Executes a one-transaction deleveraging/exit by repaying debt and withdrawing collateral.


* **`UAExecutor`**: The limit order layer for the debt-looping suite. It manages the lifecycle of automated positions.
  * **`createOrder()`**: Allows users to set a "Wind Order" (entry) that triggers when a specific price condition is met.
  * **Take Profit (TP) & Stop Loss (SL)**: Supports automated unwinds. Users can set TP/SL orders that monitor price movements and trigger `unwindLoop` on the driver.
  * **Position Tracking**: Manages position states (Pending, Active, Closed, Cancelled) and maps them to specific makers.

### Execution Flow

1. **Creation**: User calls `UAExecutor.createOrder()` with collateral, target leverage, and an entry price.
2. **Pending**: The position is stored as `Status.PENDING` until the price condition is met.
3. **Wind**: An off-chain bot or user calls `executeOrders()`. `UAExecutor` pulls the collateral and calls `UADriver.executeLoop()`.
4. **Active**: Upon successful execution, the position becomes `Status.ACTIVE`. Users can now set or update `setTP()` and `setSL()` triggers.
5. **Unwind**: When a TP/SL price is hit, `executeUnwinds()` is called, which triggers `UADriver.unwindLoop()` to close the position and return remaining assets to the maker.

---

### Logic & Gas Control

| Feature | Implementation |
| --- | --- |
| **Slippage** | Enforced at the `UADriver` level via `maxSlippageBps`. |
| **Safety** | Minimum Health Factor (default 1.05) is validated after every loop cycle. |
| **Efficiency** | Dynamic approvals (`_approveIfNeeded`) minimize gas costs for recurring pairs. |
| **Automation** | `UAExecutor` uses mapping-based tracking for gas-efficient lookups of TP/SL orders. |

---

Read more about Type-B in the [UA-Documentation](https://github.com/Peng-Protocol/CoinClash/blob/main/Type-B/UA-Documentation.md).