# CCOrderRouter Contract Documentation

## Overview
The `CCOrderRouter` contract, implemented in Solidity (`^0.8.2`), serves as the primary user-facing entry point for **creating**, **cancelling**, and **batch-cancelling** buy/sell orders in a decentralized limit-order trading system. It inherits from `CCOrderPartial` (v0.2.0), which extends `CCMainPartial` (v0.2.0), and integrates tightly with a **monolithic listing template** (`CCListingTemplate.sol` v0.4.2) via the `ICCListing` interface. The contract **no longer handles liquidity routing or liquidation payouts** — all such functionality has been **removed** from this file. `ICCLiquidity` interface and related logic (payouts, liquidity checks, `settleLongLiquid`, etc.) are **temporarily absent** but **will be reintroduced later** as `CCMainPartial` is a **shared utility base** across multiple routers (order, liquidity, payout).

**SPDX License:** BSL 1.1 - Peng Protocol 2025

**Version:** 0.2.0 (Updated 11/11/2025)

**Inheritance Tree:** `CCOrderRouter` → `CCOrderPartial` → `CCMainPartial` → `ReentrancyGuard`

**Compatibility:**
- `CCListingTemplate.sol` (v0.4.2)
- `CCOrderPartial.sol` (v0.2.0)
- `CCMainPartial.sol` (v0.2.0)
- `IERC20.sol` (standard)
- `ReentrancyGuard.sol` (OpenZeppelin-style, owns `Ownable`)

---

## Key Changes Since Last MD Version (v0.1.5 → v0.2.0)

| Category | Change |
|--------|-------|
| **Core Architecture** | Complete refactor to support **monolithic listing template** (`CCListingTemplate.sol` v0.4.2). Removed dependency on `ICCAgent`, `CCAgent`, and multi-listing logic. Now uses **single `listingTemplate` address** set post-deployment via `setListingTemplate()`. |
| **Order Creation** | Consolidated four functions (`createTokenBuyOrder`, `createNativeBuyOrder`, `createTokenSellOrder`, `createNativeSellOrder`) into **two unified functions**: `createBuyOrder()` and `createSellOrder()`. Both support **native ETH or ERC20** via `payable` and internal token detection. |
| **Order Structure** | Migrated from individual struct fields to **array-based updates** (`address[]`, `uint256[] prices`, `uint256[] amounts`) matching `CCListingTemplate` v0.4.2. `startToken` and `endToken` are now stored in `addresses[2]` and `addresses[3]`. |
| **Transfer Logic** | Replaced `_checkTransferAmountToken`/`_checkTransferAmountNative` with unified `_validateAndTransfer()` using **pre/post balance checks** for both native and ERC20. Tokens are transferred **to the router**, not directly to listing. |
| **Uniswap Pair Validation** | Added `_validateUniswapPair()` to ensure **pair exists and has liquidity** before order creation. Uses `uniswapV2Factory()` from listing template. Converts `address(0)` → WETH for native token checks. |
| **Cancellation** | `clearSingleOrder()` and `clearOrders(uint256 maxIterations)` now use `makerPendingOrdersView()` and array-based `getBuyOrder()`/`getSellOrder()` to fetch and validate maker ownership. |
| **Removed Functionality** | **All liquidation payout settlement** (`settleLongLiquid`, `settleShortLiquid`, `PayoutContext`, `payoutPendingAmounts`, etc.) has been **removed**. Liquidity routing and payout logic moved to separate `CCLiquidityRouter`. **Note:** `ICCLiquidity` interface and related structs are **temporarily removed** but **will be readded** in future versions as `CCMainPartial` serves as **shared utility** between order and liquidity routers. |
| **State Variables** | Removed: `agent`, `uniswapV2Router`, `payoutPendingAmounts`, `liquidityAddr`. Only `listingTemplate` remains (in `CCMainPartial`). |
| **Interfaces** | Updated `ICCListing` interface to reflect **array-based getters** and `ccUpdate()` batching. **Removed all `ICCLiquidity` references** (temporary — to be reintroduced). |
| **Events** | Removed `PayoutSettled`, `LiquidityUpdated`. Kept only `OrderCreated`, `OrderCancelled`, `TransferFailed`. |
| **Security** | Uses `nonReentrant` on all external functions. No `try/catch` — reverts on failure. Pre/post balance checks prevent tax-token issues. |

