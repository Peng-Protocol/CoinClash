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

# Type-B: Euler V2 Debt-Looping Suite

## Description

Type-B is a gas-optimized, monolithic debt-looping system integrated with **Euler V2** and **Uniswap V2**. It enables users to instantly create leveraged collateral positions or unwind them in a single transaction. Unlike traditional looping methods that may require flash loans, this suite automates the borrow-swap-supply cycle directly through Euler’s modular vault architecture.

## Key Components

* **`UEDriver`**: The core execution engine designed for Euler V2.
  * **Vault-Centric Design**: Operates across any valid pair of Euler Vaults (Collateral Vault and Borrow Vault).
  * **`executeLoop()`**: Performs a multi-cycle leveraged entry. It borrows from the debt vault, swaps for collateral via Uniswap V2, and deposits back into the collateral vault until the target leverage is reached.
  * **`unwindLoop()`**: Executes a "Flash Unwind" by withdrawing collateral, swapping it for the debt asset, and repaying the outstanding balance to deleverage the position.
  * **Safety Engine**: Dynamically calculates borrow amounts based on vault-specific LTV and liquidation thresholds while enforcing a minimum Health Factor (HF).


* **`UEExecutor`**: The automation and limit order layer for the Euler suite.
  * **Custodial Position Management**: Holds collateral in a monolithic model, allowing for precise execution of "Wind Orders" (entries) based on Uniswap V2 price triggers.
  * **Automated TP/SL**: Supports Take Profit (TP) and Stop Loss (SL) triggers that monitor price movements and automatically trigger the `UEDriver` to close positions.
  * **Position Lifecycle**: Tracks state transitions from `PENDING` to `ACTIVE`, and finally to `CLOSED` or `CANCELLED`.



## Execution Flow

1. **Creation**: A user calls `UEExecutor.createOrder()`, depositing initial collateral and defining target leverage and an entry price trigger.
2. **Pending**: The position remains `PENDING` in the executor contract.
3. **Wind**: Once the Uniswap V2 price condition is met, `executeOrders()` is called. The executor passes the collateral to the `UEDriver`, which performs the recursive looping.
4. **Active**: The position becomes `ACTIVE`. The executor tracks the updated debt and collateral balances. Users can then set `setTP()` or `setSL()` orders.
5. **Unwind**: When a target price is hit, `executeUnwinds()` triggers the `UEDriver.unwindLoop()`. The system repays the debt, withdraws the remaining collateral, and returns the net assets to the user.

---

## Logic & Gas Control

| Feature | Implementation |
| --- | --- |
| **Leverage Cap** | Supports up to 10x leverage, subject to Vault LTV constraints. |
| **Loop Efficiency** | Capped at a maximum of 10 cycles per transaction to prevent out-of-gas errors. |
| **Slippage Protection** | Enforced at the `UEDriver` level for all Uniswap swaps. |
| **Price Discovery** | Uses direct Uniswap V2 pair reserve checks for limit order triggers. |
| **Euler Integration** | Built to interface with the Euler Vault Connector (EVC) and standard Euler V2 Vaults. |

---

Read more about Type-B in the [UE-Documentation](https://github.com/Peng-Protocol/CoinClash/blob/main/Type-B/UE-Documentation.md).

---

# **Type-C : Synthetic Leverage**

Type-C is a decentralized synthetic leverage trading engine, it exists to facilitate short term high leverage positions which Type-B may not always be able to provide. It utilizes **Drivers** to manage position lifecycles and **Templates** for deep liquidity and fee distribution.

## **1. The Driver Layer (Execution)**

The platform utilizes two distinct driver models to handle market and limit orders via Uniswap V2 price discovery:

* **Isolated Driver:** Manages independent positions where collateral is locked per trade, featuring `taxedMargin` (leverage backing) and `excessMargin` (safety cushion).


* **Cross Driver:** Implements a universal account model using a single **Base Token** (e.g., USDC). It enables a shared margin pool where `userBaseMargin` protects all active positions from liquidation simultaneously.

## **2. The Template Layer (Settlement & Revenue)**

All drivers settle through a modular template system:

* **TypeCLiquidity:** Acts as the counterparty for all trades. It manages multi-token pools, handles normalized 18-decimal accounting, and creates payouts via `ssUpdate` for authorized drivers.


* **TypeCFees:** Collects and tracks protocol revenue using canonical token ordering. It enables distribution of fees to liquidity providers based on pro-rata snapshots taken at the time of deposit.

## **3. Operational Workflow**

| Action | Component | Logic |
| --- | --- | --- |
| **Position Entry** | Driver | Pulls Initial + Excess Margin; routes fees to `TypeCFees`. |
| **Price Trigger** | Uniswap V2 | Uses `getReserves` to activate limit orders or trigger liquidations. |
| **Liquidation** | Driver → Liquidity | Seizes margin and transfers it to the `TypeCLiquidity` vault. |
| **Settlement** | Liquidity → User | Disburses profit/margin in the appropriate asset (Isolated) or Base Token (Cross).|