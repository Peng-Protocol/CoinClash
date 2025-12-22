This Markdown document outlines the strategic pivot from **Aave V3** to **Euler V2** for the `UADriver` automated debt-looping system. This move is driven by the need for greater decentralization, permissionless market creation, and the ability to execute high-leverage strategies (e.g., 10x) that are restricted by Aave’s governance-led risk parameters.

---

# Refactoring UADriver: Transitioning to Euler V2

## 1. Rationale for Refactoring

The current `UADriver` is built on a "Monolithic" architecture that relies on **Aave V3** as the primary liquidity and credit layer. While secure, this dependency introduces several bottlenecks:

* 
**Governance Constraints:** Aave’s Loan-to-Value (LTV) ratios are set by a DAO and professional risk providers. For standard pairs like ETH/USDT, these are capped at ~75-80%, strictly limiting leverage to 4x–5x.


* 
**Centralized Risk Management:** The "Shared Pool" model means every asset’s risk affects the entire protocol, leading to conservative parameters that hinder aggressive trading strategies.


* 
**Oracle Dependency:** Aave requires professional oracle networks (Chainlink), which, while robust, can be slow to update for new or volatile assets, preventing permissionless listing.



## 2. Refactoring Objectives

Our primary goal is to leverage **Euler V2’s Modular Architecture** to create a more flexible and powerful looping driver.

### A. Permissionless Market Creation

Unlike Aave, which requires a governance vote for every new asset, Euler V2 allows us to use the **Euler Vault Kit (EVK)** to deploy custom lending vaults for any pair instantly.

* **Objective:** Enable `UADriver` to make use of "High-Leverage" vaults without waiting for DAO approval.

### B. Achieving 10x Leverage via High LTV Pools

Our target for `LoopTests` **Path 2 (Short Strategy)** is 10x leverage. On Aave, a 75% LTV makes this mathematically impossible ().

* **Objective:** Create "Realistic but Aggressive" pools on Euler with **90%–95% LTV**.
* **Rationale:** By siloing risk into isolated vaults, we can offer higher LTVs to sophisticated users without endangering the rest of the protocol's liquidity.

### C. Fund Segregation (Siloed Risk)

We intend to move from Aave’s "Shared Fate" model to Euler’s **Isolated Vault** model.

* 
**Objective:** Refactor the internal `_executeLoopCycles` logic to interact with specific Euler Vaults via the **Ethereum Vault Connector (EVC)**.


* **Security:** This ensures that even if a high-leverage 10x pool experiences bad debt or oracle manipulation, the contagion is physically contained within that specific vault.

## 3. Implementation Plan

| Step | Action | Description |
| --- | --- | --- |
| **1** | **Interface Update** | Replace Aave `IPool` and `IAaveProtocolDataProvider` with Euler `IEVault` and `IEVC` interfaces.

 |
| **2** | **Vault Integration** | Modify `executeLoop` to accept a `vaultAddress` instead of just asset addresses, allowing the driver to target specific high-LTV silos.

 |
| **3** | **Logic Refactor** | Update `_calculateLoopBorrow` to use Euler’s vault-specific LTV and health factor logic instead of Aave’s global account data.

 |
| **4** | **Deployment Script** | (For `LoopTests`) Create a script using Euler's Factory to automatically deploy a USDT/WETH vault with a 91% LTV to support the 10x test case. |

## 4. Why This Matters

By shifting to Euler V2, we are moving from a **Governed Risk** model to a **Market-Driven Risk** model. This allows `UADriver` to fulfill its purpose as a high-performance leverage tool, providing users with the "permissionless freedom" that modern DeFi demands while maintaining the security of fund segregation.

## 5. Test Environment 
Ignore this if working on `UADriver` directly, these are considerations for the new `LoopTests` suite of unit tests. 

### A. Oracle Agnostic Design

In Euler v2, each vault curator (you, in this case) chooses the oracle. The protocol supports:

* **Chainlink** (Standard push-based)
* **Pyth & Redstone** (On-demand/pull-based)
* **Uniswap v3 TWAPs** (The legacy Euler v1 favorite)
* **Custom Adapters:** This is where **Uniswap v2** comes in. Euler uses an **IPriceOracle** interface. If you want to use a Uniswap v2 TWAP, you would use (or deploy) a simple adapter that queries the `price0CumulativeLast` and `price1CumulativeLast` from the Uni v2 pair.

### B. Implementing it in your Refactor

When you refactor the `UADriver` to target Euler, you won't be hard-coding a price source. Instead, you'll be interacting with an **EVault** that has been pre-configured with an oracle.

If you want to simulate this in your test environment:

1. **Deploy a Mock Euler Vault** using the EVK.
2. **Attach a Mock Uni v2 Oracle Adapter** (This will look very similar to the `MockAaveOracle` you currently have, but it will fetch from your `MockUniRouter` or `MockUniPair`).
3. **Set LTV to 91%** on that specific vault.

**Verdict:** Euler v2 is the perfect "playground" for your strategy because it doesn't care if you use a "risky" Uniswap v2 feed—as long as the vault is isolated, the only person who suffers if it's manipulated is the person who chose to lend into that specific 10x-friendly vault.