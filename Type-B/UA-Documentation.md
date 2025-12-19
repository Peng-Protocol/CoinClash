# UADriver Protocol Documentation

This document explains the architecture and core concepts of the UADriver suite of smart contracts, which automate recursive debt looping (leverage) on the Aave V3 protocol via Uniswap V2.

***

## 1. Architecture and Non-Custodial Ownership

### Aave and the Driver's Role

The Aave protocol is **non-custodial**. The UADriver contract is an **execution layer** that enables complex, multi-step actions (borrow, swap, deposit) to occur in a single blockchain transaction.

### Asset and Debt Ownership

When a user executes a loop using the UADriver, the driver acts **on the user's behalf** (`msg.sender`):

* **Assets/Collateral Ownership:** The driver calls Aave's `supply` function with the `onBehalfOf` parameter set to the **user's wallet address**. Aave then mints **aTokens** (interest-bearing collateral tokens) and sends them **directly to the user's wallet**. The user maintains full self-custody of their collateral.
* **Debt Ownership:** When the driver executes a `borrow` call, the debt position (represented by `DebtTokens`) is tracked by Aave against the **user's wallet address**.

**The contract never holds the user's long-term assets or debt.** It only temporarily holds the borrowed and swapped tokens for the duration of the single transaction to complete the loop.

***

## 2. Core Position Concepts and Driver Usage

The leverage loop can be interpreted as a levered exposure strategy based on the pair chosen for collateral and borrowing.

| Concept | UADriver Function | Explanation |
| :--- | :--- | :--- |
| **Enter Long Position** | `executeLoop()` | The user supplies **Asset A** as collateral and borrows **Asset B**. The borrowed **Asset B** is swapped for more **Asset A**, which is then redeposited as collateral. This strategy increases the user's exposure to **Asset A** (the collateral), making them **Long** the collateral asset. |
| **Enter Short Position** | `executeLoop()`  | This is a variant of the "Long Position." The user chooses the asset they wish to **short** (e.g., ETH) as the **`borrowAsset`**, and a stable asset (e.g., USDC) as the **`collateralAsset`**. The loop increases the amount of stablecoin collateral while increasing the ETH debt, effectively creating a **Short** position on the volatile asset (ETH). |
| **Close Position** | `unwindLoop()` | This function reverses the leverage process. It involves withdrawing collateral, swapping it back for the borrowed asset, and repaying the debt. If the `repayAmount` is set to `0`, the contract will calculate and repay the user's full variable debt. |
| **Add Margin** | *Aave Interaction* | This is performed **directly by the user** on the Aave protocol. By supplying more of the collateral asset to Aave, the user increases their total collateral value, which improves the position's Health Factor and reduces liquidation risk. |

### Excess Margin (`initialMargin`)

The term **Excess Margin** refers to the initial amount of collateral the user provides when calling the `executeLoop` function via the **`initialMargin`** parameter.

* **Role in Position Health:** This initial deposit is the user's equity that underpins the entire leveraged position. It is essential for absorbing potential losses from market volatility and for ensuring the position starts with a healthy collateral-to-debt ratio.
* **Safety Constraints:** The `executeLoop` logic relies on the user providing a strong `initialMargin` and a robust `minHealthFactor`. The looping mechanism is designed to automatically reduce the borrowed amount if the projected leverage would cause the position's health factor to drop below the user-specified **`minHealthFactor`** constraint.

## Further Explanation of `minHealthFactor`

The Health Factor (HF) is a metric calculated by the Aave protocol to determine the safety of your borrowed position.

* **HF Formula:** It is essentially the total value of your collateral (adjusted by liquidation threshold) divided by the total value of your debt.
* **Liquidation Threshold:** If your Health Factor drops **below 1.0**, your position is eligible for liquidation.

The `minHealthFactor` is a buffer set by you, the user, to prevent your automated looping process from pushing your position too close to the liquidation threshold.

### How it is used in the `UADriver`

