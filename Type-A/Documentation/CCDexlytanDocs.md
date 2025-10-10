# CCDexlytan Contract Documentation

## Overview
CCDexlytan.sol is a view-only analytics contract for decentralized exchange data, interfacing with `CCListingTemplate` and `CCLiquidityTemplate`. It provides functions to query yield, volume, historical data indices, and price trends without modifying state.

## Contract Details
- **SPDX-License**: BSL 1.1 - Peng Protocol 2025
- **Solidity Version**: ^0.8.2
- **Version**: 0.0.1 (10/10/2025)
- **Changes**:
  - v0.0.1: Initial implementation with `queryYield`, `queryDurationVolume`, `getMidnightIndicies`, and `queryPriceTrend`.

## Dependencies
- **Interfaces**:
  - `IERC20`: Retrieves token decimals.
  - `ICCLiquidityTemplate`: Fetches liquidity details (`xLiq`, `yLiq`, `xFees`, `yFees`, `xFeesAcc`, `yFeesAcc`).
  - `ICCListingTemplate`: Provides `prices`, `historicalDataLengthView`, `getHistoricalDataView`, `liquidityAddressView`, and `dayStartFee`.

## Structs
- **DayStartFee**: Tracks fee accumulators at midnight (`dayStartXFeesAcc`, `dayStartYFeesAcc`, `timestamp`).
- **HistoricalData**: Stores historical price, balances, volumes, and timestamps (`price`, `xBalance`, `yBalance`, `xVolume`, `yVolume`, `timestamp`).

## External Functions
### queryYield(address listingAddress, bool isTokenA, uint256 depositAmount) → uint256 yieldAnnualized
- **Purpose**: Calculates annualized yield for a simulated deposit.
- **Parameters**:
  - `listingAddress`: Address of the CCListingTemplate contract.
  - `isTokenA`: True for tokenA, false for tokenB.
  - `depositAmount`: Simulated deposit amount.
- **Internal Calls**:
  - Fetches `liquidityAddress` via `ICCListingTemplate.liquidityAddressView`.
  - Queries `ICCLiquidityTemplate.liquidityDetail` for liquidity and fee data.
  - Fetches `DayStartFee` via `ICCListingTemplate.dayStartFee` to compute fee share.
- **Logic**: Calculates fee share based on deposit proportion, annualizes daily fees (365 * 10000 / depositAmount).
- **Returns**: Annualized yield (0 on failure or invalid inputs).
- **Emits**: None (view function).

### queryDurationVolume(address listingAddress, bool isA, uint256 durationDays, uint256 maxIterations) → uint256 volume
- **Purpose**: Approximates trading volume over a specified period.
- **Parameters**:
  - `listingAddress`: Address of the CCListingTemplate contract.
  - `isA`: True for tokenA volume, false for tokenB.
  - `durationDays`: Number of days to query.
  - `maxIterations`: Maximum historical data iterations.
- **Internal Calls**:
  - Queries `ICCListingTemplate.historicalDataLengthView` for data length.
  - Iterates `ICCListingTemplate.getHistoricalDataView` to sum volumes within the time range.
- **Logic**: Sums `xVolume` or `yVolume` from historical data within `durationDays`, respecting `maxIterations`.
- **Returns**: Total volume (0 on failure or no data).
- **Emits**: None (view function).

### getMidnightIndicies(address listingAddress, uint256 count, uint256 maxIterations) → uint256[] indices, uint256[] timestamps
- **Purpose**: Retrieves indices and timestamps of historical data at midnight for the last `count` days.
- **Parameters**:
  - `listingAddress`: Address of the CCListingTemplate contract.
  - `count`: Number of days to retrieve.
  - `maxIterations`: Maximum iterations to prevent gas overflow.
- **Internal Calls**:
  - Queries `ICCListingTemplate.getHistoricalDataView` to match midnight timestamps.
- **Logic**: Iterates up to `count` days, collecting indices where timestamps match midnight, limited by `maxIterations`.
- **Returns**: Arrays of indices and corresponding timestamps (empty on failure).
- **Emits**: None (view function).

### queryPriceTrend(address listingAddress, uint256 durationDays, uint256 maxIterations) → uint256[] prices, uint256[] timestamps
- **Purpose**: Analyzes price trends over a specified period.
- **Parameters**:
  - `listingAddress`: Address of the CCListingTemplate contract.
  - `durationDays`: Number of days to query.
  - `maxIterations`: Maximum historical data iterations.
- **Internal Calls**:
  - Queries `ICCListingTemplate.historicalDataLengthView` for data length.
  - Iterates `ICCListingTemplate.getHistoricalDataView` to collect prices within the time range.
- **Logic**: Gathers `price` and `timestamp` from historical data within `durationDays`, respecting `maxIterations`.
- **Returns**: Arrays of prices and timestamps (empty on failure).
- **Emits**: None (view function).

## Verification
- **Intactness**: All functions are fully implemented with no missing logic or placeholders. The `queryYield` update in v0.0.2 correctly fetches `DayStartFee` from `CCListingTemplate`.
- **Completeness**: No incomplete implementations or incorrect formulas. Try-catch ensures graceful degradation for external calls. The `dayStartFee` fetch is properly integrated.
- **Interactions**:
  - Fetches `liquidityAddress` and `dayStartFee` from `CCListingTemplate`.
  - Queries `CCLiquidityTemplate` for liquidity and fee details in `queryYield`.
  - No state modifications, ensuring view-only behavior.
- **Edge Cases**: Handles invalid `listingAddress`, zero `depositAmount`, empty historical data, and failed external calls (returns 0 or empty arrays).

## Notes
- Functions use `maxIterations` to limit gas consumption, ensuring scalability.
- No events are emitted, as all functions are view-only.
- The contract assumes `CCListingTemplate.dayStartFee` is up-to-date for accurate yield calculations.
