## Running Leverage Loop Strategy Tests in Remix

This guide details the updated setup and execution of the `LoopTests.sol` contract, which simulates complex leveraged long and short strategies within mock Aave and Uniswap environments.

---

### Prerequisites and Setup

* **Contracts:** Ensure all required contracts are in your Remix workspace:
    * **Core contract:** `UADriver.sol` (The contract under test, user-defined)
    * **Mocks:** `MockDeployer.sol`, `MockMAILToken.sol`, `MockWETH.sol`, `MockUniFactory.sol`, `MockUniRouter.sol`, `MockAave.sol`, `MockAavePool.sol`, `MockAaveOracle.sol`, `MockAaveDataProvider.sol`
    * **Test contract:** `LoopTests.sol`
* **Directory Structure:** Place the core contract (`UADriver`) in your main directory. Place all mock contracts and `LoopTests.sol` in a separate directory (e.g., `./Tests`).
* **Remix Settings:**
    1.  Open Remix → [https://remix.ethereum.org](https://remix.ethereum.org).
    2.  In **Solidity Compiler**, select `^0.8.2` or newer and compile everything.
    3.  In **Deploy & Run Transactions**, select **Remix VM (Berlin)** or newer.
    4.  Ensure the default account has sufficient ETH for gas.

---

### Deployment & Initialization Order

The setup process requires deploying contracts and configuring them in a specific order, including transferring ownership of the `UADriver` to the `MockDeployer` for configuration.

| Step | Contract | Function | Description |
|:-----|:---------|:---------|:------------|
| **1.** | `UADriver` | `Deploy` | Deploy the core contract under test. |
| **2.** | `MockDeployer` | `Deploy` | Deploy the contract responsible for creating and linking all mock environments. |
| **3.** | `LoopTests` | `Deploy` | Deploy the contract that will execute the test paths. |
| **4.** | `UADriver` | `transferOwnership(MockDeployer address)` | **Crucial:** Transfer ownership of the `UADriver` to the newly deployed `MockDeployer`. |
| **5.** | `MockDeployer` | `createMocks()` | Deploys `Token18` (Mock WETH/Collateral) and `Token6` (Mock USDT/Borrow). |
| **6.** | `MockDeployer` | `createUniMocks()` | Deploys Uni mocks, creates the Token18 ↔ Token6 pair, and seeds initial liquidity (implying a **$2000 price** for Token18). |
| **7.** | `MockDeployer` | `createAaveMocks()` | Deploys Aave mocks and configures reserve properties for Token18 (WETH) and Token6 (USDT). |
| **8.** | `MockDeployer` | `setupUADriver(UADriver address)` | Calls the `UADriver`'s setter functions to configure all mock addresses (AavePool, Router, etc.). This function requires `MockDeployer` to be the owner of `UADriver`. |
| **9.** | `LoopTests` | `setDeployer(MockDeployer address)` | Caches the addresses of all mock components and the `UADriver` from the `MockDeployer`. |

---

### Test Execution Order (`LoopTests.sol`)

The tests are separated into two distinct paths: a 2x Long strategy and a 10x Short strategy. Execute each function sequentially within its path. 
### Path 1: 2x Long Strategy (Long ETH using USDT debt)

This path simulates opening a leveraged long, a price pump, and unwinding for a profit.

| Step | Function | Initial State | Target/Expected Outcome |
|------|----------|---------------|-------------------------|
| **1.1** | `p1_1_PrepareFunds()` | Clean Slate. | Mints **10 ETH** (Token18) margin and sets Oracle prices ($\text{WETH} = \$2000$, $\text{USDT} = \$1$). |
| **1.2** | `p1_2_Execute2xLong()` | 10 ETH margin. | Total position $\approx 20$ ETH. Health Factor (**HF** confirmed $>1.1$). |
| **1.3** | `p1_3_SimulatePump()` | $\text{WETH} = \$2000$. | WETH price updated to **\$2200** on Oracle and Uniswap. |
| **1.4** | `p1_4_UnwindAndVerifyProfit()` | Leveraged 20 ETH position. | Position closed. Profit check confirms $\geq 1.5$ ETH profit after slippage/fees. |

---

### Path 2: 10x Short Strategy (Short ETH, Collateral USDT)

This path tests a high-risk, high-leverage short position.

| Step | Function | Initial State | Target/Expected Outcome |
|------|----------|---------------|-------------------------|
| **2.1** | `p2_1_PrepareFunds()` | Clean Slate. | Mints **\$20,000 USDT** (Token6) margin and resets prices ($\text{WETH} = \$2000$, $\text{USDT} = \$1$). |
| **2.2** | `p2_2_Execute10xShort()` | \$20k USDT margin. | Total position $\approx \$200\text{k}$ collateral, $\approx 90$ ETH debt. |
| **2.3** | `p2_3_VerifyRisk()` | 10x Short executed. | HF must be extremely tight/low (e.g., $< 1.25$ but $> 0.99$) to confirm high-leverage risk based on the Aave reserve configuration. |

---

### Verification

* Execute each function by clicking the corresponding button on the deployed `LoopTests` contract in the **Deploy & Run Transactions** tab.
* Monitor the **Remix transaction logs** for `TestLog` and `SetupCompleted` events to track progress, Health Factor, and Profit values.
* For debugging, inspect final balances or Aave state using the getter functions on the mock contracts.