# UEDriver Protocol Documentation

This document explains the architecture and core concepts of the UEDriver suite of smart contracts, which automate recursive debt looping (leverage) on the **Euler V2** protocol via Uniswap V2.

---

## 1. Architecture and Account Ownership

### Euler V2 and the Driver's Role

Euler V2 is a modular lending protocol. The UEDriver contract acts as an **execution layer** that facilitates complex, multi-step actions—borrowing, swapping, and depositing—across isolated Euler Vaults in a single blockchain transaction.

### Asset and Debt Ownership: The EVC Model

Unlike Aave’s "onBehalfOf" model, Euler V2 utilizes the **Ethereum Vault Connector (EVC)** to manage account permissions. To ensure the user, rather than the contract, owns the resulting debt and collateral, the protocol relies on one of two ownership patterns:

* **Option A: EVC Operator (Recommended):** The user designates the `UEDriver` as an **Operator** via the EVC. This allows the Driver to "act as" the user. When the Driver calls an Euler Vault, the EVC verifies this permission, and the debt/collateral is recorded directly against the **user's wallet address**.
* **Option B: Delegatecall:** If the Driver is called via `delegatecall` (e.g., from a smart contract wallet), the code executes within the context of the user's account. The Vault sees the `msg.sender` as the user, and the position is naturally attributed to them.

**The contract remains non-custodial.** It only temporarily handles assets during the execution of the loop to perform swaps; the long-term interest-bearing shares (collateral) and debt remain with the authorized account.

---

## 2. Core Position Concepts and Driver Usage

The leverage loop can be interpreted as a levered exposure strategy based on the pair chosen for collateral and borrowing.

| Concept | UEDriver Function | Explanation |
| :--- | :--- | :--- |
| **Enter Long Position** | `executeLoop()` | The user supplies **Asset A** as collateral and borrows **Asset B**. The borrowed **Asset B** is swapped for more **Asset A**, which is then redeposited as collateral. This strategy increases the user's exposure to **Asset A** (the collateral), making them **Long** the collateral asset. |
| **Enter Short Position** | `executeLoop()`  | This is a variant of the "Long Position." The user chooses the asset they wish to **short** (e.g., ETH) as the **`borrowAsset`**, and a stable asset (e.g., USDC) as the **`collateralAsset`**. The loop increases the amount of stablecoin collateral while increasing the ETH debt, effectively creating a **Short** position on the volatile asset (ETH). |
| **Close Position** | `unwindLoop()` | This function reverses the leverage process. It involves withdrawing collateral, swapping it back for the borrowed asset, and repaying the debt. If the `repayAmount` is set to `0`, the contract will calculate and repay the user's full variable debt. |
| **Add Margin** | *Euler Interaction* | This is performed **directly by the user** on the Euler v2 protocol. By supplying more of the collateral asset to Euler the user increases their total collateral value, which improves the position's Health Factor and reduces liquidation risk. |

### Excess Margin (`initialMargin`)

The term **Excess Margin** refers to the initial amount of collateral the user provides when calling the `executeLoop` function via the **`initialMargin`** parameter.

* **Role in Position Health:** This initial deposit is the user's equity that underpins the entire leveraged position. It is essential for absorbing potential losses from market volatility and for ensuring the position starts with a healthy collateral-to-debt ratio.
* **Safety Constraints:** The `executeLoop` logic relies on the user providing a strong `initialMargin` and a robust `minHealthFactor`. The looping mechanism is designed to automatically reduce the borrowed amount if the projected leverage would cause the position's health factor to drop below the user-specified **`minHealthFactor`** constraint.

## Further Explanation of `minHealthFactor`

The Health Factor (HF) is a metric calculated by the Euler v2 protocol to determine the safety of your borrowed position.

* **HF Formula:** It is essentially the total value of your collateral (adjusted by liquidation threshold) divided by the total value of your debt.
* **Liquidation Threshold:** If your Health Factor drops **below 1.0**, your position is eligible for liquidation.

The `minHealthFactor` is a buffer set by you, the user, to prevent your automated looping process from pushing your position too close to the liquidation threshold.

* **Isolated Health:** Because Euler is modular, your Health Factor is Vault-specific. In the UEDriver, the Health Factor is determined specifically by the relationship between the collateralVault and the borrowVault. Risk is isolated; a price crash in an unrelated asset on Euler won't affect the health of your specific loop in this driver.

### How it is used in the `UEDriver`

1.  **Safety Floor Enforcement:** The `UEDriver` has its own internal minimum health factor of **1.05** (a 5% buffer) that your input must meet or exceed.
2.  **Dynamic Borrow Adjustment:** During the execution of the `executeLoop` function, the contract calculates the `projectedHealthFactor` before initiating a new borrow and swap cycle.
    * If the projected Health Factor after the next loop would fall **below your specified `minHealthFactor`**, the driver will **reduce the amount it borrows** in that cycle.
    * This ensures that the leveraged position is built with enough **excess margin** to satisfy your chosen safety parameter, effectively stopping the recursive looping before it reaches a dangerously high leverage level.
3.  **Transaction Revert:** If a loop unexpectedly results in a Health Factor lower than the `minHealthFactor` (e.g., due to a major oracle price update mid-transaction), the entire transaction will be reverted, protecting your funds.

