# Running CoinClash Liquid & Liquidity Router Tests in Remix 

## Required Files
Place all in your Remix workspace:

**Core contracts**  
- `CCListingTemplate.sol`  
- `CCOrderRouter.sol`  
- `CCSettlementRouter.sol`  
- `CCLiquidRouter.sol`  
- `CCLiquidityRouter.sol`  
- `CCLiquidityTemplate.sol`  

**Mocks & Tests** (preferably in `./Tests` folder)  
- `MockDeployer.sol` ← new central mock factory  
- `MockMAILToken.sol`, `MockMailTester.sol`, `MockWETH.sol`, `MockUniFactory.sol`, `MockUniRouter.sol`  
- `LiquidTests.sol` ← updated test suite (no mock imports)

## Step-by-Step Setup (Remix VM)

1. Compile everything with Solidity `^0.8.2`  
2. Use **Remix VM (London or later)** – ensure deployer has ≥10 ETH  

### Deployment Order

3. Deploy **all core contracts** (any order):  
   `CCLiquidityTemplate`, `CCListingTemplate`, `CCOrderRouter`, `CCSettlementRouter`, `CCLiquidRouter`, `CCLiquidityRouter`

4. Deploy **MockDeployer** 

5. Deploy **LiquidTests**

6. Link them together:  
   ```solidity
   // On MockDeployer
   mockDeployer.setLiquidTests(liquidTestsAddress);

   // On LiquidTests
   liquidTests.setMockDeployer(mockDeployerAddress);

   // Set core addresses
   liquidTests.setOrderRouter(orderRouterAddr);
   liquidTests.setSettlementRouter(settlementRouterAddr);
   liquidTests.setLiquidRouter(liquidRouterAddr);
   liquidTests.setLiquidityRouter(liquidityRouterAddr);
   liquidTests.setListingTemplate(listingTemplateAddr);
   liquidTests.setLiquidityAddress(liquidityTemplateAddr);
   ```

### One-Click Initialization

7. Call on **LiquidTests** (in this exact order):

   ```solidity
   liquidTests.deployMocks();           // → token18 & token6
   liquidTests.deployUniMocks();        // → WETH, factory, router, pair + liquidity
   liquidTests.initiateTester{value: 2 ether}();  // → deploys & funds MockMailTester
   liquidTests.initializeContracts();  // adds routers, sets WETH/factory, creates pair once
   ```

   → You are now fully set up!

### Test Execution

| Test | Function                     | Purpose                                      |
|------|------------------------------|----------------------------------------------|
| 1    | `test1_InitialDeposit()`     | Basic deposit + slot creation                |
| 2    | `test2_PartialWithdrawal()`  | Partial withdraw keeps slot                  |
| 3    | `test3_WithdrawalWithCompensation()` | Withdraw with opposite token compensation |
| 4    | `test4_FullWithdrawal()`     | Full withdraw clears slot                    |
| 5    | `test5_DepositForSettlement()` | Deposit both sides for settlement         |
| 6    | `test6_CreateAndPartialSettle()` | Create order → partial settle with Settlement Router         |
| 7    | `test7_LiquidSettlement()`   | Liquid router finishes the rest and adds fees       |
| 8    | `test8_CollectFees()`        | Claim accrued fees                           |
| 9    | `test9_TransferOwnership()`  | Slot depositor transfer                      |
|10    | `test10_FinalWithdrawalByNewOwner()` | New owner withdraws                  |
|11    | `test11_DepositHeavyLiquidity()` | Heavy liquidity for impact test          |
|12    | `test12_CreateHighImpactOrder()` | Order rejected due to impact exceeding order bounds        |