# CCLiquidityTemplate Documentation

## Overview
The `CCLiquidityTemplate`, implemented in Solidity (^0.8.2), manages **token-agnostic liquidity pools**, fee accumulation, slot-based depositor tracking, and withdrawal functionality in a decentralized trading platform. It is a **refactored monolithic template** that replaces the previous dual-token (x/y) architecture with a **per-token storage model**, enabling support for arbitrary token pairs via dynamic mapping keys. The contract integrates with `ITokenRegistry` and `ICCGlobalizer` for balance initialization and liquidity globalization. All amounts are normalized to 1e18 using `IERC20.decimals()`. State variables are public where appropriate; arrays and complex mappings use explicit view functions. The contract avoids reserved keywords, uses explicit casting, avoids `SafeERC20`, and ensures **graceful degradation** via `try-catch` on external calls with detailed event emissions on failure.

**SPDX License**: BSL 1.1 - Peng Protocol 2025

**Version**: 0.2.0 (Updated 2025-11-10)

---

## Change Log Summary (Since v0.1.20)
- **v0.2.0 (10/11/2025)**:  
  - **Complete architectural refactor** from dual-token (x/y) to **token-address-indexed storage**.
  - Removed `tokenA`, `tokenB`, `listingId`, `listingAddress`, `agent` — **no longer listing-specific**.
  - All liquidity, slots, fees, and user indices now keyed by `address token`.
  - `Slot` struct now includes `token` field for self-identification.
  - `UpdateType` now includes `token` address; `updateType` values remapped:
    - `0` → set liquid
    - `1` → add fees
    - `2` → update slot allocation (create/update/remove)
    - `3` → change depositor
    - `4` → update `dFeesAcc`
    - `5` → subtract fees
  - **Removed all payout logic** (`ssUpdate`, `LongPayoutStruct`, `ShortPayoutStruct`, etc.) — moved to separate order system.
  - **Removed `transactToken`/`transactNative` liquidity reduction** — now handled externally.
  - Added `withdrawToken` for router-controlled emergency withdrawals.
  - Added `setUniswapV2Factory`, `setRegistry`, `setGlobalizerAddress`, `addRouter`, `removeRouter`.
  - `globalizeUpdate` now called **per-slot update** with correct token.
  - All arrays (`activeSlots`, `userSlotIndices`) now per-token.
  - View functions updated to accept `token` parameter.
  - **No more fixed x/y semantics** — fully generic per-token liquidity.

---

## Compatibility
- `CCLiquidityRouter.sol` (v0.1.0+) — must pass `token` in `UpdateType`
- `CCGlobalizer.sol` (v0.2.1)
- `ITokenRegistry` (v0.1.0+)
- `IUniswapV2Factory` (standard)
- **No longer compatible** with `CCListingTemplate.sol`, `CCLiquidityPartial.sol` (v0.0.41), `ICCListing.sol`

---

## State Variables
- `routers`: `mapping(address => bool) public` — Authorized router status.
- `routerAddresses`: `address[] private` — List of router addresses (for enumeration).
- `uniswapV2Factory`: `address public` — Uniswap V2 factory (optional).
- `registryAddress`: `address public` — Token registry for balance initialization.
- `globalizerAddress`: `address public` — Globalizer contract for liquidity updates.

## Mappings
- `liquidityDetail`: `mapping(address => LiquidityDetails) private`  
  → Per-token liquidity, fees, and cumulative fee tracker.
- `liquiditySlots`: `mapping(address => mapping(uint256 => Slot)) private`  
  → `token => slotID => Slot` — slot storage.
- `activeSlots`: `mapping(address => uint256[]) private`  
  → `token => active slot IDs[]`.
- `userSlotIndices`: `mapping(address => mapping(address => uint256[])) private`  
  → `token => user => slotIDs[]` — user-owned slots per token.

---

## Structs

