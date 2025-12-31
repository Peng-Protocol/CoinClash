# Templates Documentation (v0.0.1 - v0.0.2)

This document outlines the technical specifications and operational logic for the **TypeCLiquidity** and **TypeCFees** templates. These contracts serve as the decentralized settlement and revenue layers for the CoinClash Type-C, separating asset management from execution logic. 

---

## 1. TypeCFees Template (v0.0.1)

The `TypeCFees` contract is a standalone module dedicated to tracking, and accumulating protocol fees. It uses canonical token ordering to ensure fee data is consistent across different trading pairs. 

### Key Mechanisms

* **Canonical Ordering:** To prevent duplicate fee mappings for the same pair (e.g., ETH/USDC vs USDC/ETH), the contract always sorts token addresses: `token0 = tokenA < tokenB ? tokenA : tokenB`. 

* **Fee Accumulation:** * **Pair Level:** Tracks the current withdrawable `fees` and the cumulative `feesAcc` for a specific pair. 

* **Token Level:** Tracks a global `tokenFeesAcc` for backwards compatibility with legacy liquidity systems.

* **Depositor Snapshots:** It maintains `depositorFeesAcc`, which takes a snapshot of the global `feesAcc` whenever a user enters a liquidity position, allowing for precise pro-rata fee distribution. 

### Core Functions

* **addFees:** Primary entry point for revenue. It pulls tokens from the caller (e.g., the Driver) and updates both the pair-level and token-level accumulators. 

* **withdrawFees:** Restricted to authorized **Routers**. It allows for the extraction of accumulated fees to a designated recipient. 

* **initializeDepositorFeesAcc:** Used by the liquidity router during new deposit events to "lock in" the starting point for a user's fee earning period. 

---

## 2. TypeCLiquidity Template (v0.0.2)

The `TypeCLiquidity` contract acts as the primary vault and counterparty for all trades. It enables liquidity provider (LP) deposits, withdrawals, and trade settlements. 

### Settlement Architecture

The contract utilizes a **(`ssUpdate`)** pattern. Rather than the Driver handling payouts directly, it submits a request to the liquidity template. 

* **Router Privileges:** Only addresses whitelisted in the `routers` mapping can trigger asset movements or settlement updates. 

* **Liquidity Slots:** User deposits are organized into "Slots," which track the token, amount, and the depositor's address. 

### Core Functions

* **ssUpdate:** The settlement engine. It accepts an array of `SettlementUpdate` structs (containing recipient, token, and amount) to distribute profits to winning traders. 

* **Asset Management:**
  * **Liquidity Totals:** Tracks the `liquid` (available) balance for every supported token. 

  * **User Views:** Provides functions like `userSlotIndicesView` and `getSlotView` for frontend transparency regarding LP positions. 

---

### Security Requirements

1. **Router Whitelisting:** The `CCIsolatedDriver` must be added as a router to both contracts via `addRouter` for the system to function. 

2. **Asset Safety:** All settlement and withdrawal functions are protected by `nonReentrant` modifiers and strict access controls. 

3. **Normalization:** Both templates use internal `normalize` and `denormalize` helpers to ensure math remains consistent across tokens with different decimal places (e.g., USDT vs. WBTC).

---

# CCLiquidityRouter Documentation (v0.0.1)

The **CCLiquidityRouter** (extending `TypeCLiquidityPartial`) serves as the primary user-facing interface for interacting with the **TypeCLiquidity** and **TypeCFees** templates. It simplifies complex operations like multi-token deposits, interest-bearing withdrawals, and pro-rata fee claims.

---

## 2. Core Operations

### A. Deposits (`depositToken` / `depositNativeToken`)

When a user provides liquidity, the Router coordinates a multi-step process:

1. **Transfer:** Assets are moved from the user to the `TypeCLiquidity` vault.
2. **Slot Creation:** A "Liquidity Slot" is created in the liquidity template to track the `allocation` and `timestamp`.
3. **Fee Syncing:** The Router calls the `feeTemplate` to initialize the `depositorFeesAcc` (snapshot) for that specific slot. This "locks in" the current fee accumulator so the user only earns fees generated *after* their deposit.

### B. Fee Claims (`claimFees`)

The Router is responsible for calculating how much profit a Liquidity Provider (LP) has earned based on their share of the pool.

* **Logic:** It compares the current `feesAcc` in the `TypeCFees` template against the snapshot (`dFeesAcc`) stored when the user deposited or last claimed.
* **Settlement:** Once the share is calculated, the Router triggers a withdrawal from the Fee Template to the user's address and resets their dFeesAcc to prevent double claiming.

### C. Withdrawals (`withdrawToken`)

Withdrawals are "prepared" and then "executed" to handle potential compensations or slippage:

* **Primary Amount:** The principal liquidity being removed from the slot.
* **Compensation:** In cases where the pool balance is skewed, the system may provide compensation in a paired token.
* **Slot Update:** The `allocation` in the `TypeCLiquidity` vault is reduced accordingly.

---

## 4. Technical Constants & Safety

### Normalize / Denormalize

Because the protocol supports tokens with varying decimals (e.g., USDC with 6 vs. DAI with 18), the Router uses internal math to normalize all internal accounting to **18 decimals**.

* **Normalize:** `(amount * 1e18) / (10**decimals)`
* **Denormalize:** `(internalAmount * 10**decimals) / 1e18`

### Update Types (ccUpdate)

The Router communicates with the Liquidity Vault using a standardized `UpdateType` struct:

* `0`: Liquid (Total pool balance update)
* `1`: Fees (Add to pool revenue)
* `2`: Slot Allocation (Change user principal)
* `3`: Slot Depositor (Transfer ownership)

### Requirements for Deployment

1. **Fee Template Link:** The `feeTemplateAddress` must be set in the Router via `setFeeTemplateAddress`.
2. **Router Whitelisting:** The Router's address must be added to the `routers` mapping in **both** the `TypeCLiquidity` and `TypeCFees` contracts. Without this, the `ccUpdate` and `withdrawFees` calls will fail.