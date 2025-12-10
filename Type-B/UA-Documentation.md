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
    
    ```Target Collateral Value $\approx$ Initial Margin Value * Target Leverage```
    
2.  **Iterative Looping:**
    The contract then enters a loop to achieve this target. In each iteration, it performs the following steps on your behalf:
    * **Borrow:** It borrows the maximum available amount of the `borrowAsset` based on your current collateral and Aave's Loan-to-Value (LTV) ratio.
    * **Swap:** It immediately swaps the borrowed asset for more of the `collateralAsset` on Uniswap V2.
    * **Supply:** It supplies the newly acquired collateral back to Aave, increasing your position's collateral balance.

The loop continues until either the **target collateral value is reached** or the next loop is blocked by the **`minHealthFactor`** constraint. This means your safety setting can, and often will, cap your final achieved leverage below the maximum value requested.

---

## 3. UAExecutor - Limit Order and Automated Execution System

The **UAExecutor** contract serves as the Limit Order and Automated Execution System for the UADriver Protocol. It provides an on-chain mechanism for users to submit orders for future execution based on specific price conditions, integrating directly with the **UADriver** to handle the complex debt-looping logic.

It introduces two primary order types and one position tracking mechanism:

### Core Data Structures

| Data Structure | Purpose | Key Parameters |
| :--- | :--- | :--- |
| **`WindOrder`** | A limit order to **open** a leveraged position (a "wind"). | `entryPrice`, `entryDirection` (e.g., execute when price `>=` or `<=` target), `targetLeverage`, `collateralAmount`. |
| **`UnwindOrder`** | A limit order to **close** an existing position. | `positionId`, `targetPrice`, `priceDirection`, `isTP` (Take Profit) or `isSL` (Stop Loss). |
| **`Position`** | Tracks the details of an active, executed leveraged position. | `maker`, `collateralAsset`, `borrowAsset`, `collateralAmount`, `debtAmount`, and links to the `tpOrderId` and `slOrderId`. |

### Execution Flow and Mechanics

1.  **Order Creation (`createWindOrder`)**: A user sends the initial margin (collateral) to the `UAExecutor` contract, along with all parameters for the desired leveraged position (pair, leverage, entry price, etc.).
2.  **External Execution**: Since smart contracts cannot execute themselves, the order execution is permissionless. An external entity ("mysterium") calls the `executeWinds` or `executeUnwinds` functions.
3.  **Price Check**: The Executor checks the current price for the asset pair using the integrated Uniswap V2 functions. If the price condition is met, the order proceeds.
4.  **Position Execution**:
    * **Wind Order**: The Executor calls the internal `_executeWindOrder`, which triggers the **UADriver's `executeLoop`** function.
    * **Unwind Order (TP/SL)**: The Executor calls the internal `_executeUnwindOrder`, which triggers the **UADriver's `unwindLoop`** function.
5.  **Position Management**: Users can create, modify, or bulk-cancel their pending orders, returning the held collateral if the order is not yet executed. Users can also manually `closePosition` at any time.

### Key Nuance: Custodial Position Management

The single most important distinction between the `UAExecutor` and the raw `UADriver` is their approach to position ownership:

* **UADriver (Direct Use) is Non-Custodial**: As outlined in Section 2, when a user calls the `UADriver` directly, the driver sets the `onBehalfOf` parameter to the **user's wallet address**. This means the aTokens (collateral) and DebtTokens are held and tracked by Aave against the user's wallet, maintaining non-custodial ownership.
* **UAExecutor is Custodial**: When a position is opened via a `WindOrder`, the `UAExecutor` calls the `UADriver` with its own contract address (`address(this)`) as the `onBehalfOf` parameter.
    * **Custody**: The Aave debt and collateral are tracked against the **Executor's address**.
    * **Tracking**: The `UAExecutor` becomes the custodian of the active position and tracks the *true* owner using its internal `Position` struct. This shift in ownership is necessary for the Executor to maintain the collateral and to be the entity that can later call `unwindLoop` for the TP/SL orders.