1.  **Safety Floor Enforcement:** The `UADriver` has its own internal minimum health factor of **1.05** (a 5% buffer) that your input must meet or exceed.
2.  **Dynamic Borrow Adjustment:** During the execution of the `executeLoop` function, the contract calculates the `projectedHealthFactor` before initiating a new borrow and swap cycle.
    * If the projected Health Factor after the next loop would fall **below your specified `minHealthFactor`**, the driver will **reduce the amount it borrows** in that cycle.
    * This ensures that the leveraged position is built with enough **excess margin** to satisfy your chosen safety parameter, effectively stopping the recursive looping before it reaches a dangerously high leverage level.
3.  **Transaction Revert:** If a loop unexpectedly results in a Health Factor lower than the `minHealthFactor` (e.g., due to a major oracle price update mid-transaction), the entire transaction will be reverted, protecting your funds.

## The Mechanism for Achieving Leverage

The process is managed by the contract's **`executeLoop`** function, which takes the desired leverage as the **`targetLeverage`** parameter (e.g., a value of 10 represents 10x leverage).

1.  **Calculate Target Collateral Value:**
    The contract first calculates the total value of collateral it needs to accumulate to reach the desired leverage, using your **initial margin (equity)** as a base.
    
$$
\text{Target Collateral Value} \approx \text{Initial Margin Value} \times \text{Target Leverage}
$$
    
2.  **Iterative Looping:**
    The contract then enters a loop to achieve this target. In each iteration, it performs the following steps on your behalf:
    * **Borrow:** It borrows the maximum available amount of the `borrowAsset` based on your current collateral and Aave's Loan-to-Value (LTV) ratio.
    * **Swap:** It immediately swaps the borrowed asset for more of the `collateralAsset` on Uniswap V2.
    * **Supply:** It supplies the newly acquired collateral back to Aave, increasing your position's collateral balance.

The loop continues until either the **target collateral value is reached** or the next loop is blocked by the **`minHealthFactor`** constraint. This means your safety setting can, and often will, cap your final achieved leverage below the maximum value requested.

---

## 3. Price Impact and Market Slippage

The **UADriver**'s recursive swaps on Uniswap V2 actively move the market price of the assets involved in each cycle of the loop. This creates a direct relationship between the user's chosen leverage and the resulting price impact.

### Leverage as an Impact Multiplier

Price impact is a function of the user's **total exposure** (Initial Margin \times Leverage). 

* **Long Positions:** Concentrated demand "pumps" the price of the collateral relative to the borrow asset.
* **Short Positions:** Selling the borrowed asset into the pool "dumps" its price.

For example, a swap representing **1%** of a pool’s depth might cause **2%** price impact. At **2x leverage**, that same initial margin results in a **4%** impact. At **10x leverage**, the total amount swapped could move the price by **20%** or more.

### Impact on Loop Success

Price impact is the primary reason high-leverage orders may fail. The protocol’s safeguards interact with these price shifts in real-time:

* **Slippage Reversion:** If the cumulative price impact across all cycles exceeds your `maxSlippage` setting, the transaction will revert to prevent you from entering at an unfavorable price.
* **Health Factor Degradation:** Significant price movement during execution can cause the `projectedHealthFactor` to drop. If the impact pushes the position’s health below your `minHealthFactor`, the driver will either stop looping early or fail the transaction entirely.
* **Liquidity Constraints:** In smaller pools, the depth often cannot support the volume required for high leverage (like 10x). The price moves so aggressively during the initial cycles that the safety buffers are triggered before the target leverage is ever reached.

---

## 4. Financial Costs of Debt Looping

### 4.1. Aave Protocol Costs: Interest

The Aave protocol is an interest-based system and **does not** charge a standard supply or borrow origination fee on the principal amount.

The primary cost of using Aave is the **Borrow Interest Rate**:

| Cost Component | Description | Calculation |
| :--- | :--- | :--- |
| **Borrow Interest Rate** | The continuous, time-dependent cost of maintaining the debt position. | Interest accrues in real-time based on the **Variable** or **Stable** Annual Percentage Rate (APR/APY) of the asset borrowed. |
| **Supply Yield** | The yield earned on your collateral. | The interest earned on your supplied collateral (aTokens) helps to offset the borrow interest, resulting in the **Net Borrow Rate**. |

### 4.2. Uniswap Protocol Costs: Swap Fees

This is a fixed-percentage cost of 0.30% charged by the Uniswap liquidity pool for exchanging the borrowed asset back into the collateral asset during each cycle of the loop.
This cost is multiplied for each debt loop cycle. 

### 4.3. Total Cost Analysis

* **Opening the Position:** $N$ swaps are executed as the loop is initiated (borrow → swap → supply).
* **Unwinding the Position:** Reversing the loop requires $N$ reverse swaps to liquidate collateral and obtain the required repayment asset.

For an $N$-cycle loop, the total swap fee cost is incurred on $2N$ swaps.

### Ongoing Interest Cost (Time-Dependent)

Interest is calculated on the **total notional borrowed amount**. Looping multiplies the overall debt, which in turn multiples the relative fee, the interest rate itself remains flat.
Since Aave interest rates are highly dynamic, we use a representative example:

***Assumption:*** *A representative annual borrow APR for a stablecoin is **6%**.*

* **Hourly Interest Rate:** 6% APR / (365 days \* 24 hours) ≈ **0.000684%** per hour.

*This figure is multiplied by the amount of leverage used*

| Target Leverage (Approx.) | Cycles ($N$) to Open | Total Swaps (Open + Unwind) | Total Swap Fee Cost (% of Initial Principal) | Effective Hourly Interest Rate (on Total Borrowed) |
| :---: | :---: | :---: | :---: | :---: |
| **2x** | 2 | 4 | **1.20%** | $\approx \mathbf{0.001368\%}$ |
| **10x** | 10 | 20 | **6.00%** | $\approx \mathbf{0.00684\%}$ |
| **50x** | 50 | 100 | **30.00%** | $\approx \mathbf{0.0342\%}$ |

### Gas Fees

All interactions with Aave and Uniswap are subject to **Gas Fees**, which are non-refundable network transaction costs. Due to the high number of contract calls and internal loops in a single leveraged transaction, the gas cost for both opening and unwinding a position is substantial.

---

## 5. Understanding Leverage: Exposure vs. Equity

A debt loop multiplies the user's **market exposure**, not their initial margin (net worth).

The key distinction is between the **Target Collateral Value** (what you control) and your **Net Equity** (what you own).

### Exposure and Net Equity

| Term | Definition | Impact on Profit/Loss |
| :--- | :--- | :--- |
| **Total Exposure** | The total size of the collateral asset controlled by the position. This is the **Target Collateral Value** (Initial Margin $\times$ Target Leverage). | The full profit or loss from price movements is applied to this amount. |
| **Net Equity** | The user's true capital in the position (Total Collateral Value minus Total Debt Owed). | This value remains constant until the market price changes. |

### Example: 2x Leverage Loop

Starting with **200 USDT** and targeting **2x Leverage**:

* **Total Assets (Controlled):** $\mathbf{400 \text{ USDT}}$ (Collateral)
* **Total Liabilities (Owed):** $\mathbf{-200 \text{ USDT}}$ (Debt)
* **Net Equity (Owned):** $\mathbf{200 \text{ USDT}}$ (Your initial capital, not accounting for fees)

If the price of the collateral asset increases by **10%**, the user's **Net Equity** increases by 40 USDT, which represents a **20%** return (40 / 200) on the initial margin, or double the **10%** market gain.

---

## 6. UAExecutor - Limit Order and Automated Execution System

The **UAExecutor** contract serves as the Limit Order and Automated Execution System for the UADriver Protocol. It provides an on-chain mechanism for users to submit orders for future execution based on specific price conditions, integrating directly with the **UADriver** to handle the complex debt-looping logic.

