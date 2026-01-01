# CoinClash Type-C Liquidity & Fee Docs (v0.0.5)

This document outlines the technical specifications for the **TypeCLiquidity** and **TypeCFees** templates. As of version 0.0.5, the protocol uses an **Isolated Liquidity** model to prevent cross-pair exploits.

---

## 1. Core Architecture: Pair-Isolation

Unlike certain liquidity pools where all assets of a certain type (e.g., USDT) are fungible, Type-C isolates liquidity by the **Pair Bucket**.

* **The Bucket:** `pairLiquidity[Token][PairedToken]` If `USDT` is deposited to support an `ETH/USDT` pair, that USDT **cannot** be used to pay out winners on a `JUNK/USDT` pair.
* **Security Impact:** A price manipulation attack on a low-liquidity or "trash" pair is mathematically confined to the liquidity specifically deposited for that pair.

---

## 2. TypeCLiquidity Template

The `TypeCLiquidity` contract serves as the primary vault. It handles principal deposits, trade payouts, and direct withdrawals.

### A. Core Entry Points

* **`ccDeposit(token, pairedToken, depositor, amount)`**:
  * Pulls funds from the caller.
  * Creates a `Slot` for the depositor.
  * Increases the specific `pairLiquidity` bucket.
  * Initializes the fee snapshot in the Fee Template.

* **`ccWithdraw(token, slotIndex, amount)`**:
  * Allows a depositor to reclaim their principal.
  * Decreases both the slot `allocation` and the `pairLiquidity` bucket.
  * Restricted to the `depositor` address.

* **`ccDonate(token, pairedToken, amount)`**:
  * Adds liquidity to a pair bucket without creating a debt (slot).
  * Used by drivers to add "Yield" or "Closures" to a specific pair.

### B. Settlement Logic

* **`ssUpdate`**: Authorized Drivers call this to create `Payout` objects. Every payout is linked to a `pairedToken` to ensure isolation.
* **`processPayout`**: Checks that the requested payout does not exceed the `pairLiquidity` for that specific pair. This is the final line of defense against drain attacks.

---

## 3. TypeCFees Template

The `TypeCFees` contract manages protocol revenue independently of user principal. It uses a **Global Accumulator** pattern, meaning it tracks the "true" fees a user is entitled to, rather than a simple time based function. 

### A. Fee Logic

* **`addFees(tokenA, tokenB, amount)`**: Increases the `feesAcc` (accumulator) for the canonical pair by billing the caller.
* **`initializeDepositorFeesAcc`**: Called during `ccDeposit` to take a "snapshot" of the current accumulator, this is essential for accurate depositor fee calculation.

* **`claimFees(liquidityAddress, token, index)`**: 
  1. Calculates the delta between the current `feesAcc` and the user's last snapshot. (Essentially; what amount of fees their liquidity has contributed to). 
  2. Multiplies the delta by the user's `allocation` relative to the `pairLiquidity`.
  3. Updates the snapshot to the current value to prevent double-claiming.
  4. Transfers the pro-rata share of fees to the user.

---

## 4. Technical Constants & Safety

### Canonical Ordering

To prevent duplicate data for `ETH/USDT` vs `USDT/ETH`, all mappings in the Fee Template use canonical sorting:
`token0 = address(tokenA) < address(tokenB) ? tokenA : tokenB`

### Graceful Degradation

Internal calls between the Liquidity and Fee templates (and Globalizer/Registry) are wrapped in `try/catch` blocks. If a non-essential accounting module (like the Globalizer) fails, the core deposit or settlement will still succeed.

### Native ETH Handling

Both templates natively support ETH (`address(0)`).

* **Deposits:** Handled via `msg.value`.
* **Withdrawals/Claims:** Handled via `address(recipient).call{value: amount}("")`.

---

## 5. Deployment Checklist

1. **Linkage:** Set `feeTemplateAddress` in `TypeCLiquidity`. Setup `TypeCLiquidity` as a router in `TypeCFees` to enable `dFeesAcc` initialization. 
2. **Auth:** Add the `CCIsolatedDriver` address to the `routers` mapping in both templates.
3. **Initialization:** Ensure the token registry and globalizer addresses are set (optional). 

---