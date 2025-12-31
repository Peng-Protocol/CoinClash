# CCIsolated Driver Documentation (v0.0.2)

The **CCIsolated Driver** is a decentralized synthetic leverage trading contract designed for isolated margin positions. It interfaces with Uniswap V2 pairs for price discovery and utilizes a specialized liquidity and fee template system for settlement.

---

## 1. Core Concepts

### Margin Structure

* **Initial Margin:** The total amount of Token-1 (Quote Asset) provided by the user.
* **Taxed Margin:** The remaining margin after the entry fee is deducted. This serves as the collateral for the position.
* **Excess Margin:** Additional buffer funds provided by the user to lower the liquidation price without increasing the position size.

### Fees

Fees are calculated based on leverage to ensure higher-risk positions contribute more to the protocol:

* **Fee Ratio:** `(Leverage - 1) / 100`
* **Entry Fee:** `Initial Margin * Fee Ratio`
* All entry fees are immediately transferred to the `FeeTemplate` upon position initiation.

### Pricing Mechanism

Prices are derived from Uniswap V2 Reserves:

* `Price = Reserve1 / Reserve0` (Standardized to 18 decimals).
* All positions are denominated in Token-1 (Quote Asset) relative to Token-0 (Base Asset).

---

## 2. Position Lifecycle

### Entry

Users can enter positions via `enterLong` or `enterShort`.

* **Market Orders:** Set `entryPrice` to `0`. The position opens immediately at the current pool price.
* **Limit Orders:** Set a specific `entryPrice`. The position remains in `Pending` status until `executeEntry` is called at the target price.

### Exit & Automation

Positions are closed through three primary triggers, handled by the `executeExit` function:

1. **Liquidation:** Triggered if the current price crosses the `liquidationPrice`. The `Taxed Margin` is sent to the Liquidity Template, and the maker receives 0.
2. **Take Profit (TP):** Triggered if the price reaches the user's profit target. The position is closed, and profits are settled in the appropriate asset (Token-1 for Longs, Token-0 for Shorts).
3. **Stop Loss (SL):** Triggered if the price reaches the user's risk limit. This acts as a **Cancellation**, refunding the remaining margin to the maker after a holding fee is applied.

### Cancellation

Users can manually cancel `Pending` positions to retrieve their margin. If an `Active` position is cancelled (via SL), a holding fee of **0.1% per hour** is deducted from the refund.

---

## 3. Technical Implementation

### State Management

The contract uses several mappings and counters to track positions:

* `longIdCounter` / `shortIdCounter`: Incremental IDs for every position.
* `positions`: A central mapping of `ID => Position` struct.
* `userLongIds` / `userShortIds`: Used to track positions owned by specific addresses for UI/UX.

### Refactoring for Stack Depth

Due to the complexity of the math and the number of variables required for isolated margin, the contract utilizes:

* **Struct Packing:** `EntryParams` and `EntryContext` are used to pass data between functions to avoid `Stack Too Deep` errors.
* **Internal Routing:** Logic is split into phases (e.g., `_processEntryFunding` -> `_finalizeEntry`) to clear the stack between external calls and storage updates.
* **via-IR:** The contract **must** be compiled using the Solidity IR (Intermediate Representation) pipeline.

---

## 4. Liquidation Math

The liquidation price is calculated to ensure the protocol remains solvent. It determines the point where the `Taxed Margin` plus `Excess Margin` is no longer sufficient to cover the position's leverage ratio.

**Long Liquidation:**
`Price Delta = (Entry Price * Margin Ratio) / 1e18`
`Liquidation Price = Entry Price - Price Delta`

**Short Liquidation:**
`Price Delta = (Entry Price * Margin Ratio) / 1e18`
`Liquidation Price = Entry Price + Price Delta`

---

## 5. Security Features

* **ReentrancyGuard:** Applied to all state-changing external functions.
* **Access Control:** `OwnerOnly` functions manage critical infrastructure like `setFeeTemplate` and `setLiquidityTemplate`.
* **Status Checks:** Functions verify that a position is in the correct state (e.g., `Active` vs `Pending`) before executing logic.

