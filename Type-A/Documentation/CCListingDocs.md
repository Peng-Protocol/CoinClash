# CCListingTemplate Documentation

## Overview
The `CCListingTemplate` contract (Solidity ^0.8.2) enables decentralized trading for a token pair, leveraging Uniswap V2 for price discovery via `IERC20.balanceOf`. It manages buy/sell orders and normalized (1e18 precision) balances. **Volumes are tracked in `_historicalData` during order settlement/cancellation, with auto-generated historical data if not provided by routers.** Licensed under BSL 1.1 - Peng Protocol 2025, it uses explicit casting, avoids inline assembly, and ensures graceful degradation with try-catch for external calls.

**Version**: 0.4.2 (10/11/2025)

**Changes**:
- **v0.4.2 (10/11/2025)**: **Removed `_balances` tracker and all balance update functionality.**  
  - Deleted `mapping(address => mapping(address => Balance)) private _balances`.  
  - Deleted `struct Balance`, `struct BalanceUpdate`, and `event BalancesUpdated`.  
  - Removed `BalanceUpdate[] calldata balanceUpdates` from `ccUpdate` signature and all processing logic.  
  - **Removed `volumeBalances()` entirely** — it is now redundant. Real-time pair reserves are already accessible via `prices()` and direct `IERC20.balanceOf` queries on the Uniswap pair.  
  - Historical data (`_historicalData`) remains per-pair and continues to track `xVolume`/`yVolume` based on order fills and sends.  
  - **No stored balances** — system now fully relies on live Uniswap pair state for price and volume context.  
  - Updated `ccUpdate` to skip balance processing loop; only buy/sell order updates and historical updates are processed.  
  - Removed all references to stored balance tracking in internal logic and events.

- v0.4.1 (10/11/2025): Made historical data and balances token-pair specific. Added mapping-based storage for historical data per pair. Updated `prices()`, `volumeBalances()`, and all historical views to take token addresses as parameters. Moved balance tracking to per-pair basis.
- v0.4.0 (10/11/2025): Refactored to monolithic standalone template. Removed CCAgent dependency, added direct Uniswap Factory integration. Routers now owner-only, added token withdrawal function, `prices()` now takes token addresses and queries factory. Grouped order struct fields into arrays, added `startToken`/`endToken` to orders, removed agent references.
- v0.3.11: Updated `_processHistoricalUpdate` to use full `HistoricalUpdate` struct, removing `structId` and `value` parameters. Added `_updateHistoricalData` and `_updateDayStartIndex` helper functions for clarity. Modified `ccUpdate` to align with new `_processHistoricalUpdate` logic. Removed `uint2str` function as it’s no longer used in error messages.
- v0.3.10: Modified `ccUpdate` to accept `BuyOrderUpdate[]`, `SellOrderUpdate[]`, `BalanceUpdate[]`, `HistoricalUpdate[]` instead of `updateType`, `updateSort`, `updateData`. Replaced `UpdateType` with new structs. Updated `_processBuyOrderUpdate` and `_processSellOrderUpdate` to use direct struct fields, removing `abi.decode` and `uint2str` in errors.
- v0.3.9: Fixed `_processBuyOrderUpdate` and `_processSellOrderUpdate` to use `UpdateType` fields directly for Core updates, removing incorrect `abi.decode` of `uint2str(value)`.
- v0.3.8: Corrected `_processBuyOrderUpdate` and `_processSellOrderUpdate` to update `_historicalData.xVolume` (tokenA) with `amountSent` for buy orders and `filled` for sell orders; `yVolume` (tokenB) with `filled` for buy orders and `amountSent` for sell orders. Volume changes computed as differences.
- v0.3.5: Moved payout functionality to `CCLiquidityTemplate.sol`.
- v0.3.3: Added `resetRouters` to fetch lister via `ICCAgent.getLister`, restrict to lister, and update `_routers` with `ICCAgent.getRouters`.
- v0.3.2: Added view functions `activeLongPayoutsView`, `activeShortPayoutsView`, `activeUserPayoutIDsView`.
- v0.3.1: Added `activeLongPayouts`, `activeShortPayouts`, `activeUserPayoutIDs` to track active payout IDs. Modified `PayoutUpdate` to include `orderId`. Updated `ssUpdate` to use `orderId`, manage active payout arrays.
- v0.3.0: Bumped version.
- v0.2.25: Replaced `update` with `ccUpdate`, using `updateType`, `updateSort`, `updateData`. Removed logic in `_processBuyOrderUpdate` and `_processSellOrderUpdate` for `pending` reduction or order creation/settlement distinction.

