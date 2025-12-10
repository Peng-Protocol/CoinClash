# `CCSettlementRouter` Contract Documentation

## Overview: What the Router Does

The `CCSettlementRouter` is the **core execution engine** for a decentralized trading platform. Its primary job is to take pre-computed orders (buy or sell) and settle them by executing a token swap on **Uniswap V2**.

**Key Principles:**

* **Off-Chain Pricing:** The contract **avoids complex on-chain price and slippage calculations**. The input amount (`amountsIn`) is pre-calculated off-chain and must be provided in a **normalized 18-decimal format**.
* **Decentralized Integration:** It manages interactions with external contracts: the `ICCListing` contract (where orders live), `IUniswapV2Router02` (for swaps), and `IERC20` tokens.
* **Safety & Control:** It uses `ReentrancyGuard` to prevent re-entrancy attacks and `Ownable` for administrative functions.

**Core Flow Summary:**

1.  **Receive Call:** `settleOrders` is called with a list of `orderIds` and pre-normalized `amountsIn`.
2.  **Validate:** The contract validates the order against pricing rules (`_checkPricing`).
3.  **Withdraw/Pull Funds:** It pulls the necessary input tokens (or ETH) from the listing contract using `withdrawToken` or a low-level call.
4.  **Execute Swap:** It executes the swap on Uniswap V2.
5.  **Update State:** It updates the order status and amounts on the listing contract via a single, atomic `ccUpdate` call.
6.  **Historical Record:** If successful, it records a historical trade entry.

**Contract Details:**
* **Solidity Version:** `^0.8.2`
* **Inheritance:** `CCSettlementRouter` → `CCSettlementPartial` → `CCUniPartial` → `CCMainPartial`
* **License:** BSL 1.1 - Peng Protocol 2025
* **Version:** 0.4.3

---

## Core Function: `settleOrders`

$$\texttt{settleOrders}(\texttt{listingAddress}, \texttt{orderIds}[], \texttt{amountsIn}[], \texttt{isBuyOrder}) \rightarrow \texttt{reason}$$

This is the main external function, protected by `nonReentrant`.

| Parameter | Type | Description | Key Requirement |
| :--- | :--- | :--- | :--- |
| `listingAddress` | `address` | The address of the order book contract. | N/A |
| `orderIds` | `uint256[]` | The list of orders to settle. | N/A |
| `amountsIn` | `uint256[]` | The token input amounts for each order. | **Must be 18-decimal normalized.** |
| `isBuyOrder` | `bool` | True for buy orders, false for sell orders. | N/A |

### Execution Steps:

1.  **Iterate Orders:** The function loops through each order ID and its corresponding `amountIn`.
2.  **Validation:** Calls `_validateOrder`, which checks:
    * The order is active (`status == 1`).
    * The input amount is positive (`amounts[0] > 0`).
    * The market price is within the order's specified `[minPrice, maxPrice]` range via **`_checkPricing`** (which is **non-view** because it emits `OrderSkipped` on failure).
3.  **Order Processing:** If validated, it calls `_processBuyOrder` or `_processSellOrder`.
    * This includes: pulling funds (Token or ETH), preparing the swap data, executing the swap on Uniswap V2, and calculating the resulting order updates.
4.  **Order Update:** Calls `_updateOrder`, which sends the final update structs to the listing contract via the critical **`ccUpdate`** function.
    * If `ccUpdate` fails, the transaction **reverts** with the decoded error reason.
5.  **Historical Update:** If at least one order was successfully settled, a new historical entry is created for the token pair.

---

## Key Technical Concepts

### Token Denormalization/Normalization

The router relies on the `CCUniPartial` base contract to handle the necessary conversions between the native token decimals (e.g., 6 for USDC, 18 for ETH) and the standardized **18-decimal normalized format**.

* **Normalization:** `normalized\_value = value * 10^{(18 - decimals)}`
* **Denormalization:** `value = normalized\_value / 10^{(18 - decimals)}`

### Low-Level ETH Withdrawal (`_callWithdrawNative`)

To solve the "non-payable function" type error, this function safely executes a low-level call to the listing contract's `withdrawToken` function:

1.  **Encodes Calldata:** It uses `abi.encodeWithSelector` to create the payload for the `withdrawToken` call.
2.  **Executes Call:** It performs a low-level `call{value:}`.
3.  **Error Handling:** It uses assembly to decode the revert reason if the low-level call fails.

### Order Skip vs. Revert

The router employs distinct error handling for different failure types:

* **Non-Critical Failure (Graceful Degradation):** If an order fails its pricing check (`_checkPricing`), the function emits an `OrderSkipped` event and simply moves to the next order in the batch.
* **Catastrophic Failure:** If a system-critical step fails (e.g., `ccUpdate` fails, Uniswap swap fails, or a zero reserve is hit), the entire transaction **reverts** with the decoded error message.

### Swap Details

* The swap uses the **Uniswap V2** interface.
* **Slippage Check:** It enforces a minimum output amount (`amountOutMin`) of **95%** of the expected output: `amountOutMin = expected * 95 / 100`.
* **Fee:** A 0.3% Uniswap fee is applied during the internal `_calculateSwap` validation.

### Impact Price Validation

The `CCSettlementRouter` uses an **Impact Price**—the estimated price after the specific trade is executed—to validate orders, not just the current spot price.

This is calculated internally by modeling the swap's effect on the Uniswap V2 reserves as follows;

1.  **Calculate Impact:** Helper functions (`_loadReserves`, `_calculateSwap`) model the trade to determine the price that results *after* the input amount is factored into the pool's liquidity.
2.  **Validate Bounds:** The `_checkPricing` function uses this **Calculated Impact Price** and confirms it falls within the order's defined limits (`minPrice` and `maxPrice`):
    $$\text{Order Min Price} \le \text{Calculated Impact Price} \le \text{Order Max Price}$$
3.  **Result:** If the projected fill price is outside the acceptable range, the order is **skipped**, preventing settlement at a severely unfavorable price. 

---