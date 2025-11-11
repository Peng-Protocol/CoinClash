# CCLiquidityRouter Contract Documentation

## Overview
The `CCLiquidityRouter` contract, written in Solidity (^0.8.2), facilitates liquidity management on a decentralized trading platform, handling deposits, withdrawals, fee claims, and depositor changes. It inherits `CCLiquidityPartial` (v0.2.2) and interacts directly with `ICCListing` (v0.0.7), `ICCLiquidity` (v0.0.4), and `CCLiquidityTemplate` (v0.0.20). It uses `ReentrancyGuard` for security. State variables are accessed via `ICCLiquidity` view functions. All amounts are normalized to 1e18 decimals using token-specific `normalize`/`denormalize` functions.

**SPDX License**: BSL 1.1 - Peng Protocol 2025

**Version**: 0.2.0 (Updated 2025-11-11)

**Changes Since Last MD Version (v0.1.15 → v0.2.0)**:
- **v0.2.0 (11/11)**: Complete architectural overhaul from dual-token (x/y) to **token-agnostic** design. Removed `isTokenA`/`isX` boolean flags. All functions now accept explicit `token` and `compensationToken` addresses. `listingAddress` parameter removed from all router functions — replaced by `liquidityAddress` (direct reference to `ICCLiquidity` template). `CCMainPartial` dependency eliminated. `CCLiquidityPartial` now operates on arbitrary token pairs via per-token slot arrays in `CCLiquidityTemplate`.
- **v0.2.1 (11/11)**: Added `compensationToken` parameter to `withdraw`. Introduced pair existence validation via `IUniswapV2Factory.getPair`. Price-based conversion of `compensationAmount` into primary token allocation using `ICCListing.prices(tokenA, tokenB)`. All withdrawal logic now supports cross-token compensation with normalized allocation accounting.
- **v0.2.2 (11/11)**: **Stack-too-deep resolution via x64 decomposition** in `_prepWithdrawal`. Split into isolated internal helpers: `_validateWithdrawalSlot`, `_checkCompensationPair`, `_fetchCompensationPrice`, `_calculateAllocationNeeded`. Introduced `WithdrawalPrepCore` and `WithdrawalPrepState` structs to pass data between helpers. No function exceeds 16 stack slots. All compensation logic now fully encapsulated and reusable. `WithdrawalContext` simplified — price and allocation deduction no longer recalculated in `_updateWithdrawalAllocation` (trusts `_prepWithdrawal` validation).
- **Removed**: `depositStates`, `xLiquiditySlots`, `yLiquiditySlots`, `userXIndex`, `userYIndex`, `isX` flags, `listingAddress` routing, `onlyValidListing` modifier, `volumeAmount` in `claimFees`.
- **Added**: `liquidityAddress` as direct `ICCLiquidity` reference, `compensationToken` support, `normalize`/`denormalize` for arbitrary decimals, `uint2str` for error messages.
- **Refactored**: All internal functions now token-specific. `ccUpdate` uses `updateType=2` (slot allocation) universally. Fee claiming uses `updateType=5` (fees subtract), `updateType=4` (dFeesAcc update).
- **Event System**: Unified events (`DepositReceived`, `WithdrawalFailed`, `CompensationCalculated`, `TransferSuccessful`, `FeesClaimed`, `SlotDepositorChanged`) with token-address indexing.

**Inheritance Tree**: `CCLiquidityRouter` → `CCLiquidityPartial` → `ReentrancyGuard`

**Compatibility**: ICCLiquidity.sol (v0.0.4), ICCListing.sol (v0.0.7), IUniswapV2Factory.sol, IERC20.sol, ReentrancyGuard.sol

## Mappings
- **None in `CCLiquidityRouter` or `CCLiquidityPartial`**. All state resides in `CCLiquidityTemplate` (`ICCLiquidity`) and is accessed via view functions:
  - `liquidityAmounts(token)` → total liquid for token
  - `liquidityDetailsView(token)` → `(liquid, fees, feesAcc)`
  - `getSlotView(token, index)` → `Slot` struct
  - `getActiveSlots(token)` → array of active indices
  - `userSlotIndicesView(token, user)` → user’s slot indices

## Structs
- **ICCLiquidity.Slot**:
  - `token`: ERC20 address (or `address(0)` for ETH)
  - `depositor`: Slot owner
  - `recipient`: Reserved (unused)
  - `allocation`: Normalized contribution (1e18)
  - `dFeesAcc`: Fees accumulator at deposit/claim
  - `timestamp`: Slot creation time
- **ICCLiquidity.UpdateType**:
  - `updateType`: `2`=slot allocation, `3`=slot depositor, `4`=dFeesAcc, `5`=fees subtract
  - `token`, `index`, `value`, `addr`, `recipient`: payload fields
- **ICCLiquidity.PreparedWithdrawal**:
  - `primaryAmount`: Normalized amount in withdrawal token
  - `compensationAmount`: Normalized amount in compensation token
- **DepositContext** (internal):
  - `liquidityAddress`, `depositor`, `token`, `inputAmount`, `receivedAmount`, `normalizedAmount`, `index`