### `LiquidityDetails`
| Field | Type | Description |
|------|------|-----------|
| `liquid` | `uint256` | Normalized available liquidity |
| `fees` | `uint256` | Normalized pending fees |
| `feesAcc` | `uint256` | Cumulative fee volume (never decreases) |

### `Slot`
| Field | Type | Description |
|------|------|-----------|
| `token` | `address` | Token this slot provides |
| `depositor` | `address` | Owner of the slot |
| `recipient` | `address` | Withdrawal recipient |
| `allocation` | `uint256` | Normalized allocated liquidity |
| `dFeesAcc` | `uint256` | Snapshot of `feesAcc` at last update |
| `timestamp` | `uint256` | Slot creation time |

### `UpdateType`
| Field | Type | Description |
|------|------|-----------|
| `updateType` | `uint8` | Operation type (0–5) |
| `token` | `address` | Target token |
| `index` | `uint256` | Slot index or 0 |
| `value` | `uint256` | Amount/allocation |
| `addr` | `address` | New depositor |
| `recipient` | `address` | Withdrawal recipient |

---

## External Functions and Internal Call Trees

### `setUniswapV2Factory(address _factory)` → onlyOwner
- Sets factory; emits `UniswapFactorySet`.
- **Internal Call Tree**: None.

### `setRegistry(address _registryAddress)` → onlyOwner
- Sets registry; emits `RegistryAddressSet`.
- **Internal Call Tree**: None.

### `setGlobalizerAddress(address _globalizerAddress)` → onlyOwner
- Sets globalizer; emits `GlobalizerAddressSet`.
- **Internal Call Tree**: None.

### `addRouter(address router)` → onlyOwner
- Adds router; updates `routers` and `routerAddresses`; emits `RouterAdded`.
- **Internal Call Tree**: None.

### `removeRouter(address router)` → onlyOwner
- Removes router; updates mapping and array; emits `RouterRemoved`.
- **Internal Call Tree**: Linear search + pop.

### `withdrawToken(address token, uint256 amount, address recipient)`
- Router-only. Withdraws any token (including ETH) held by contract.
- Emits `TokensWithdrawn`.
- **Internal Call Tree**: `balanceOf`, `transfer`, or `call{value}`.

---

### `ccUpdate(address depositor, UpdateType[] memory updates)`
- **Router-only**. Processes batch updates per-token.
- **Internal Call Flow**:
  1. Loop over `updates` → extract `u`
  2. Fetch `LiquidityDetails storage details = liquidityDetail[u.token]`
  3. Branch by `u.updateType`:
     - **0**: `details.liquid = u.value` → emit `LiquidityUpdated`
     - **1**: `details.fees += u.value; details.feesAcc += u.value` → emit `FeesUpdated`
     - **2 (slot allocation)**:
       - If new: initialize `slot` (set `token`, `depositor`, `recipient`, `dFeesAcc`, push to `activeSlots` and `userSlotIndices`)
       - If remove: zero `depositor`, `allocation`, remove from user indices
       - Adjust `details.liquid +=/- (new - old)`
       - Call `globalizeUpdate(depositor, u.token, u.value)`
       - Emit `LiquidityUpdated`
     - **3 (change depositor)**:
       - Require `slot.depositor == depositor`
       - Transfer slot ownership in `userSlotIndices`
       - Emit `SlotDepositorChanged`
     - **4 (update dFeesAcc)**:
       - Require ownership
       - Set `slot.dFeesAcc = u.value`
     - **5 (subtract fees)**:
       - Require `details.fees >= u.value`
       - `details.fees -= u.value` → emit `FeesUpdated`
- **Internal Call Tree**:
  - `globalizeUpdate` → `ICCGlobalizer.globalizeLiquidity`, `ITokenRegistry.initializeBalances` (try-catch)
  - `removePendingOrder` (not used in v0.2.0)

---