The contract refactors position initiation (wind orders) and ongoing position tracking into a single **`Position`** struct and introduces an **`UnwindOrder`** struct for Take Profit (TP) and Stop Loss (SL) management.

### Core Data Structures and Status

| Data Structure | Status Enum | Purpose | Key Parameters |
| :--- | :--- | :--- | :--- |
| **`Position`** | `PENDING`, `ACTIVE`, `CLOSED`, `CANCELLED` | Used to track both the initial limit order (when `PENDING`) and the resulting active position (when `ACTIVE`). | `entryPrice`, `entryDirection`, `targetLeverage`, `collateralAmount`, `debtAmount`. |
| **`UnwindOrder`** | N/A (uses `executed`, `cancelled` flags) | A limit order to **close** an existing `ACTIVE` position, either as a TP or SL. | `positionId`, `targetPrice`, `priceDirection`, `isTP` (Take Profit) or `isSL` (Stop Loss). |

The contract uses mappings to manage the life-cycle of these orders:

* `positions`: Maps the unique `positionId` to its `Position` struct.
* `positionToTP`, `positionToSL`: Maps an `ACTIVE` `positionId` to its associated `UnwindOrder` ID. This ensures only one TP and one SL can exist per position.

### Execution Flow and Mechanics

1.  **Order Creation (`createOrder`)**:
    * A user sends the initial margin (collateral) to the `UAExecutor` contract.
    * A new **`Position`** struct is created with the status set to **`PENDING`**. The `entryPrice` and `entryDirection` define the limit order's trigger condition.

2.  **External Execution of Wind Orders (`executeOrders`)**:
    * An external entity ("mysterium") calls the `executeOrders` function with a list of `positionId`s.
    * The Executor checks:
        a.  If the position's status is **`PENDING`**.
        b.  If the `currentPrice` meets the `entryPrice` and `entryDirection` condition.
    * If conditions are met, the Executor calls the **UADriver's `executeLoop`** function, and then updates the `Position` struct:
        * Status is changed to **`ACTIVE`**.
        * `collateralAmount` and `debtAmount` are updated based on the actual figures from the Aave pool.
        * `entryPrice` is updated to the actual execution price.

3.  **TP/SL Order Management (`setTP`, `setSL`)**:
    * A user can set or update a Take Profit or Stop Loss for a `PENDING` or `ACTIVE` position.
    * A new **`UnwindOrder`** is created (or an existing one is updated).
    * The `positionToTP` or `positionToSL` mapping is updated to link the position to the new unwind order ID.

4.  **External Execution of Unwind Orders (`executeUnwinds`)**:
    * An external entity calls the `executeUnwinds` function.
    * The Executor iterates through the provided `orderId`s and checks:
        a.  If the associated `Position` is **`ACTIVE`**.
        b.  If the `currentPrice` meets the `targetPrice` and `priceDirection` condition of the `UnwindOrder`.
    * If conditions are met, the Executor calls the internal `_executeUnwindOrder`, which triggers the **UADriver's `unwindLoop`** function to close the position.

5.  **Position Finalization and Funds Return**:
    * Upon successful `unwindLoop` execution, the `Position` status is set to **`CLOSED`**.
    * All remaining collateral (initial margin + profit/loss) held by the Executor is transferred back to the original `maker`.
    * The position's associated TP/SL mappings are deleted.

### Key Nuance: Custodial Position Management

The `UAExecutor` is designed to act as the holder and manager of the active position. When a `PENDING` order becomes `ACTIVE` (the wind is executed):

* The **`UAExecutor`** calls the `UADriver` with its own contract address (`address(this)`) as the `onBehalfOf` parameter in `executeLoop`.
* **Custody**: The Aave debt and collateral are tracked against the **Executor's address** by Aave.
* **Tracking**: The `UAExecutor` becomes the custodian of the active position, tracking the *true* user owner via the `Position.maker` field. This custodial arrangement is essential for the Executor to maintain control of the collateral and debt, allowing it to execute the subsequent `unwindLoop` for TP/SL orders or manual closing.