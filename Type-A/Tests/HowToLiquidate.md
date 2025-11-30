# Running CoinClash Liquid & Liquidity Routers Tests in Remix – LiquidTests.sol

## Prerequisites
Ensure the following contracts are in your Remix workspace:

**Core contracts** (main directory):
- `CCListingTemplate.sol`
- `CCOrderRouter.sol`
- `CCSettlementRouter.sol`
- `CCLiquidRouter.sol`
- `CCLiquidityRouter.sol`
- `CCLiquidityTemplate.sol`

**Mocks & Tests** (preferably in a `./Tests` folder):
- `MockMAILToken.sol`
- `MockMailTester.sol`
- `MockWETH.sol`
- `MockUniFactory.sol` + `MockUniRouter.sol` (already used)
- `LiquidTests.sol` ← the new comprehensive liquidity test suite (provided in the previous message)

## Setup Steps (Remix)

1. Open https://remix.ethereum.org
2. Compile everything with Solidity `^0.8.2`
3. Select **Remix VM (London or later)**
4. Make sure the deploying account has ≥ 10 ETH (tests fund the tester + native deposits)

### Deployment & Initialization Order

5. Deploy the core system (any order is fine):
   - `CCLiquidityTemplate`
   - `CCListingTemplate`
   - `CCOrderRouter`
   - `CCSettlementRouter`
   - `CCLiquidRouter`
   - `CCLiquidityRouter`

6. Deploy **`LiquidTests`** (this contract will own everything during testing)

7. Transfer ownership of **all** core contracts to the `LiquidTests` address:
   - Call `transferOwnership(liquidTestsAddress)` on:
     - `CCLiquidityTemplate`
     - `CCListingTemplate`
     - `CCOrderRouter`
     - `CCSettlementRouter`
     - `CCLiquidRouter`
     - `CCLiquidityRouter`

### Call these functions on the deployed `LiquidTests` contract (in this order)

8. **`deployUniMocks()`**  
   → Deploys MockWETH, MockUniFactory, MockUniRouter

9. Set the router/template addresses (granular setters – any order):
   - `setOrderRouter(CCOrderRouter_address)`
   - `setSettlementRouter(CCSettlementRouter_address)`
   - `setLiquidRouter(CCLiquidRouter_address)`
   - `setLiquidityRouter(CCLiquidityRouter_address)`
   - `setListingTemplate(CCListingTemplate_address)`
   - `setLiquidityTemplate(CCLiquidityTemplate_address)`

10. **`initializeContracts()`** (can be called multiple times safely)  
    → Adds missing routers, sets WETH/factory/router, creates the Token18↔Token6 pair once

11. **`initiateTester()`** → send **3 ETH value** (≥ 3 ETH)  
    → Deploys `MockMailTester`, funds it with 2 ETH, mints 1000 TK18 + 1000 TK6 to tester

You are now fully ready to run all liquidity & liquid-settlement tests.

## Test Execution Order (LiquidTests.sol)

All paths assume the above setup is complete.

| Path | Function(s)                                 | Purpose                                                                                 | Expected Outcome                                            |
|------|---------------------------------------------|-----------------------------------------------------------------------------------------|-------------------------------------------------------------|
| **D1** | `d1_1DepositToken18()`                      | Basic ERC20 deposit → creates new slot                                                  | Slot created, allocation > 0                                 |
|      | `d1_2ZeroDepositMustFail()`                 | Zero deposit must revert                                                                | Reverts correctly                                           |
| **D2** | `d2_1DepositForWithdrawal()` → `d2_2PartialWithdrawal()` → `d2_3FullWithdrawalClearsSlot()` → `d2_4ZeroWithdrawalMustFail()` | Partial & full withdrawal behaviour, slot clearing                                      | Partial keeps slot, full sets allocation=0, zero withdraw reverts |
| **D3** | `d3_1TesterDeposit()` → `d3_2ContractDeposit()` → `d3_3VerifyIndependentSlots()` | Multi-user deposits remain isolated                                                     | Two separate slots with correct depositors                  |
| **D4** | `d4_1SetupForCompensation()` → `d4_2WithdrawWithCompensation()` | Withdrawal with compensation token (other side of pair)                                 | User receives compensationAmount of the other token         |
| **D5** | `d5_1CreateOrderAndSettle()` → `d5_2SettleViaLiquidRouter()` → `d5_3ClaimFees()` | Generate fees via liquid settlement → claim them                                        | Fees accrue → successfully claimed by depositor             |
| **D6** | `d6_1DepositForTransfer()` → `d6_2TransferOwnership()` | Slot ownership transfer via `changeDepositor`                                           | Slot depositor changes, old owner loses index               |
| **L1** | `l1_1CreateOrderForLiquidSettlement()` → `l1_2FullLiquidSettle()` | Full liquid settlement of a normal-sized buy order                                      | Order moves Pending (1) → Filled (3)                        |
| **L2** | `l2_1CreateLargeOrder()` → `l2_2PartialSettleViaSettlementRouter()` → `l2_3CompleteLiquidSettle()` | Partial settle via normal router → liquid router finishes the rest                     | Status Partial (2) → Filled (3)                             |
| **L3** | `l3_1DepositHeavyLiquidity()` → `l3_2CreateHighImpactOrder()` | Massive order that would cause >10% price impact                                        | Liquid settlement skips it → order stays Pending (1)        |

### Running the Tests
- Execute the functions in the order above (or any order after full setup).
- Watch Remix logs for:
  - `TestPassed(string)` → confirms each individual test succeeded
  - `DebugLiquidity` & `DebugSlot` → helpful for manual inspection
- You can always query slots manually:
  ```solidity
  liquidityTemplate.userSlotIndicesView(token, user)
  liquidityTemplate.getSlotView(token, slotIndex)
  liquidityTemplate.liquidityDetailsView(token)```