---

## 6. View Functions

The driver provides optimized view functions for frontend integration:

* `positionsByTypeView`: Returns a paginated list of all Long or Short IDs.
* `positionsByAddressView`: Returns a paginated list of IDs belonging to a specific user.
* `positionByIndex`: Returns the full `Position` struct data.

---

## 7. Dependencies

The `CCIsolatedDriver.sol` is designed specifically to act as the "brains" or the execution layer for the `TypeCLiquidity` and `TypeCFees` templates. The integration is tight and follows a clear separation of concerns: the Driver manages position logic, while the templates manage the actual asset pools.

### **1. Integration with TypeCFees (Fee Management)**

The Driver interacts with `TypeCFees` primarily during the **Entry** and **Cancellation** phases of a position.

* **Entry Fee Capture:** When a user calls `enterLong` or `enterShort`, the Driver calculates the fee based on the leverage multiplier. It then calls `feeTemplate.addFees`.
* *Mechanism:* The Driver uses `transferFrom` to pull the fee from the user, then approves `TypeCFees` to pull the fee tokens and calls `addFees` which notifies the template to update its internal `pairFees` and `feesAcc` mappings.

* **Holding Fee Logic:** During a Stop Loss or manual cancellation of an active position, the Driver calculates a "Holding Fee" (0.1% per hour). This fee is also routed to the `feeTemplate`, ensuring that even unsuccessful trades contribute to the protocol's revenue stream.

### **2. Integration with TypeCLiquidity (Settlement Layer)**

The Driver treats `TypeCLiquidity` as the ultimate counterparty for all trades. The integration relies on the `ssUpdate` pattern.

* **Losses (Liquidation/Negative Trades):** When a position is liquidated or closed at a loss, the Driver transfers the remaining "Taxed Margin + Excess Margin" from its own balance to the `TypeCLiquidity` contract.
* **Wins (Payouts):** If a user closes a position in profit, the Driver does not pay the user directly from its own holdings. Instead, it generates a `SettlementUpdate` struct and calls `liquidityTemplate.ssUpdate` while also transferring the "Taxed Margin + Excess Margin" to the `TypeCLiquidity` contract.

* *The "Router" Privilege:* For this to work, the `CCIsolatedDriver` **must** be added to the `routers` mapping in the `TypeCLiquidity` contract. This allows the Driver to authorize the release of pool funds to the winning trader.

### **3. Operational Workflow Summary**

| Action | Driver Interaction | Template Involved | Asset Flow |
| --- | --- | --- | --- |
| **Open Position** | `addFees()` | `TypeCFees` | User → Fee Template |
| **Liquidation** | `transfer()` | `TypeCLiquidity` | Driver → Liquidity Template |
| **Take Profit** | `ssUpdate()` | `TypeCLiquidity` | Liquidity Template → User |
| **Stop Loss** | `addFees()` | `TypeCFees` | Driver → Fee Template (Holding Fee) |

### **4. Potential Integration Risks**

* **The "Router" Requirement:** If the Driver address is not manually whitelisted as a "router" in both the Fee and Liquidity templates after deployment, all settlement calls (`ssUpdate` and `addFees`) will revert.
* **Canonical Ordering:** `TypeCFees` uses canonical ordering (address comparison) to track pair fees. The Driver ensures it passes `token0` and `token1` correctly to avoid fragmented fee data, the current implementation handles this via the Uniswap Pair address lookup.

### **Correct Fee Flow Breakdown**

1. **User → Driver (`transferFrom`):**
The Driver first pulls the `initialMargin` from the user into its own balance using `_transferIn`.

2. **Driver Approval:**
The Driver calculates the `feeAmount` and grants the `TypeCFees` contract an allowance to spend those tokens.

3. **Driver → Fee Template (`addFees`):**
The Driver calls `addFees` on the `TypeCFees` contract. The `TypeCFees` contract then uses `transferFrom` to pull the tokens **from the Driver** into its own storage.