---

## State Variables

| Variable | Type | Location | Access | Description |
|--------|------|----------|--------|-----------|
| `listingTemplate` | `address` | `CCMainPartial` | internal | Single monolithic listing template address. Set via `setListingTemplate()` post-deployment. |

---

## Structs

### `OrderPrep` (defined in `CCOrderPartial`)
```solidity
struct OrderPrep {
    address maker;
    address recipient;
    address startToken;
    address endToken;
    uint256 amount;           // normalized to 1e18
    uint256 maxPrice;
    uint256 minPrice;
    uint256 amountReceived;   // actual received (denormalized)
    uint256 normalizedReceived;
}
```
- Used to pass prepared order data into `_executeSingleOrder`.
- `amount` is input normalized via `normalize()`.
- `amountReceived` and `normalizedReceived` set by `_validateAndTransfer()`.

---

## External Functions

### `createBuyOrder(...)` payable
```solidity
function createBuyOrder(
    address startToken,
    address endToken,
    address recipientAddress,
    uint256 inputAmount,
    uint256 maxPrice,
    uint256 minPrice
) external payable nonReentrant
```
- **Purpose**: User pays with `startToken` to buy `endToken`.
- **Flow**:
  1. Validates `startToken != endToken`, not both native.
  2. Calls `_validateUniswapPair(startToken, endToken)` → ensures liquidity.
  3. `_handleOrderPrep()` → normalizes `inputAmount`, validates inputs.
  4. `_validateAndTransfer()` → transfers tokens/ETH **to router**, returns actual received.
  5. `_executeSingleOrder(prep, true)` → builds 3 `BuyOrderUpdate` structs (Core, Pricing, Amounts), calls `listingTemplate.ccUpdate()`.
- **Events**: `OrderCreated(orderId, maker, true)`
- **Reverts**: Invalid tokens, no liquidity, transfer failure, zero received.

---

### `createSellOrder(...)` payable
```solidity
function createSellOrder(
    address startToken,
    address endToken,
    address recipientAddress,
    uint256 inputAmount,
    uint256 maxPrice,
    uint256 minPrice
) external payable nonReentrant
```
- **Purpose**: User sells `startToken` to receive `endToken`.
- **Flow**: Identical to `createBuyOrder`, but uses `SellOrderUpdate[]` and `isBuy = false`.
- **Events**: `OrderCreated(orderId, maker, false)`

---

### `clearSingleOrder(uint256 orderIdentifier, bool isBuyOrder)` nonReentrant
- **Purpose**: Cancels a single order by ID.
- **Flow**:
  1. Calls `_clearOrderData(orderId, isBuy)` in `CCOrderPartial`.
  2. Fetches order via `getBuyOrder()` or `getSellOrder()`.
  3. Validates `addresses[0] == msg.sender`.
  4. Refunds pending amount via `withdrawToken()` or native `call`.
  5. Sets status to `0` (cancelled) via `ccUpdate()`.
- **Events**: `OrderCancelled(orderId, maker, isBuy)`

---

### `clearOrders(uint256 maxIterations)` nonReentrant
- **Purpose**: Batch cancel up to `maxIterations` of `msg.sender`'s pending orders.
- **Flow**:
  1. Fetches `makerPendingOrdersView(msg.sender)` from listing template.
  2. Iterates up to `maxIterations`.
  3. For each ID, checks if buy or sell order and maker matches.
  4. Calls `_clearOrderData()` if valid.
- **Gas Control**: User-defined `maxIterations` prevents gas exhaustion.
- **Events**: `OrderCancelled` per successful cancellation.

---

## Internal Functions

### `_handleOrderPrep(...)` → `OrderPrep`
- Normalizes `inputAmount` using token decimals (18 for native).
- Validates: non-zero maker/recipient, positive amount, different tokens.
- Returns `OrderPrep` with `normalizedAmount`.