**Compatibility**:
- CCLiquidityTemplate.sol (v0.1.9)
- CCMainPartial.sol (v0.0.14)
- CCLiquidityPartial.sol (v0.0.27)
- ICCLiquidity.sol (v0.0.5)
- ICCListing.sol (v0.0.7)
- CCOrderRouter.sol (v0.1.0)
- TokenRegistry.sol (2025-08-04)
- CCUniPartial.sol (v0.1.0)
- CCOrderPartial.sol (v0.1.0)
- CCSettlementPartial.sol (v0.1.0)

## Interfaces
- **IERC20**: Defines `decimals()`, `transfer(address, uint256)`, `balanceOf(address)`.
- **IUniswapV2Factory**: Defines `getPair(address, address)`.
- **IUniswapV2Pair**: Defines `token0()`, `token1()`.
- **ITokenRegistry**: Defines `initializeTokens(address, address[])`.
- **ICCGlobalizer**: Defines `globalizeOrders(address, address)`.

## Structs
- **HistoricalData**: `price`, `xBalance`, `yBalance`, `xVolume`, `yVolume`, `timestamp`.
- **BuyOrder**: 
  - `addresses`: `[maker, recipient, startToken, endToken]`
  - `prices`: `[maxPrice, minPrice]`
  - `amounts`: `[pending, filled, amountSent]`
  - `status`: `0: cancelled`, `1: pending`, `2: partially filled`, `3: filled`
- **SellOrder**: Same structure as `BuyOrder`.
- **BuyOrderUpdate**: `structId` (0: Core, 1: Pricing, 2: Amounts), `orderId`, `addresses`, `prices`, `amounts`, `status`.
- **SellOrderUpdate**: Same as `BuyOrderUpdate`.
- **HistoricalUpdate**: `tokenA`, `tokenB`, `price`, `xBalance`, `yBalance`, `xVolume`, `yVolume`, `timestamp`.
- **OrderStatus**: `hasCore`, `hasPricing`, `hasAmounts`.

## State Variables
- **`routers`**: `mapping(address => bool) public` — Authorized routers.
- **`routerAddresses`**: `address[] private` — Router address array.
- **`uniswapV2Factory`**: `address public` — Uniswap V2 Factory address.
- **`uniswapV2Router`**: `address public` — Uniswap V2 Router address.
- **`registryAddress`**: `address public` — Token registry address.
- **`globalizerAddress`**: `address public` — Globalizer address.
- **`nextOrderId`**: `uint256 private` — Order ID counter.
- **`_pendingBuyOrders`**, **`_pendingSellOrders`**: `uint256[] private` — Pending order IDs.
- **`makerPendingOrders`**: `mapping(address => uint256[]) private` — Maker order IDs.
- **`_historicalData`**: `mapping(address => mapping(address => HistoricalData[])) private` — Per-pair historical data.
- **`_dayStartIndices`**: `mapping(address => mapping(address => mapping(uint256 => uint256))) private` — Midnight → index per pair.
- **`buyOrders`**, **`sellOrders`**: `mapping(uint256 => BuyOrder/SellOrder) private` — Order storage.
- **`orderStatus`**: `mapping(uint256 => OrderStatus) private` — Order completeness tracking.

## Functions

### External Functions

#### setUniswapV2Factory(address _factory)
- **Purpose**: Sets Uniswap V2 Factory address (owner-only).
- **State Changes**: `uniswapV2Factory`.
- **Internal Call Tree**: None.
- **Emits**: `UniswapFactorySet`.

#### setUniswapV2Router(address _router)
- **Purpose**: Sets Uniswap V2 Router address (owner-only).
- **State Changes**: `uniswapV2Router`.
- **Internal Call Tree**: None.
- **Emits**: `UniswapRouterSet`.

#### setRegistry(address _registryAddress)
- **Purpose**: Sets token registry address (owner-only).
- **State Changes**: `registryAddress`.
- **Internal Call Tree**: None.
- **Emits**: `RegistryAddressSet`.

