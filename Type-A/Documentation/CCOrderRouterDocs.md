## CCOrderRouter Contract: Simplified Documentation

This document provides an overview of the `CCOrderRouter` contract, the primary interface for users to create and manage limit orders in the CoinClash Type-B decentralized trading system.

---

### Overview

The `CCOrderRouter` is a Solidity contract (`^0.8.2`) designed as the **user's entry point** for all order-making activities (creating, cancelling, and batch-cancelling orders).

* **Core Function:** It handles the user's initial token/ETH transfer and formats the order data for the underlying system.
* **Architecture:** It inherits key utilities from `CCOrderPartial` and `CCMainPartial` and interacts exclusively with a single, central **Listing Template** contract via the `ICCListing` interface.
* **Key Distinction:** This router is focused *only* on order-making.

| Detail | Value |
| :--- | :--- |
| **License** | BSL 1.1 - Peng Protocol 2025 |
| **Version** | 0.2.0 (Updated 11/11/2025) |
| **Base Contract** | `CCMainPartial` (Shared utility base) |
| **Core Dependency**| Monolithic `CCListingTemplate.sol` (v0.4.2) |

---

### Order Creation (`createBuyOrder` & `createSellOrder`)

Both buy and sell orders follow a similar, robust execution pipeline:

1.  **Input Validation:** Checks if the tokens are different and ensures at least one is an ERC20 or native ETH (represented by $address(0)$).
2.  **Uniswap Check:** Calls `_validateUniswapPair(startToken, endToken)` to confirm active liquidity exists on Uniswap V2 for the pair.
3.  **Preparation (`_handleOrderPrep`):**
    * Creates an `OrderPrep` struct.
    * **Normalizes** the user's `inputAmount` to an 18-decimal standard (`1e18`) for internal processing, regardless of the token's actual decimals.
4.  **Transfer & Validation (`_validateAndTransfer`):**
    * **ERC20 Tokens:** Checks the user's allowance, uses `transferFrom` to pull the tokens from the user, and calculates the `amountReceived` using **pre/post balance checks** to account for transfer fees or taxes. The tokens are then immediately **forwarded to the Listing Template** for safekeeping.
    * **Native ETH ($address(0)$):** Requires $msg.value$ to match the expected `inputAmount`. The ETH is then **forwarded to the Listing Template**.
    * Returns the denormalized (`amountReceived`) and normalized (`normalizedReceived`) amounts.
5.  **Execution (`_executeSingleOrder`):**
    * Fetches the next available `orderId`.
    * Constructs **three array-based update structures** (Core, Pricing, Amounts) containing the order details.
    * Calls $listingTemplate.ccUpdate()$ to record the order in the central Listing Template.
6.  **Event:** Emits `OrderCreated`.

---

### Order Cancellation (`clearSingleOrder` & `clearOrders`)

Users can cancel orders they have previously created:

* **`clearSingleOrder(uint256 orderIdentifier, bool isBuyOrder)`:** Cancels one specific order by ID.
* **`clearOrders(uint256 maxIterations)`:** Allows a user to batch-cancel up to `maxIterations` of their pending orders, providing a gas-efficient method for mass cancellation.

#### Cancellation Process (`_clearOrderData`)

1.  **Retrieve & Validate:** Fetches the order data from the Listing Template and verifies that the $msg.sender$ is the original order **maker**.
2.  **Refund Check:** If the order is `pending` (Status 1) or `partially filled` (Status 2) and has a remaining pending amount (`amounts[0] > 0`), a refund is triggered.
3.  **Refund Execution:** The pending amount is **denormalized** back to the token's original decimal format. 
    * The router calls $listingContract.withdrawToken(tokenAddress, refundAmount, recipient)$ on the Listing Template. The template handles returning the funds (ETH or ERC20) to the order recipient.
4.  **Status Update:** A final update is sent to the Listing Template via $ccUpdate()$ to set the order status to `0` (**cancelled**).
5.  **Event:** Emits `OrderCancelled`.

---

### Formulas: Normalization

Since different tokens have different decimal counts (e.g., 6, 8, 18), all internal calculations are performed using a standard **18-decimal format** to maintain precision.

* **Normalization:** Converts the actual token amount to the 18-decimal standard for storage and processing.

    $$
    \text{normalize}(\text{amount}, \text{decimals}) =
    \begin{cases}
    \text{amount} & \text{if } \text{decimals} = 18 \\
    \text{amount} \times 10^{(18 - \text{decimals})} & \text{if } \text{decimals} < 18 \\
    \text{amount} / 10^{(\text{decimals} - 18)} & \text{if } \text{decimals} > 18
    \end{cases}
    $$

* **Denormalization:** Converts the 18-decimal amount back to the token's native decimal format for transfers and refunds.

    $$
    \text{denormalize}(\text{amount}, \text{decimals}) =
    \begin{cases}
    \text{amount} & \text{if } \text{decimals} = 18 \\
    \text{amount} / 10^{(18 - \text{decimals})} & \text{if } \text{decimals} < 18 \\
    \text{amount} \times 10^{(\text{decimals} - 18)} & \text{if } \text{decimals} > 18
    \end{cases}
    $$