- **WithdrawalContext** (internal):
  - `liquidityAddress`, `token`, `compensationToken`, `depositor`, `index`, `primaryAmount`, `compensationAmount`, `currentAllocation`, `totalAllocationDeduct`, `price`
- **FeeClaimCore** (internal):
  - `liquidityAddress`, `token`, `depositor`, `liquidityIndex`, `feeShare`
- **FeeClaimDetails** (internal):
  - `liquid`, `fees`, `feesAcc`, `allocation`, `dFeesAcc`
- **WithdrawalPrepCore** (internal, v0.2.2):
  - Core input parameters for `_prepWithdrawal`
- **WithdrawalPrepState** (internal, v0.2.2):
  - Mutable state (`slot`, `factory`, `price`, `hasCompensation`) passed between helpers

## Formulas
1. **Normalization**:
   ```
   normalize(amount, decimals) = decimals == 18 ? amount : 
                                 decimals < 18 ? amount * 10^(18-decimals) : 
                                                 amount / 10^(decimals-18)
   ```
2. **Denormalization**:
   ```
   denormalize(amount, decimals) = inverse of above
   ```
3. **Compensation Conversion** (in `_calculateAllocationNeeded`):
   ```
   price = ICCListing.prices(token, compensationToken)  // compensationToken / token
   converted = (compensationAmount * 1e18) / price
   totalAllocationNeeded = outputAmount + converted
   ```
4. **Fee Share** (in `_calculateFeeShare`):
   ```
   contributedFees = feesAcc > dFeesAcc ? feesAcc - dFeesAcc : 0
   liquidityContribution = liquid > 0 ? (allocation * 1e18) / liquid : 0
   feeShare = (contributedFees * liquidityContribution) / 1e18
   feeShare = min(feeShare, fees)
   ```

## External Functions

### depositNativeToken(address liquidityAddress, address depositor, uint256 amount) payable
- **Parameters**:
  - `liquidityAddress`: `ICCLiquidity` template address
  - `depositor`: Address receiving slot credit
  - `amount`: ETH amount (must equal `msg.value`)
- **Behavior**: Deposits ETH to `liquidityAddress`. Supports zero-balance initialization. Normalizes to 1e18, appends new slot via `ccUpdate(updateType=2)`.
- **Internal Call Flow**:
  - `_depositNative` → `_validateDeposit` → initializes `DepositContext`, sets `index = getActiveSlots(token).length`
  - `_executeNativeTransfer` → pre/post balance check on `liquidityAddress`, updates `receivedAmount`
  - `_updateDeposit` → `ccUpdate` with `updateType=2`, emits `DepositReceived`
- **Balance Checks**: Pre/post `liquidityAddress.balance`
- **Restrictions**: `nonReentrant`, `msg.value == amount`, `token == address(0)`
- **Gas**: 1 ETH transfer, 1 `ccUpdate`
- **Events**: `DepositReceived`, `DepositNativeFailed`, `TransferFailed`

### depositToken(address liquidityAddress, address token, address depositor, uint256 amount)
- **Parameters**:
  - `liquidityAddress`, `token`, `depositor`, `amount` (denormalized)
- **Behavior**: Transfers ERC20 from `msg.sender` → router → `liquidityAddress`. Normalizes, appends slot.
- **Internal Call Flow**:
  - `_depositToken` → `_validateDeposit`, `_executeTokenTransfer` (allowance + pre/post checks), `_updateDeposit`
- **Balance Checks**: `allowance`, pre/post `balanceOf(address(this))`, pre/post `balanceOf(liquidityAddress)`
- **Restrictions**: `nonReentrant`, `token != address(0)`
- **Gas**: 2 `transferFrom`/`transfer`, 1 `ccUpdate`
- **Events**: `DepositReceived`, `DepositTokenFailed`, `TransferFailed`, `InsufficientAllowance`

### withdraw(address liquidityAddress, address listingAddress, address token, address compensationToken, uint256 outputAmount, uint256 compensationAmount, uint256 index)
- **Parameters**:
  - `liquidityAddress`: `ICCLiquidity` template
  - `listingAddress`: `ICCListing` for price/pair queries
  - `token`: Primary withdrawal token
  - `compensationToken`: Optional compensation token
  - `outputAmount`, `compensationAmount`: Normalized amounts
  - `index`: Slot index in `token` array
- **Behavior**: Withdraws `outputAmount` of `token` and `compensationAmount` of `compensationToken` from slot. Validates ownership, pair existence, price, and total allocation. Denormalizes before transfer.
- **Internal Call Flow**:
  - `_prepWithdrawal` (v0.2.2 decomposed):
    - `_validateWithdrawalSlot` → ownership + allocation
    - `_checkCompensationPair` → `uniswapV2Factory` + `getPair`
    - `_fetchCompensationPrice` → `prices(token, compensationToken)`
    - `_calculateAllocationNeeded` → `outputAmount + (compensationAmount * 1e18 / price)`
    - Returns `PreparedWithdrawal(0,0)` on any failure
  - `_executeWithdrawal`:
    - `_fetchWithdrawalData` → current `slot.allocation`
    - `_transferWithdrawalAmount` → denormalize + `transactNative`/`transactToken`, reverts if primary fails or compensation fails when requested
    - `_updateWithdrawalAllocation` → deducts `outputAmount + convertedCompensation` via `ccUpdate(updateType=2)`
