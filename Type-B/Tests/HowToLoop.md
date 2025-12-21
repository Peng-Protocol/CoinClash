## Running Leverage Loop Strategy Tests in Remix (Updated Guide)

This guide details the updated setup and execution of the `LoopTests.sol` contract, which simulates complex leveraged long and short strategies using mock Aave and Uniswap environments.

---

### Prerequisites and Setup

1.  **Contracts:** Ensure all required contracts are in your Remix workspace:
    * **Core contract:** `UADriver.sol` (The contract under test, user-defined)
    * **Mocks:** `MockDeployer.sol` and supporting mocks (`MockAavePool.sol`, `MockUniRouter.sol`, etc.)
    * **Test contract:** `LoopTests.sol`
2.  **Remix Settings:**
    * In the **Solidity Compiler**, select `^0.8.2` or newer and compile everything.
    * In **Deploy & Run Transactions**, select **Remix VM (Berlin)** or newer.

---

### Deployment & Initialization Order

The setup requires deploying contracts and configuring them in a specific order, including the mandatory step of **transferring ownership of the `UADriver` to the `MockDeployer`** for system initialization.

| Step | Contract | Action / Function | Description |
| :--- | :--- | :--- | :--- |
| **1.** | `UADriver` | `Deploy` | Deploy the core contract under test. |
| **2.** | `MockDeployer` | `Deploy` | Deploy the contract that manages the mock environment setup. |
| **3.** | `LoopTests` | `Deploy` | Deploy the test execution contract. |
| **4.** | `UADriver` | `transferOwnership(MockDeployer address)` | **Crucial Manual Step:** Call the `transferOwnership` function on the deployed **`UADriver`** contract, passing the address of the deployed **`MockDeployer`**. |
| **5.** | `MockDeployer` | `createMocks()` | Deploys `Token18` (Mock WETH) and `Token6` (Mock USDT). |
| **6.** | `MockDeployer` | `createUniMocks()` | Deploys Uni mocks, creates the Token18 ↔ Token6 pair, and seeds liquidity (implying a **$2000 price** for Token18). |
| **7.** | `MockDeployer` | `createAaveMocks()` | Deploys Aave mocks, configures reserve properties (e.g., WETH LTV 80%, LT 82.5%), and funds the pools. |
| **8.** | `MockDeployer` | `setupUADriver(UADriver address)` | **Configures the Driver:** This function sets all mock addresses within the `UADriver` contract. This step **requires** the `MockDeployer` to be the owner (as done in Step 4). |
| **9.** | `LoopTests` | `setDeployer(MockDeployer address)` | **Final Setup:** This call fetches and caches all configured addresses, including the `UADriver` address, from the `MockDeployer`. |

---

### Test Execution Order (`LoopTests.sol`)

The tests are separated into two main paths. Execute the functions sequentially within each path.

### Path 1: 2x Long Strategy (Long ETH using USDT debt)
Objective: Achieve 2x leverage on an initial 10 ETH margin and verify profit after a simulated price pump.

| Step | Function | Key Action & Verification |
| :--- | :--- | :--- |
| **1.1** | `p1_1_PrepareFunds()` | Mints **10 ETH** (Token18) to the test contract and sets Oracle prices: WETH = $2000, USDT = $1. |
| **1.2** | `p1_2_Execute2xLong()` | Executes the leveraged loop with a **2.0x target** and a minimum Health Factor (HF) of 1.1. Verification: Collateral is approximately 20 ETH. |
| **1.3** | `p1_3_SimulatePump()` | Simulates a market pump: WETH price is updated to **$2200** (+10%) on the Oracle and the Uniswap pair. |
| **1.4** | `p1_4_UnwindAndVerifyProfit()` | Closes the loop position (Repay All, Withdraw All). Verification: Final profit is checked to be >1.5 ETH after fees and slippage. |

---

### Path 2: 3.5x Short Strategy (Short ETH, Collateral USDT)
Objective: Execute an extremely high-leverage short position to test risk parameters.

| Step | Function | Key Action & Verification |
| :--- | :--- | :--- |
| **2.1** | `p2_1_PrepareFunds()` | Mints **$1000 USDT** (Token6) margin and resets prices to WETH = $2000, USDT = $1$. |
| **2.2** | `p2_2_Execute3_5xShort()` | Executes the leveraged loop with a **3.5x target**. The position is highly volatile. |
| **2.3** | `p2_3_VerifyRisk()` | Checks the resulting risk profile. Verification: Health Factor must be **low (e.g., HF < 1.25)** to confirm high-leverage risk, but must be above the liquidation threshold **(HF > 0.99)**. |

### Verification

* Execute each function by clicking the corresponding button on the deployed `LoopTests` contract in the **Deploy & Run Transactions** tab.
* Monitor the **Remix transaction logs** for `TestLog` and `SetupCompleted` events to track progress, Health Factor, and Profit values.
* For debugging, inspect final balances or Aave state using the getter functions on the mock contracts.