## The Mechanism for Achieving Leverage

The process is managed by the contract's **`executeLoop`** function, which takes the desired leverage as the **`targetLeverage`** parameter (e.g., a value of 2 represents 2x leverage).

1.  **Calculate Target Collateral Value:**
    The contract first calculates the total value of collateral it needs to accumulate to reach the desired leverage, using your **initial margin (equity)** as a base.
    
$$
\text{Target Collateral Value} \approx \text{Initial Margin Value} \times \text{Target Leverage}
$$
    
2.  **Iterative Looping:**
    The contract then enters a loop to achieve this target. In each iteration, it performs the following steps on your behalf:
    * **Borrow:** It borrows the maximum available amount of the `borrowAsset` based on your current collateral and the specific pool's Loan-to-Value (LTV) ratio.
    * **Swap:** It immediately swaps the borrowed asset for more of the `collateralAsset` on Uniswap V2.
    * **Supply:** It supplies the newly acquired collateral back to Euler, increasing your position's collateral balance.

The loop continues until either the **target collateral value is reached** or the next loop is blocked by the **`minHealthFactor`** constraint. This means your safety setting can, and often will, cap your final achieved leverage below the maximum value requested.

LTV limits on Euler (the percent of your collateral you're allowed to borrow against), will set a cap on how much leverage you can realistically use, there are no global limits, but you may expact LTV for uncorrelated assets around ~82.5%, at which the max leverage is about 5.7x. 
Though most pools will have LTV around 75%

$1 / (1 - 0.75) = \mathbf{4x}$.

---

## 3. Price Impact and Market Slippage

The **UEDriver**'s recursive swaps on Uniswap V2 actively move the market price of the assets involved in each cycle of the loop. This creates a direct relationship between the user's chosen leverage and the resulting price impact.

### Leverage as an Impact Multiplier

Price impact is a function of the user's **total exposure** (Initial Margin \times Leverage). 

* **Long Positions:** Concentrated demand "pumps" the price of the collateral relative to the borrow asset.
* **Short Positions:** Selling the borrowed asset into the pool "dumps" its price.

For example, a swap representing **1%** of a pool’s depth might cause **2%** price impact. At **2x leverage**, that same initial margin results in a **4%** impact. 

### Impact on Loop Success

Price impact is the primary reason high-leverage orders may fail. The protocol’s safeguards interact with these price shifts in real-time:

* **Slippage Reversion:** If the cumulative price impact across all cycles exceeds your `maxSlippage` setting, the transaction will revert to prevent you from entering at an unfavorable price.
* **Health Factor Degradation:** Significant price movement during execution can cause the `projectedHealthFactor` to drop. If the impact pushes the position’s health below your `minHealthFactor`, the driver will either stop looping early or fail the transaction entirely.
* **Liquidity Constraints:** In smaller pools, the depth often cannot support the volume required for leverage. The price moves so aggressively during the initial cycles that the safety buffers are triggered before the target leverage is ever reached.

---

## 4. Financial Costs of Debt Looping

### 4.1. Aave Protocol Costs: Interest

The Aave protocol is an interest-based system and **does not** charge a standard supply or borrow origination fee on the principal amount.

The primary cost of using Aave is the **Borrow Interest Rate**:

| Cost Component | Description | Calculation |
| :--- | :--- | :--- |
| **Borrow Interest Rate** | The continuous, time-dependent cost of maintaining the debt position. | Interest accrues in real-time based on the **Variable** or **Stable** Annual Percentage Rate (APR/APY) of the asset borrowed. |
| **Supply Yield** | The yield earned on your collateral. | The interest earned on your supplied collateral (Vault Shares) helps to offset the borrow interest, resulting in the **Net Borrow Rate**. |

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
| **4x** | 4 | 8 | **2.4%** | $\approx \mathbf{0.002736\%}$ |

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

## 6. UEExecutor: Limit Order Management

The `UEExecutor` contract introduces a **Custodial/Monolithic** management layer on top of the Driver. It allows users to automate the "When" of their leverage through limit orders.

### Execution Flow

1. **Order Creation (Wind)**:
* The user creates a `PENDING` position by depositing initial margin into the `UEExecutor`.
* The user defines a `targetPrice` and `entryDirection` (e.g., "Enter 5x ETH/USDC long if ETH falls to $2000").


2. **Price Triggers**:
* The Executor monitors prices via Uniswap V2 pairs.
* When the condition is met, `executeOrders` is called.


3. **Position Custody**:
* Unlike direct Driver usage, the **`UEExecutor` contract itself holds the position** on Euler.
* It tracks the original `maker` internally. This allows the Executor to autonomously close the position when Take-Profit (TP) or Stop-Loss (SL) conditions are met without requiring further user signatures.


4. **Automated Unwinding**:
* The Executor monitors the active position against user-defined TP/SL prices.
* When triggered, it calls the Driver's `unwindLoop` to repay debt, withdraw collateral, and return the remaining assets (initial margin + PnL) to the user.



### Key Nuance: Custodial Position Management

The `UEExecutor` is designed to act as the manager of the active position. Because the Executor holds the assets and debt on Euler, it maintains the authority to "unwind" the strategy at the exact moment a price target is hit, ensuring the limit order logic is enforced even if the user is offline.