- **Balance Checks**: Implicit via `allocation` validation
- **Restrictions**: `nonReentrant`, `compensationToken != token`, pair must exist
- **Gas**: Up to 2 transfers, 1 `ccUpdate`, 2 external view calls
- **Events**: `ValidationFailed`, `CompensationCalculated`, `TransferSuccessful`, `WithdrawalFailed`

### claimFees(address liquidityAddress, address token, uint256 liquidityIndex)
- **Parameters**:
  - `liquidityAddress`, `token`, `liquidityIndex`
- **Behavior**: Claims fee share proportional to slot allocation.
- **Internal Call Flow**:
  - `_processFeeShare` → `_validateFeeClaim` → `_fetchLiquidityDetails` + `_fetchSlotDetails`
  - `_calculateFeeShare` → formula above
  - `_executeFeeClaim` → `ccUpdate` with `updateType=5` (fees subtract) + `updateType=4` (dFeesAcc), then `transactNative`/`transactToken`
- **Balance Checks**: `liquid > 0`, `fees > 0`, `allocation > 0`
- **Restrictions**: `nonReentrant`
- **Gas**: 2 `ccUpdate`, 1 transfer
- **Events**: `FeesClaimed`, `NoFeesToClaim`, `FeeValidationFailed`

### changeDepositor(address liquidityAddress, address token, uint256 slotIndex, address newDepositor)
- **Parameters**:
  - `liquidityAddress`, `token`, `slotIndex`, `newDepositor`
- **Behavior**: Reassigns slot ownership.
- **Internal Call Flow**:
  - `_changeDepositor` → validates ownership + allocation, `ccUpdate(updateType=3)`
- **Restrictions**: `nonReentrant`, `newDepositor != address(0)`
- **Gas**: 1 `ccUpdate`
- **Events**: `SlotDepositorChanged`

## Internal Functions (CCLiquidityPartial)

### Deposit Pipeline
- **_validateDeposit**: Returns `DepositContext` with `index = getActiveSlots(token).length`
- **_executeTokenTransfer**: Allowance check, router → template transfer, pre/post balance, normalize
- **_executeNativeTransfer**: `msg.value` check, ETH send, pre/post balance, normalize
- **_updateDeposit**: `ccUpdate(updateType=2)`

### Withdrawal Pipeline (v0.2.2)
- **_validateWithdrawalSlot**: Ownership + allocation check
- **_checkCompensationPair**: Factory → `getPair`, emits on failure
- **_fetchCompensationPrice**: `prices(...)`, emits on failure/zero
- **_calculateAllocationNeeded**: `output + (compensation * 1e18 / price)`
- **_prepWithdrawal**: Orchestrates above, returns `PreparedWithdrawal`
- **_fetchWithdrawalData**: Reads current `slot.allocation`
- **_transferWithdrawalAmount**: Denormalizes, calls `transactNative`/`transactToken`, reverts on primary/compensation failure
- **_updateWithdrawalAllocation**: Deducts validated total via `ccUpdate(updateType=2)`

### Fee Claim Pipeline
- **_fetchLiquidityDetails**: `liquidityDetailsView(token)`
- **_fetchSlotDetails**: `getSlotView(...)`, ownership check
- **_validateFeeClaim**: Combines above, checks `liquid`, `fees`, `allocation`
- **_calculateFeeShare**: Proportional fee formula
- **_executeFeeClaim**: `ccUpdate` ×2, transfer, `FeesClaimed`

### Utility
- **normalize / denormalize**: Decimal adjustment to/from 1e18
- **uint2str**: Error message helper

## Clarifications and Nuances
- **Token-Agnostic Design**: Each `token` has independent slot array in `CCLiquidityTemplate`. No x/y duality.
- **Compensation Logic**: `compensationAmount` converted to primary token allocation **only for validation**. Actual transfers are independent (denormalized to native decimals).
- **Price Source**: `ICCListing.prices(tokenA, tokenB)` returns `tokenB / tokenA` in 1e18. Conversion: `tokenA_equiv = compensationB_amount / price`.
- **Decimal Safety**: `normalize` uses `IERC20.decimals()`, ETH = 18. Pre/post balance checks handle tax tokens.
- **Graceful Degradation**: All external calls wrapped in `try/catch`. Failures emit detailed events, never leave state inconsistent.
- **Stack Safety**: No function >16 stack slots. All complex logic in structs + helper call tree.
- **Event Indexing**: All events indexed by `token` and `depositor` for subgraph compatibility.
- **No Listing Dependency in Router**: `liquidityAddress` passed directly. `listingAddress` only used in `withdraw` for price/pair queries.
- **Security**: `nonReentrant`, explicit casting, no inline assembly, no `virtual`/`override`, no `SafeERC20`.
- **Gas**: Single `ccUpdate` per state change. View calls minimized.
