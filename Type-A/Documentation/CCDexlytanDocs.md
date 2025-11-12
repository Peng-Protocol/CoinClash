# CCDexlytan Contract Documentation

## Overview
CCDexlytan.sol is a view-only analytics contract for decentralized exchange data, interfacing with `CCListingTemplate` and `CCLiquidityTemplate`. It provides functions to query yield, volume, historical data indices, and price trends without modifying state. The contract has been fully refactored to support the new monolithic template architecture, where all data is token-pair-specific and liquidity is managed per-token.

## Contract Details
- **SPDX-License**: BSL 1.1 - Peng Protocol 2025
- **Solidity Version**: ^0.8.2
- **Version**: 0.1.1 (12/11)
- **Changes**:
  - (12/11/2025) v0.1.1: Fixed "Stack too deep" in `queryYield` by extracting intermediate calculations into a private struct `YieldParams`. Reduced stack usage from >16 to <10 slots. Preserved all logic and safety checks. No behavioral changes.
  - (12/11/2025) v0.1.0: Fully refactored to work with new monolithic templates.
    - Removed all references to non-existent `ICCListingTemplate` functions.
    - Replaced `liquidityDetail()` with per-token `liquidityDetailsView(address)`.
    - Replaced `dayStartFee()` with `getDayStartIndex()` + `getHistoricalDataView()` for feeAcc snapshot.
    - Added explicit `tokenA`/`tokenB` parameters to all queries.
    - All historical data now queried via token-pair-specific views.
    - Removed outdated `ICCLiquidityTemplate` interface.
    - Added helper functions: `_getLiquidityDetails`, `_getDayStartFeeAcc`.
    - Updated `queryYield`, `queryDurationVolume`, `getMidnightIndicies`, `queryPriceTrend`.

## Dependencies
- **Interfaces**:
  - `IERC20`: Retrieves token decimals (used internally in templates).
  - `ICCListingTemplate`: Provides token-pair-specific views:
    - `prices(address tokenA, address tokenB)`
    - `historicalDataLengthView(address tokenA, address tokenB)`
    - `getHistoricalDataView(address tokenA, address tokenB, uint256 index)`
    - `getDayStartIndex(address tokenA, address tokenB, uint256 midnightTimestamp)`
  - `ICCLiquidityTemplate`: Provides per-token liquidity views:
    - `liquidityDetailsView(address token)` → `(uint256 liquid, uint256 fees, uint256 feesAcc)`

## Structs
- **HistoricalData**: Stores historical price, balances, volumes, and timestamps (`price`, `xBalance`, `yBalance`, `xVolume`, `yVolume`, `timestamp`). Used internally for data consistency.
- **YieldParams** (internal): Groups intermediate variables in `queryYield` to avoid stack depth errors. Contains:
  - `xLiquid`, `yLiquid`, `xFeesAcc`, `yFeesAcc`
  - `dayStartXFeesAcc`, `dayStartYFeesAcc`
  - `feesAcc`, `dayStartFeesAcc`, `liquid`
  - `contributedFees`, `totalLiquidity`, `contributionRatio`, `feeShare`, `midnight`

## External Functions

### queryYield(
    address listingAddress,
    address liquidityAddress,
    address tokenA,
    address tokenB,
    bool isTokenA,
    uint256 depositAmount
) → uint256 yieldAnnualized
- **Purpose**: Calculates annualized yield for a simulated deposit into a token pair.
- **Parameters**:
  - `listingAddress`: Address of the `CCListingTemplate` contract.
  - `liquidityAddress`: Address of the `CCLiquidityTemplate` contract.
  - `tokenA`, `tokenB`: The two tokens in the trading pair.
  - `isTokenA`: `true` if depositing `tokenA`, `false` for `tokenB`.
  - `depositAmount`: Simulated deposit amount in native token decimals.
- **Internal Calls**:
  - `_getLiquidityDetails(liquidityAddress, token)` → fetches `liquid`, `fees`, `feesAcc` for each token.
  - `_getDayStartFeeAcc(...)` → uses `getDayStartIndex()` to locate midnight index, then falls back to current `feesAcc` if historical data unavailable.
- **Call Tree**:
  1. Early return `0` if any address is zero or `depositAmount == 0`.
  2. Load current liquidity and fee accumulators for both tokens.
  3. Compute current midnight timestamp.
  4. Fetch day-start fee accumulators via index lookup.
  5. Select side-specific values (`isTokenA`).
  6. Compute contributed fees since midnight.
  7. Calculate proportional fee share based on simulated deposit.
  8. Annualize: `(feeShare * 365 * 10000) / depositAmount` → basis points.
- **Logic**: Simulates deposit impact on fee share using current liquidity. Uses midnight fee snapshot to isolate daily fees.
- **Returns**: Annualized yield in basis points (1e4 = 100%). Returns `0` on failure, invalid inputs, or insufficient data.
- **Emits**: None (view function).