### `transactToken(address depositor, address token, uint256 amount, address recipient)`
- **Router-only**. Transfers ERC20; **does not reduce `liquid`**.
- Normalizes `amount`, checks `liquid >= normalized`, transfers denormalized.
- **try-catch** on transfer → emit `TransactFailed` + revert.
- **Internal Call Tree**: `normalize`, `IERC20.decimals`, `IERC20.transfer`

### `transactNative(address depositor, uint256 amount, address recipient)`
- **Router-only**. Transfers ETH; **does not reduce `liquid`**.
- Normalizes, checks `liquid[ETH]`, sends via `call`.
- On fail → emit `TransactFailed` + revert.
- **Internal Call Tree**: `normalize`

---

### `globalizeUpdate(address depositor, address token, uint256 amount)` internal
- If `globalizerAddress`: `try ICCGlobalizer.globalizeLiquidity` → catch `GlobalizeUpdateFailed`
- If `registryAddress`: `try ITokenRegistry.initializeBalances([depositor])` → catch `UpdateRegistryFailed`
- **Graceful degradation**: continues on failure.

---

## View Functions (All `external view`)

| Function | Returns | Description |
|--------|--------|-----------|
| `routerAddressesView()` | `address[]` | All routers |
| `liquidityAmounts(address token)` | `uint256` | `liquid` |
| `liquidityDetailsView(address token)` | `(liquid, fees, feesAcc)` | Full details |
| `userSlotIndicesView(address token, address user)` | `uint256[]` | User's slot IDs |
| `getActiveSlots(address token)` | `uint256[]` | Active slot indices |
| `getSlotView(address token, uint256 index)` | `Slot memory` | Full slot data |

---

## Events
- `LiquidityUpdated(address indexed token, uint256 liquid)`
- `FeesUpdated(address indexed token, uint256 fees)`
- `SlotDepositorChanged(address indexed token, uint256 indexed slotIndex, address indexed oldDepositor, address newDepositor)`
- `GlobalizeUpdateFailed(...)`, `UpdateRegistryFailed(...)`, `TransactFailed(...)`
- `RouterAdded`, `RouterRemoved`
- `RegistryAddressSet`, `GlobalizerAddressSet`, `UniswapFactorySet`
- `TokensWithdrawn(address indexed token, address indexed recipient, uint256 amount)`

---

## Key Insights & Design Notes

### **Token-Agnostic Refactor (v0.2.0)**
- Eliminates fixed `tokenA`/`tokenB` → supports **any token** via `address` key.
- Enables **multi-pair liquidity** in a single contract (via different `token` keys).
- **Backwards incompatible** with prior listing-based templates.

### **Slot Lifecycle**
1. **Create**: `updateType=2`, `slot.depositor == address(0)` → init + push to active/user
2. **Update Allocation**: `liquid += (new - old)`
3. **Remove**: `addr == address(0)` → zero fields, remove from user indices
4. **Transfer**: `updateType=3` → ownership move, event
5. **Fee Claim Prep**: `updateType=4` → sync `dFeesAcc`

### **Fee System**
- `fees`: claimable pool
- `feesAcc`: monotonically increasing → enables pro-rata claims via `feesAcc - dFeesAcc`
- `updateType=1`: add fees
- `updateType=5`: subtract (payout)

### **Decimal Normalization**
- `normalize()`: to 1e18
- `denormalize()`: for transfer
- Uses `IERC20.decimals()` → no SafeERC20

### **Security & Gas**
- **No reentrancy**: router-level guard assumed
- **Try-catch** on external calls → non-reverting
- **No caps**: dynamic arrays
- **No virtual/override**
- **No inline assembly**
- **Explicit casting** in interface calls

### **Router Pattern**
- All state changes via `routers[msg.sender]`
- `withdrawToken` allows emergency drain

### **ETH Handling**
- `address(0)` = ETH
- `transactNative` uses `call{value}`
- `receive()` allows ETH deposits
