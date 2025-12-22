## Running Euler Leverage Loop Strategy Tests in Remix

This guide explains how to set up and execute the `EulerLoopTests.sol` contract. This environment simulates leveraged long and short strategies using a mock Euler Vault Connector (EVC) and Uniswap ecosystem.

---

### Prerequisites and Setup

1. **Contracts:** Ensure the following files are in your Remix workspace:
* **Core contract:** `UEDriver.sol` (The Euler-specific driver under test).
* **Mocks:** `MockEuler.sol`, `MockEulerDeployer.sol`, and other supporting mocks (`MockMAILToken.sol`, etc.).
* **Test contract:** `EulerLoopTests.sol`.


2. **Remix Settings:**
* **Solidity Compiler:** Select version `0.8.20` or newer to match the Euler mock requirements.
* **Deploy & Run Transactions:** Use **Remix VM (Cancun)** or a similar modern environment.



---

### Deployment & Initialization Order

To initialize the testing environment correctly, you must deploy the contracts and configure the dependencies in this specific order.

| Step | Contract | Action / Function | Description |
| --- | --- | --- | --- |
| **1.** | `UEDriver` | `Deploy` | Deploy the driver contract. |
| **2.** | `MockEulerDeployer` | `Deploy` | Deploy the utility contract that manages mock setup. |
| **3.** | `EulerLoopTests` | `Deploy` | Deploy the test execution contract. |
| **4.** | `MockEulerDeployer` | `createMocks()` | Deploys `Token18` (Mock WETH) and `Token6` (Mock USDT). |
| **5.** | `MockEulerDeployer` | `createUniMocks()` | Deploys Uniswap mocks and seeds liquidity at a **$2000 ETH price**. |
| **6.** | `MockEulerDeployer` | `createEulerMocks()` | Deploys the Mock EVC, Oracle, and the WETH/USDT Vaults. |
| **7.** | `MockEulerDeployer` | `setupUEDriver(UEDriver address)` | Configures the `UEDriver` with the EVC, Oracle, and Router addresses. |
| **8.** | `EulerLoopTests` | `setDeployer(MockEulerDeployer address)` | Links the test contract to the environment and caches all necessary addresses. |

---

### Test Execution Order (`EulerLoopTests.sol`)

The tests follow two distinct strategy paths. Execute the functions within each path sequentially.

#### Path 1: 2x Long Strategy (Long ETH using USDT debt)

**Objective:** Use 10 ETH initial margin to achieve 2x leverage ($40,000 exposure) and capture profit after a price pump.

| Step | Function | Key Action & Verification |
| --- | --- | --- |
| **1.1** | `p1_1_PrepareFunds()` | Mints 10 WETH and sets Oracle prices to $2000/WETH and $1/USDT. |
| **1.2** | `p1_2_Execute2xLong()` | Loops into the position. Verification: Collateral should reach ~20 ETH with a Health Factor > 1.1. |
| **1.3** | `p1_3_SimulatePump()` | Updates Oracle to **$2200** (+10%) and performs a Uniswap swap to align the pool price. |
| **1.4** | `p1_4_UnwindAndVerifyProfit()` | Closes the position. Verification: Final WETH balance should show a profit of **> 1.5 ETH**. |

#### Path 2: 10x Short Strategy (Short ETH using USDT collateral)

**Objective:** Test high-leverage boundaries (10x) by borrowing WETH against USDT collateral.

| Step | Function | Key Action & Verification |
| --- | --- | --- |
| **2.1** | `p2_1_PrepareFunds()` | Mints **$2,000 USDT** margin and resets prices to $2000/WETH. |
| **2.2** | `p2_2_Execute10xShort()` | Executes the loop with 10x target leverage. This is high-risk and near the liquidation threshold. |
| **2.3** | `p2_3_VerifyRisk()` | Verifies the position exists. Health Factor (HF) must be **low (< 1.25)** but still solvent (> 0.99). |

---

### Verification and Debugging

* **Logs:** Check the **Remix Console** after each transaction. Look for `TestLog` events to see real-time Health Factors and profit calculations.
* **Errors:** If a transaction fails, look for the `DebugError` event which captures the revert string from the Driver.
* **Vault State:** You can call `balanceOf` or `debtOf` directly on the `MockEVault` addresses (found in the `EulerLoopTests` state) to verify user balances manually.