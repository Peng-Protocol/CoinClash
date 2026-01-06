# CoinClash Type-C Liquidity & Fee Docs (v0.0.6)

This document outlines the technical specifications for the **TypeCLiquidity** and **TypeCFees** templates. As of version 0.0.6, the protocol uses a **Pair-Specific Slot** model, further hardening the isolation between different liquidity pools.

---

## 1. Core Architecture: Pair-Isolation

Type-C isolates liquidity and accounting by the **Pair Bucket**. This ensures that risk and rewards are strictly confined to the specific market participants of a given token pair.

* **The Bucket:** `pairLiquidity[Token][PairedToken]`. Liquidity is tracked in a directional mapping. If `USDT` is deposited to support an `ETH/USDT` pair, that USDT is strictly locked to that specific pair's settlement logic.
* **Security Impact:** This architecture prevents "Contagion Draining." A failure, exploit, or extreme volatility in a "junk" token pair cannot mathematically impact the liquidity or fees of a blue-chip pair like `ETH/USDT`.
* **Slot-Level Isolation:** In v0.0.6, slots are indexed *within* each pair. This means `Slot #1` for Pair A is entirely distinct from `Slot #1` for Pair B, preventing index collisions and simplifying cross-contract lookups.

---

## 2. TypeCLiquidity Template

The `TypeCLiquidity` contract serves as the primary vault and ledger for user allocations.

### A. Core Entry Points

* **`ccDeposit(token, pairedToken, depositor, amount)`**:
  * Pulls funds from the caller and updates the isolated `pairLiquidity` bucket.
  * Generates a new `Slot` using a pair-specific index (`activeSlots[token][pairedToken]`).
  * Triggers an external call to the Fee Template to "snapshot" the current fee accumulator for that specific pair.
  * Note: Once a slot is created, its allocation cannot be increased, this is essential for accurate fee tracking. 


* **`ccWithdraw(token, pairedToken, index, amount)`**:
  * Reclaims principal from a specific pair bucket.
  * Requires both the `token` and `pairedToken` to locate the correct isolated slot.
  * Decreases the slot `allocation` and the total `pairLiquidity` for that bucket.


* **`ccDonate(token, pairedToken, amount)`**:
  * Injects "unclaimed" liquidity into a pair bucket. Because no `Slot` is created, this liquidity acts as a permanent buffer or reward for other participants in that specific pair.



### B. Settlement Logic

* **`ssUpdate`**: Authorized Routers/Drivers create `Payout` objects. These are now explicitly linked to a `pairedToken` to ensure the debt is settled from the correct isolated bucket.
* **`processPayout`**: The final safety check. It ensures the contract never pays out more than the specific pair's liquidity allows, regardless of the contract's total global balance.

---

## 3. TypeCFees Template

The `TypeCFees` contract manages protocol revenue. It uses a **Global Accumulator** pattern (*feesAcc*) to handle pro-rata distributions without expensive loop-based accounting.

### A. Fee Logic

* **`addFees(tokenA, tokenB, amount)`**:
  * Calculates the **Canonical Ordering** of the pair (standardizing `TokenA/TokenB` vs `TokenB/TokenA`).
  * Increases the pair's global accumulator. All fees are normalized to 18 decimals internally for mathematical precision.


* **`claimFees(token, pairedToken, index)`**:
1. **Context Fetching:** Retrieves the user's specific slot data from the Liquidity Template.
2. **Delta Calculation:** Calculates the difference between the current pair accumulator and the user's last snapshot.
3. **Pro-Rata Share:** Multiplies this delta by the user's `allocation` relative to the *entire* liquidity of that specific pair.
4. **Inverse Payment:** Fees are always paid in the **opposite** token of the deposit. If you provide liquidity in Token A, you earn your yield in Token B.
5. **Denormalization:** Before transfer, the normalized fee amount is converted back to the specific decimal precision of the fee token.



---

## 4. Technical Nuances & Safety

### Canonical Ordering & Uniswap V2

To ensure consistent tracking, TypeCFees fetches the "True" token order from the Uniswap V2 Factory. This prevents the creation of two separate fee buckets for the same pair (e.g., one for `ETH/USDC` and one for `USDC/ETH`).

### The "Opposite Token" Rule

Liquidity providers (LPs) act as the counterparty to the pair. Therefore, their earnings are denominated in the paired asset. This ensures that LPs are naturally diversifying their holdings into the asset they are supporting.

### Reentrancy & State

All core functions utilize `nonReentrant` guards. In `claimFees`, the user's fee snapshot is updated *before* the transfer of funds to prevent double-claim exploits.

---

## 5. Deployment & Configuration

1. **Linkage:** The `TypeCLiquidity` contract must have the `feeTemplateAddress` set.
2. **Router Permissions:** `TypeCLiquidity` must be added as a **Router** in `TypeCFees` so it can trigger the `initializeDepositorFeesAcc` function during deposits.
3. **Factory Setup:** Both contracts require the `uniswapV2Factory` address to correctly identify and order token pairs.
4. **Graceful Degradation:** Core operations (deposits/withdrawals) use `try/catch` blocks for external calls to the Registry or Globalizer. This ensures that a failure in a secondary accounting module does not lock user funds.
