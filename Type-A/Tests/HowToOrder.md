# Running CoinClash OrderRouter Tests in Remix

## Prerequisites
- Ensure the following contracts are in your Remix workspace:
    - `CCOrderRouter.sol`, `CCListingTemplate.sol`
    - `OrderTests.sol`
    - Mock Contracts: `MockMAILToken.sol`, `MockMailTester.sol`, `MockWETH.sol`, `MockUniFactory.sol`, `MockUniPair.sol`
- Place core contracts in your main directory.
- Place mocks and `OrderTests.sol` in `./Tests`.

## Setup Steps
1. Open Remix [https://remix.ethereum.org](https://remix.ethereum.org).
2. Upload all contracts to the specified directories.
3. In "Solidity Compiler", select `^0.8.2` and compile all.
4. In "Deploy & Run Transactions", select **Remix VM**.
5. Ensure the default account has **at least 3 ETH** (for setup and liquidity).
6. **Deploy the core system contracts first** (in any order):
   - Deploy `CCListingTemplate`
   - Deploy `CCOrderRouter`
7. Deploy `OrderTests` using the default account. Transfer ownership of core system contracts to `OrderTests`.

### Initialization Sequence (Call these functions on `OrderTests`)
8. Call **`deployUniMocks()`**:
   - Deploys the `MockWETH` and `MockUniFactory` contracts.
9. Call **`setCCContracts(routerAddr, listingAddr)`**:
   - Paste the **exact addresses** of the deployed `CCOrderRouter` and `CCListingTemplate` contracts.
10. Call **`initializeContracts()`** with a **Value of 2 ETH** (or more):
   - This sets up all cross-references (Router in Template, Template in Router).
   - This creates the required liquidity pairs: `WETH/Token18`, `WETH/Token6`, and `Token18/Token6`.
11. Call **`initiateTester()`** with a **Value of 1 ETH**:
    - This deploys a `MockMailTester` (called `tester`).
    - It funds the `tester` with 1 ETH, `TOKEN18_AMOUNT` (100 * 1e18), and `TOKEN6_AMOUNT` (100 * 1e6).

## Test Execution Order

### Path 1 – Token-to-Token Order Lifecycle (Token6/Token18)
- All calls in this path are proxied through the `tester` account.

| Function | Action | Expected Outcome |
| :--- | :--- | :--- |
| **`p1_1TestBuyTokenBtoA()`** | Create a Buy order: Pay with 10 Token6 (6 decimals), Receive Token18 (18 decimals). | Order created and placed in the pending list. The input amount (Token6) is normalized to 18 decimals and stored as `pending`. |
| **`p1_2TestSellTokenAtoB()`** | Create a Sell order: Sell 10 Token18 (18 decimals), Receive Token6 (6 decimals). | Order created and placed in the pending list. The Token18 is transferred and stored as `pending`. |
| **`p1_3TestCancelTokenBuyOrder()`** | Cancel the Token6 Buy Order (`p1BuyOrderId`) created in P1-1. | Order status set to `0` (Cancelled). Pending Token6 is refunded to the `tester`. |
| **`p1_4TestCancelTokenSellOrder()`** | Cancel the Token18 Sell Order (`p1SellOrderId`) created in P1-2. | Order status set to `0` (Cancelled). Pending Token18 is refunded to the `tester`. |

### Path 2 – ETH-to-Token Order Lifecycle (ETH/Token)

| Function | Action | Expected Outcome |
| :--- | :--- | :--- |
| **`p2_1TestBuyTokenAtoETH()`** | Create a Buy order: Pay with 0.1 ETH (`address(0)`), Receive Token18. | Order created. 0.1 ETH is transferred via `msg.value` and stored as pending. |
| **`p2_2TestSellTokenBtoETH()`** | Create a Sell order: Sell 10 Token6, Receive ETH (`address(0)`). | Order created. Token6 is transferred and stored as pending, amount is normalized. |
| **`p2_3TestCancelETHBuyOrder()`** | Cancel the ETH Buy Order (`p2BuyOrderId`) created in P2-1. | Order status set to `0` (Cancelled). Pending ETH is refunded to the `tester`. |
| **`p2_4TestCancelETHSellOrder()`** | Cancel the Token6 Sell Order (`p2SellOrderId`) created in P2-2. | Order status set to `0` (Cancelled). Pending Token6 is refunded to the `tester`. |

### Path 3 – Batch Operations

| Function | Action | Expected Outcome |
| :--- | :--- | :--- |
| **`s8_TestClearOrdersMultiple()`** | Creates 3 new Buy Orders from the `tester` and then calls `clearOrders(10)` from the `tester`. | All 3 orders are cancelled. The `makerPendingOrdersView(tester)` returns an empty array, and all tokens are refunded. |

### Sad Path Tests (Expect Revert/Failure)
- These tests are designed to assert that the contract reverts when called incorrectly.

| Function | Action | Expected Revert/Failure |
| :--- | :--- | :--- |
| **`s1_TestStartEndSame()`** | Attempt to create an order where `startToken == endToken`. | Transaction reverts. |
| **`s2_TestBuyOrderNativeEndToken()`** | Attempt to call `createBuyOrder` with both `startToken` and `endToken` as `address(0)` (ETH). | Transaction reverts. |
| **`s3_TestCreateOrderZeroAmount()`** | Attempt to create an order with an `inputAmount` of zero. | Transaction reverts. |
| **`s4_TestCreateOrderIncorrectETHAmount()`** | Attempt to create a Buy Order (starting with ETH) but send insufficient ETH via `msg.value`. | Transaction reverts. |
| **`s5_TestCancelOrderNotMaker()`** | An address other than the order maker attempts to cancel the order. | Transaction reverts. |
| **`s6_TestCancelAlreadyClearedOrder()`** | Attempt to clear an order that has already been set to `Cancelled` status. | Transaction reverts, or the test asserts that no funds were unexpectedly refunded. |

### Final Step
- Call **`returnOwnership()`** (as the original owner) to transfer ownership of `CCListingTemplate` back to the deployer if desired.