#### setGlobalizerAddress(address _globalizerAddress)
- **Purpose**: Sets globalizer address (owner-only).
- **State Changes**: `globalizerAddress`.
- **Internal Call Tree**: None.
- **Emits**: `GlobalizerAddressSet`.

#### addRouter(address router) / removeRouter(address router)
- **Purpose**: Manage authorized routers (owner-only).
- **State Changes**: `routers`, `routerAddresses`.
- **Internal Call Tree**: None.
- **Emits**: `RouterAdded`, `RouterRemoved`.

#### withdrawToken(address token, uint256 amount, address recipient)
- **Purpose**: Allows routers to withdraw any token or ETH held by contract.
- **State Changes**: None (external transfer).
- **Restrictions**: Router-only, sufficient balance.
- **Internal Call Tree**: `IERC20.transfer`, low-level `call`.
- **Emits**: `TokensWithdrawn`.

#### ccUpdate(
    BuyOrderUpdate[] calldata buyUpdates,
    SellOrderUpdate[] calldata sellUpdates,
    HistoricalUpdate[] calldata historicalUpdates
)
- **Purpose**: Updates buy/sell orders and historical data, callable by routers.
- **Parameters**:
  - `buyUpdates`: Array of `BuyOrderUpdate` (structId, orderId, addresses, prices, amounts, status).
  - `sellUpdates`: Array of `SellOrderUpdate` (same).
  - `historicalUpdates`: Array of `HistoricalUpdate` (per-pair price, volume, balance snapshot).
- **Logic**:
  1. Verifies router caller.
  2. Processes buy updates via `_processBuyOrderUpdate`:
     - `structId=0` (Core): Updates order metadata, manages pending arrays, emits `OrderUpdated`.
     - `structId=1` (Pricing): Updates price bounds.
     - `structId=2` (Amounts): Updates amounts, adds `filled` diff to `yVolume`, `amountSent` diff to `xVolume` in latest `_historicalData` entry.
  3. Processes sell updates via `_processSellOrderUpdate`:
     - `structId=2`: Adds `filled` diff to `xVolume`, `amountSent` diff to `yVolume`.
  4. **Removed**: Balance update loop and `BalancesUpdated` emission.
  5. Processes historical updates via `_processHistoricalUpdate`:
     - Validates price > 0.
     - Appends to per-pair `_historicalData`.
     - Updates `_dayStartIndices` if new day.
  6. Checks `orderStatus` for completeness:
     - Emits `OrderUpdatesComplete` if all parts present.
     - Emits `OrderUpdateIncomplete` with missing part.
  7. Calls `globalizeUpdate(lastMaker, lastToken)` if valid.
- **State Changes**: 
  - `buyOrders`, `sellOrders`, `orderStatus`
  - `_pendingBuyOrders`, `_pendingSellOrders`, `makerPendingOrders`
  - `_historicalData[token0][token1]`, `_dayStartIndices[token0][token1]`
- **External Interactions**: 
  - `ITokenRegistry.initializeTokens` (via `_updateRegistry`)
  - `ICCGlobalizer.globalizeOrders` (via `globalizeUpdate`)
- **Internal Call Tree**:
  - `_processBuyOrderUpdate` → `removePendingOrder`, `_updateRegistry`, `_getTokenPair`
  - `_processSellOrderUpdate` → `removePendingOrder`, `_updateRegistry`, `_getTokenPair`
  - `_processHistoricalUpdate` → `_updateHistoricalData`, `_updateDayStartIndex`, `_getTokenPair`, `_floorToMidnight`
  - `globalizeUpdate` → `ICCGlobalizer.globalizeOrders` (try/catch)
- **Emits**: 
  - `OrderUpdated`, `OrderUpdatesComplete`, `OrderUpdateIncomplete`
  - `UpdateFailed`, `ExternalCallFailed`, `RegistryUpdateFailed`, `GlobalUpdateFailed`

