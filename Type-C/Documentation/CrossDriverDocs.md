# CCCross Driver Documentation (v0.0.4)

The **CCCross Driver** (Base-Asset Edition) is a synthetic leverage trading engine designed for **Cross-Margin** portfolios. Unlike isolated margin, where collateral is locked per trade, this driver utilizes a single **Universal Base Asset** to back multiple positions simultaneously.

---

## 1. Core Architecture: The Base Asset Model

The primary shift in this driver is the introduction of a **Universal Base Asset** (e.g., USDC or ETH).

* **User Delimited Buckets:** Instead of token-delimited collateral, margin is stored in a global `userBaseMargin` pool.


* 
**Asset Translation:** The contract uses the **Uniswap V2 Factory** to fetch prices and "translate" the value of the `baseToken` into the specific `positionToken` required for a trade (Token-0 for Longs, Token-1 for Shorts).


* **Unified Payouts:** Regardless of the pair being traded, all profits and returned margins are converted back into the `baseToken` for final settlement.



---

## 2. Position Lifecycle

### Entry & Funding

Users specify two margin components in their `EntryParams`:

1. **Initial Margin:** The amount of `baseToken` to be leveraged.
2. 
**Excess Margin:** An optional "cushion" amount in `baseToken`.



**Workflow:**

* The contract withdraws the sum of `Initial + Excess` from the user.


* **Fees:** Calculated as `(Initial Margin * (Leverage - 1)) / 100` and sent to the `FeeTemplate` in `baseToken`.


* **Pending State:** The position remains "Pending" if a limit price is set. During this stage, all margin is stored as `baseToken`.



### Execution (Activation)

When a position is executed (Market or Limit hit):

1. **Margin Conversion:** The `Initial Margin` (minus fees) is converted from `baseToken` to the required `positionToken` using real-time Uniswap reserves.


2. **Excess Routing:** The `excessMargin` is moved from the position struct to the user's global `userBaseMargin` pool.


3. **Leverage:** The `leverageAmount` is now tracked in the units of the `positionToken`.



### Exit (Close & Cancellation)

* **Active Positions:** On closure, the net gains and margin are calculated in the `positionToken`, converted back to `baseToken` at the current rate, and paid out to the user via the `LiquidityTemplate`.


* **Pending Cancellation:** Refunds the full amount of `baseToken` (Initial + Excess).



---

## 3. Cross-Margin Liquidation Logic

Liquidation in the Cross Driver is a "Global Nuke" event. Because positions share a margin pool, one failing trade can liquidate the entire account.

### The Solvency Formula

To determine the liquidation price of a specific position, the contract calculates a **Dynamic Margin Ratio** by considering the user's global pool:
`Total Available (PosToken) = (userBaseMargin * Conversion Rate) + Position Taxed Margin` `Margin Ratio = Total Available / Leverage Amount` 

### The "Nuke" Event

If any single position crosses its liquidation price:

1. **Global Wipe:** The entire `userBaseMargin` (Base Token) is seized and sent to the `LiquidityTemplate`.


2. **Mass Closure:** Every other active position owned by the user (regardless of the pair or token) is forcibly closed with a 100% loss.



---

## 4. Integration with Templates

The Cross Driver maintains the same strict separation of concerns as the Isolated Driver but adapts the currency flow:

| Action | Template | Asset Flow |
| --- | --- | --- |
| **Open Position** | `CCFeeTemplate` | User `baseToken` → Fee Template 

 |
| **Liquidation** | `CCLiquidity` | Global `baseToken` + Position `posTokens` → Liquidity Template 

 |
| **Trade Profit** | `CCLiquidity` | Liquidity Template pays User in `baseToken` 

 |
| **Margin Pull** | N/A | User withdraws `baseToken` from Global Pool 

 |

---

## 5. Administrative & Security Features

* **Owner-Only Base Setter:** The `baseToken` is set once by the owner and serves as the protocol's cornerstone.


* **Dynamic Health Adjustment:** Users can call `addExcessMargin` or `pullMargin` at any time to adjust their global health and move their liquidation prices for all positions simultaneously.


* **Price Safety:** Conversions rely on `getReserves` from Uniswap V2, requiring the existence of a direct pair between the `baseToken` and any traded `positionToken`.

---

## 6. Further Elaboration on Excess and Total Margin

### **A. Storage in the Driver**

* **During Pending State:** When you call `enterLong` or `enterShort`, the `excessMargin` is stored inside the `Position` struct. It stays there as a "reserved" amount of `baseToken` until the trade is executed or cancelled.


* **During Active State:** Once the position is executed via `executeEntry`, that `excessMargin` is moved out of the position struct and added to the `userBaseMargin` mapping.


* **The Global Pool:** This `userBaseMargin` is a "virtual balance" held by the Driver contract. The physical `baseToken` remains in the Driver's contract address.

### **B. Withdrawal via `pullMargin**`

* **The Only Exit:** Since `excessMargin` is no longer tied to a specific trade's payout, it is **not** automatically returned to you when you close a single position.


* **Manual Retrieval:** You must call `pullMargin(uint256 amount)` to withdraw those funds back to your wallet. This function checks your global balance and transfers the `baseToken` out of the Driver.

### **C. The Exception: Liquidation**

* **Automated Loss:** While `pullMargin` is the only way for **you** to get the money out, there is one other way it leaves the Driver: **Liquidation**.

* **Seizure:** If any of your positions cross the liquidation threshold, the `_liquidateAccount` function wipes your entire `userBaseMargin` and transfers those funds to the `LiquidityTemplate` to cover the protocol's risk.