### `_validateAndTransfer(...)` → `(uint256, uint256)`
- **ERC20**: Checks allowance, transfers via `transferFrom`, uses **pre/post balance** to get `amountReceived`.
- **Native**: Validates `msg.value == inputAmount`, sets `amountReceived = msg.value`.
- Normalizes received amount → `normalizedReceived`.
- Reverts if `amountReceived == 0`.

### `_validateUniswapPair(address, address)`
- Fetches `uniswapV2Factory()` from `listingTemplate`.
- Maps `address(0)` → WETH.
- Queries `getPair()` → ensures pair exists.
- Calls `getReserves()` → ensures `reserve0 > 0 && reserve1 > 0`.

### `_executeSingleOrder(OrderPrep, bool)`
- Gets `nextOrderId` from listing template.
- Builds **3 updates**:
  - **Core** (`structId: 0`): `addresses[0..3]` = maker, recipient, start, end; `status = 1` (pending)
  - **Pricing** (`structId: 1`): `prices[0] = maxPrice`, `prices[1] = minPrice`
  - **Amounts** (`structId: 2`): `amounts[0] = normalizedReceived`, `amounts[1] = 0`, `amounts[2] = 0`
- Calls `listingTemplate.ccUpdate()` with appropriate buy/sell arrays.

### `_clearOrderData(uint256, bool)`
- Fetches order via `getBuyOrder()` or `getSellOrder()`.
- Validates maker.
- **Refunds** pending amount (`amounts[0]`) if `status == 1 or 2`:
  - Native: `recipient.call{value: denormalizedAmount}`
  - ERC20: `listingTemplate.withdrawToken(token, amount, recipient)`
- Updates status to `0` (cancelled) via `ccUpdate()` with single update.

---

## View Functions

| Function | Returns | Description |
|--------|--------|-----------|
| `listingTemplateView()` | `address` | Returns `listingTemplate` address |

---

## Formulas

### Normalization
```solidity
normalize(amount, decimals) = 
    decimals == 18 → amount
    decimals < 18 → amount * 10^(18 - decimals)
    decimals > 18 → amount / 10^(decimals - 18)
```

### Denormalization
```solidity
denormalize(amount, decimals) = 
    decimals == 18 → amount
    decimals < 18 → amount / 10^(18 - decimals)
    decimals > 18 → amount * 10^(decimals - 18)
```

---

## Security & Design Notes

- **No Reentrancy**: All external functions guarded by `nonReentrant`.
- **Pre/Post Balance Checks**: Used in `_validateAndTransfer` to handle tax-on-transfer tokens.
- **No Try/Catch**: Reverts on failure — no silent failures.
- **Graceful Degradation**: Only reverts on **catastrophic** failure. Refunds always attempted.
- **No Virtual/Override**: Per Trenche 1.2.
- **No SafeERC20**: Direct `IERC20` calls with balance checks.
- **No Caps**: Uses `maxIterations` for user-controlled loops.
- **No Inline Assembly**: Pure Solidity array resizing.
- **No Constructor Args**: `listingTemplate` set via `setListingTemplate()`.

---

## Clarifications

- **Native ETH Handling**: `address(0)` represents native ETH. WETH used only for Uniswap pair validation.
- **Order IDs**: Sequential, fetched via `getNextOrderId()` — no race condition (EVM sequential).
- **Status Codes**:
  - `0` = cancelled
  - `1` = pending
  - `2` = partially filled
  - `3` = filled (not used in router)
- **Amounts Array**:
  - `[0]` = pending
  - `[1]` = filled
  - `[2]` = amountSent (to recipient on fill)
- **Router Holds Tokens**: Tokens transferred to router during order creation. Listing template pulls via `withdrawToken` on fill/cancel.
- **`ICCLiquidity` Temporary Removal**: All references to `ICCLiquidity`, payout structs, and settlement functions are **intentionally removed** in this version to isolate order routing. They **will be readded** in a future update as `CCMainPartial` is **shared infrastructure** between `CCOrderRouter` and `CCLiquidityRouter`.