### View Functions
- **pendingBuyOrdersView()**, **pendingSellOrdersView()**: Return pending order ID arrays.
- **routerAddressesView()**: Returns `routerAddresses`.
- **getNextOrderId()**: Returns `nextOrderId`.
- **getBuyOrder(uint256 orderId)**, **getSellOrder(uint256 orderId)**: Return full order details.
- **makerPendingOrdersView(address maker)**: Returns maker’s pending order IDs.
- **getHistoricalDataView(address tokenA, address tokenB, uint256 index)**: Returns `HistoricalData` at index for pair.
- **historicalDataLengthView(address tokenA, address tokenB)**: Returns length of `_historicalData` for pair.
- **getDayStartIndex(address tokenA, address tokenB, uint256 midnight)**: Returns index of first entry on that day.
- **prices(address tokenA, address tokenB)**: Returns current price from Uniswap pair (tokenB/tokenA in 1e18).
- **floorToMidnightView(uint256)**, **isSameDayView(uint256, uint256)**: Utility timestamp functions.

> **Note**: `volumeBalances()` has been **removed**. Use `prices()` or direct `IERC20.balanceOf` on the Uniswap pair for real-time reserves.

### Internal Functions

#### normalize(uint256 amount, uint8 decimals) returns (uint256)
- Normalizes to 1e18. Used in `prices()` and historical data.

#### denormalize(uint256 amount, uint8 decimals) returns (uint256)
- Denormalizes from 1e18. Used in `withdrawToken`.

#### _isSameDay(uint256 time1, uint256 time2) returns (bool)
- Compares day boundaries.

#### _floorToMidnight(uint256 timestamp) returns (uint256)
- Rounds down to midnight UTC.

#### _getTokenPair(address tokenA, address tokenB) returns (address token0, address token1)
- Returns canonical (lower, higher) token ordering.

#### removePendingOrder(uint256[] storage orders, uint256 orderId)
- Removes order ID from array (swap-pop).

#### _updateRegistry(address maker, address[] memory tokens)
- Calls `ITokenRegistry.initializeTokens` with try/catch.

#### globalizeUpdate(address maker, address token)
- Calls `ICCGlobalizer.globalizeOrders` with try/catch.

#### _processBuyOrderUpdate(BuyOrderUpdate memory update)
- Updates `buyOrders[orderId]` by `structId`, manages pending lists, updates volumes in latest `_historicalData` entry.

#### _processSellOrderUpdate(SellOrderUpdate memory update)
- Same as buy, with swapped volume mapping (`filled` → `xVolume`, `amountSent` → `yVolume`).

#### _updateHistoricalData(HistoricalUpdate memory update)
- Appends to `_historicalData[token0][token1]` with normalized timestamp.

#### _updateDayStartIndex(address tokenA, address tokenB, uint256 timestamp)
- Sets `_dayStartIndices[token0][token1][midnight]` if unset.

#### _processHistoricalUpdate(HistoricalUpdate memory update) returns (bool)
- Validates price, calls helpers, returns success.

## Parameters and Interactions
- **Orders**: 
  - Buy: Input `filled` (tokenB), output `amountSent` (tokenA) → `yVolume += filled`, `xVolume += amountSent`
  - Sell: Input `filled` (tokenA), output `amountSent` (tokenB) → `xVolume += filled`, `yVolume += amountSent`
- **Price**: Computed via `IUniswapV2Factory.getPair` → `IUniswapV2Pair.token0/1` → `IERC20.balanceOf`.
- **Registry**: Updated on new pending orders via `_updateRegistry`.
- **Globalizer**: Notified on last updated maker/token.
- **Historical Data**: Per-pair, append-only, volume diffs applied on amount updates.
- **External Calls**: 
  - `IERC20.balanceOf`, `IERC20.transfer`, `IERC20.decimals`
  - `IUniswapV2Factory.getPair`, `IUniswapV2Pair.token0/1`
  - `ITokenRegistry.initializeTokens`, `ICCGlobalizer.globalizeOrders`
  - Low-level `call` for ETH withdrawal
- **Security**: 
  - Router-only `ccUpdate` and `withdrawToken`
  - Try/catch with detailed error emission
  - No stored balances — immune to sync issues
  - Explicit casting, no inline assembly
- **Optimization**: 
  - Per-pair mappings reduce gas
  - Helper functions for clarity and reuse
  - No caps on iteration — user supplies `maxIterations` in views (if added later)
  - Graceful degradation on external call failure