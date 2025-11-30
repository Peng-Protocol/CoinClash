# Running CoinClash Settlement Tests in Remix

## Prerequisites
- Ensure the following contracts are in your Remix workspace:
  - Core contracts: `CCOrderRouter.sol`, `CCSettlementRouter.sol`, `CCListingTemplate.sol`
  - Mock contracts: `MockMAILToken.sol`, `MockMailTester.sol`, `MockWETH.sol`, `MockUniFactory.sol`, `MockUniPair.sol`
  - Test contract: `SettlementTests.sol` (provided below)
- Place core contracts in your main directory.
- Place mocks and `SettlementTests.sol` in `./Tests`.

## Setup Steps
1. Open Remix → https://remix.ethereum.org
2. Upload all contracts to the directories above.
3. In **Solidity Compiler**, select `^0.8.2` and compile everything.
4. In **Deploy & Run Transactions**, select **Remix VM (Berlin)** or newer.
5. Ensure the default account has **at least 5 ETH** (used for liquidity & tester funding).

### Deployment & Initialization Order
6. If not already deployed, deploy the core system contracts (any order):
   - `CCListingTemplate`
   - `CCOrderRouter`
   - `CCSettlementRouter`
7. Deploy `SettlementTests` (this contract should own everything during testing).
8. Transfer ownership of the three core contracts to the deployed `SettlementTests` instance:
   - Call `transferOwnership(settlementTestsAddress)` on each of `CCListingTemplate`, `CCOrderRouter`, and `CCSettlementRouter`.

### Call these functions on the deployed `SettlementTests` contract
9. **`deployUniMocks()`**  
   Deploys `MockWETH`, `MockUniFactory` and `MockUniRouter`.

10. Call the **three new granular setters** on `SettlementTests` (in any order):
  - setOrderRouter(CCOrderRouter address)
  
   - setSettlementRouter(CCSettlementRouter address)
   - setListingTemplate(CCListingTemplate address)

11. Call **`initializeContracts()`**
    This function is now **state aware**:
    - Adds routers to ListingTemplate only if missing
    - Sets `listingTemplate`, `wethAddress`, factory, and router only if still zero
    - Creates the Token18 ↔ Token6 pair only once
    - Safe to call repeatedly (perfect for Remix pinning workflow).

12. **`initiateTester()`** (send 3 ETH value)  
    - Deploys `MockMailTester` (the `tester` account used in all paths)  
    - Mints 1000 Token18 + 1000 Token6 to tester  
    - Funds tester with 2 ETH
    - Keeps 1 ETH. 

You are now ready to run settlement tests.

## Test Execution Order (SettlementTests.sol)

All settlement paths assume the above setup is complete.

| Path | Function | Purpose | Expected Outcome |
|------|----------|--------|-------------------|
| **Path 1** | `p1_1CreateOrder()` | Creates a Buy order (Token6 → Token18) with mixed decimals | Order created, input correctly normalized to 18 decimals |
|      | `p1_2FullSettleWithZeroCheck()` | Tries to settle with 0 → fails, then full settles | Zero-amount settle skipped, full settle marks order Filled (status 3) |
| **Path 2** | `p2_1CreateOrder()` | Creates larger Buy order | Pending order |
|      | `p2_2PartialSettleWithTransitionChecks()` | Settles 20% twice | Status transitions Pending → Partial (2), cumulative filled increases |
| **Path 3** | `p3_1CreateOrders()` | Creates 3 separate Buy orders | 3 pending orders |
|      | `p3_2FullSettleAll()` | Batch full-settles all 3 in one call | All orders status 3 (Filled) |
| **Path 4** | `p4_1CreateOrders()` | Creates another 3 Buy orders | 3 pending orders |
|      | `p4_2PartialSettleAll()` | Batch partial-settles (50% each) | All orders status 2 (Partial) |
| **Path 5** | `p5_1CreateOrder()` | Creates large 100 Token6 order | Pending |
|      | `p5_2Round1Settle()` → `p5_3Round2RecoverOriginal()` → `p5_4FinalSweep()` | Multi-round partial → final sweep | Progressively reduces pending, final sweep sets status 3 |
| **Path 6 – Seesaw Price Impact** | `p6_1CreateRestrictedOrder()` | Creates Buy order with tight min/max price range (±25%) | Pending order with price bounds |
|      | `p6_2CrashPriceAndFail()` | Dumps massive Token6 → price crashes below minPrice | Settlement skipped (order stays Pending) |
|      | `p6_3RecoverPriceAndSucceed()` | Adds Token18 back → price recovers into range | Settlement succeeds → order Filled |
| **Path 7 – Impact ** | `p7_1CreateHighImpactOrder()` | Creates an order with relatively large principal | order cannot be settled due to price impact |
|      | `p7_2AttemptImpactSettlement()` | Attempts to settle the order expecting it to be skipped | Order still active, settlement degrades gracefully with error message |

### Running the Tests
- Watch the Remix transaction logs for `TestPassed`, `OrderSettled`, and `DebugPrice` events.
- Manually inspect orders by fetching `p#_orderId` or `p#_order#` on `SettlementTests` then querying `getBuyOrder` or `getSellOrder` on the `CCListingTemplate`. 