### queryDurationVolume(
    address listingAddress,
    address tokenA,
    address tokenB,
    bool isA,
    uint256 durationDays,
    uint256 maxIterations
) → uint256 volume
- **Purpose**: Approximates cumulative trading volume over a specified number of days for one side of the pair.
- **Parameters**:
  - `listingAddress`: Address of the `CCListingTemplate` contract.
  - `tokenA`, `tokenB`: The two tokens in the pair.
  - `isA`: `true` to sum `tokenA` volume (`xVolume`), `false` for `tokenB` (`yVolume`).
  - `durationDays`: Number of days to look back.
  - `maxIterations`: Maximum number of historical entries to scan (gas control).
- **Internal Calls**:
  - `historicalDataLengthView(tokenA, tokenB)` → get total entries.
  - `getHistoricalDataView(tokenA, tokenB, index)` → fetch `xVolume`, `yVolume`, `timestamp`.
- **Call Tree**:
  1. Validate `durationDays > 0` and `maxIterations > 0`.
  2. Compute time range: `[currentMidnight - durationDays, currentMidnight)`.
  3. Iterate backward from latest historical entry.
  4. For each entry in range: add `xVolume` or `yVolume` to total.
  5. Stop at `maxIterations` or end of data.
- **Logic**: Sums volume from historical data within the time window. Uses `maxIterations` to cap gas.
- **Returns**: Total volume in 1e18 normalized units. Returns `0` on failure or no data.
- **Emits**: None (view function).

### getMidnightIndicies(
    address listingAddress,
    address tokenA,
    address tokenB,
    uint256 count,
    uint256 maxIterations
) → uint256[] indices, uint256[] timestamps
- **Purpose**: Retrieves indices and timestamps of historical data entries recorded at midnight, going backward from today.
- **Parameters**:
  - `listingAddress`: Address of the `CCListingTemplate` contract.
  - `tokenA`, `tokenB`: The two tokens in the pair.
  - `count`: Maximum number of midnight entries to return.
  - `maxIterations`: Maximum number of day lookups (gas control).
- **Internal Calls**:
  - `getDayStartIndex(tokenA, tokenB, midnightTimestamp)` → returns index of first entry on that day.
- **Call Tree**:
  1. Validate `maxIterations > 0`.
  2. Start from current midnight, subtract `i * 86400` for `i = 0 to count-1`.
  3. For each day: query `getDayStartIndex`.
  4. If index > 0, store index and timestamp.
  5. Stop at `maxIterations` or `count`.
- **Logic**: Builds arrays of midnight-aligned historical indices. Uses `maxIterations` to prevent gas overflow.
- **Returns**: Parallel arrays of indices and midnight timestamps. Empty if no data.
- **Emits**: None (view function).

### queryPriceTrend(
    address listingAddress,
    address tokenA,
    address tokenB,
    uint256 durationDays,
    uint256 maxIterations
) → uint256[] prices, uint256[] timestamps
- **Purpose**: Collects price and timestamp history over a specified duration.
- **Parameters**:
  - `listingAddress`: Address of the `CCListingTemplate` contract.
  - `tokenA`, `tokenB`: The two tokens in the pair.
  - `durationDays`: Number of days to query.
  - `maxIterations`: Maximum number of historical entries to scan.
- **Internal Calls**:
  - `historicalDataLengthView(tokenA, tokenB)` → get length.
  - `getHistoricalDataView(tokenA, tokenB, index)` → fetch `price`, `timestamp`.
- **Call Tree**:
  1. Validate `durationDays > 0` and `maxIterations > 0`.
  2. Compute time range: `[currentMidnight - durationDays, currentMidnight)`.
  3. Iterate backward from latest entry.
  4. For each entry in range: collect `price` and `timestamp`.
  5. Stop at `maxIterations` or end of data.
- **Logic**: Gathers price snapshots within the time window. Respects gas limits.
- **Returns**: Parallel arrays of prices (in 1e18, tokenB per tokenA) and timestamps. Empty on failure.
- **Emits**: None (view function).

## Internal Helper Functions

### _getLiquidityDetails(address liquidityAddress, address token)
- **Purpose**: Safely fetches `liquid`, `fees`, `feesAcc` for a token.
- **Call Tree**:
  1. Return `(0,0,0)` if `liquidityAddress == address(0)`.
  2. `try` call `liquidityDetailsView(token)` → return values.
  3. `catch` → return `(0,0,0)`.
- **Returns**: `(liquid, fees, feesAcc)` or `(0,0,0)` on failure.

### _getDayStartFeeAcc(...)
- **Purpose**: Retrieves fee accumulator values at midnight.
- **Call Tree**:
  1. `try` `getDayStartIndex(...)` → get index.
  2. If index == 0 → return `(0,0)`.
  3. Fallback: use current `feesAcc` from `_getLiquidityDetails` for both tokens.
- **Returns**: `(xFeesAcc, yFeesAcc)` at midnight (approximated).
