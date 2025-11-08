# Overview
CoinClash, derived from [Dexhune-P](https://github.com/Peng-Protocol/Dexhune-P) uses Uniswap V2 for order settlement. The system introduces range/limit orders - dynamic fees - historical data, etc to Uniswap v2. 

## System Summary
CoinClash operates via `CCAgent`, to deploy `CCListingTemplate` and `CCLiquidityTemplate` contracts for unique token pairs. `CCListingTemplate` serves as the order book, enabling order creation, cancellation, and settlement via `CCOrderRouter`, `CCSettlementRouter`, and `CCLiquidRouter`. It uses Uniswap V2 for real-time pricing and partial fills, tracking historical data and balances. `CCLiquidityTemplate` enables deposits, withdrawals, fee claims, and payouts, storing liquidity details and slot data. `CCLiquidityRouter` handles deposits, partial withdrawals with compensation, and fee calculations, while `CCLiquidRouter` settles orders using liquidity balances, charging between 0.01% and 10% fees depending on liquidity usage. `CCGlobalizer` and `TokenRegistry` ensure cross-contract order and balance consistency. Pagination (`maxIterations`, `step`) optimizes queries, and relisting supports system upgrades.

*Pending*: The contracts listed below make up the leverage and multi-hop functionalities. They are still in development and currently do not work. Existing functionality covers basic swaps and liquidity provision.

* MultiController
* MultiInitializer 
* Multistorage 
* UAEntryDriver
* UAExitDriver
* UALiquidationDriver
* UAExecutionDriver
* UAStorage

# CCAgent

## Description 
The `CCAgent` contract (Solidity ^0.8.2) manages the deployment and initialization of token pair listings and liquidity contracts. It serves as a central hub for creating and tracking token pair listings, ensuring secure deployment using CREATE2 and maintaining state for token pairs, listings, and listers.

## Key Functionality
- **Listing Management**: Deploys listing (`CCListingTemplate`) and liquidity (`CCLiquidityTemplate`) contracts via `CCListingLogic` and `CCLiquidityLogic` using `_deployPair`. Supports token-token (`listToken`) and token-native (`listNative`) pairs, with relisting (`relistToken`, `relistNative`) restricted to original listers.
- **State Tracking**: Maintains mappings (`getListing`, `getLister`, `listingsByLister`) and arrays (`allListings`, `allListedTokens`) for token pairs, listing addresses, and lister details. Updates state via `_updateState`.
- **Initialization**: Configures listing and liquidity contracts with routers, tokens, and Uniswap V2 pair via `_initializeListing` and `_initializeLiquidity`. Verifies token pairs against Uniswap V2 pair using `_verifyAndSetUniswapV2Pair`.
- **Lister Management**: Supports lister transfers (`transferLister`) and paginated queries (`getListingsByLister`, `queryByAddressView`) for listings and tokens, using `maxIterations` for gas control.
- **Validation**: Ensures valid deployments with checks for non-zero addresses, existing routers, and unique token pairs. Emits events (`ListingCreated`, `ListingRelisted`, `ListerTransferred`) for transparency.

## Interactions
- **CCListingLogic**: Deploys listing contracts via `deploy` with CREATE2, ensuring deterministic addresses. Can be updated by owner.
- **CCLiquidityLogic**: Deploys liquidity contracts similarly, linked to listings via `liquidityAddressView`. Can be updated by owner.

## Globalizer Integration
- **CCGlobalizer**: Optionally set via `setGlobalizerAddress`, enabling order and liquidity globalization. Listings call `setGlobalizerAddress` if configured, allowing cross-contract order tracking. Owner sets or resets this address. 

## Token Registry Integration
- **TokenRegistry**: Tracks token balances for users, integrated via `registryAddress`. Used by listings for balance queries, ensuring consistent token data across the system. Owner sets or resets this address. 

## Security
- Restricts critical functions (`setWETHAddress`, `setGlobalizerAddress`) to owner.
- Uses try-catch for external calls, ensuring graceful degradation.
- Validates inputs (e.g., non-zero addresses, token pair uniqueness) to prevent errors.
- Opt-in updates via relisting or router-resets ensure that the system is upgradable and secure. If routers are updated the new addresses can be pushed via `resetRouters` on the `CCListingTemplate` and `CCLiquidityTemplate`, restricted to the original lister. Globalizer and Token Registry cannot be changed on the listing template without relisting. Liquidity template fetches latest Globalizer and Token Registry from Agent. Templates can only be updated by relisting. Agent retains old pairs after relisting and continues to validate them, but `getListing` and other queries return only the latest listing. 

## Notes
- Supports pagination (`maxIterations`, `step`) for efficient queries.
- WETH address required for native ETH pairs, set via `setWETHAddress`.

# CCListingTemplate

## Description 
As seen in [MFP](https://github.com/Peng-Protocol/Dexhune-P) with some key differences involving Uniswap v2 integraion.

## Key Differences
- **UniswapV2 Addresses**: Stores `uniswapV2PairView` mapping for the associated Uniswap v2 Liquidity Pool (LP). `uniswapV2PairViewSet` boolean which prevents resetting the pair address after deployment. `setUniswapV2Pair` used by the `ccAgent` to determine the Uniswap v2 LP address. 
- **Price Calculation**: Price is calculated using the balances of `token1` and `token0` at the associated Uniswap V2 pair address. `IUniswapV2Pair` is used in `ccUpdate` for consistency reasons. 

# CCLiquidityTemplate

## Description 
As seen in [MFP](https://github.com/Peng-Protocol/Dexhune-P) but primarily relies on `CCLiquidRouter` and `CCAgent`, not `MFPLiquidRouter` and `MFPAgent` (Though they are interchangeable depending on usecase). 

# CCOrderRouter

## Description 
As seen in [MFP](https://github.com/Peng-Protocol/Dexhune-P).

# CCSettlementRouter

## Description 
This is where the magic happens, As seen in  [MFP](https://github.com/Peng-Protocol/Dexhune-P) Listing Template with key differences for Uniswap v2 integration. 

## Key Interactions
- **Order Settlement**: Iterates over pending orders using `pendingBuyOrdersView`/`pendingSellOrdersView` from CCListingTemplate. Processes orders in batches to manage state and avoid stack issues.
- **Order Validation**: Validates orders to ensure non-zero pending amounts and price compliance.
- **Balance Handling**: Uses `transactToken`/`transactNative` to pull funds, checking own balance post-transfer for tax-on-transfer tokens.
- **Update Application**: Applies updates via `ccUpdate` with `BuyOrderUpdate`/`SellOrderUpdate` structs, handling status changes (pending, partially filled, filled).
- **Historical Data**: Creates historical entries in `_createHistoricalEntry`, capturing price and volume data for analytics.
- **Pagination**: Limits processing up to `maxIterations` orders starting from `step`. E.g; if a pending orders array has (5) orders, "2,22,23,24,30", the user or frontend specifies a `step` "1" (zero based indexing) and `maxIterations` "3" this limits processing to orders "22,23,24". 
- **Security**: Uses `nonReentrant` modifier and try-catch for external calls, reverting with detailed reasons on failure. Emits no events if nonpending orders exist, relying on reverts. 
If orders exist but none are settled due to price bounds or swap failures, returns string "No orders settled: price out of range or swap failure" without emitting events or reverting, ensuring graceful degradation.
- **Partial Fills Behavior:**
Partial fills occur when the `swapAmount` is limited by `maxAmountIn`, calculated in `_computeMaxAmountIn` (CCSettlementPartial.sol) to respect price bounds and available reserves. For example, with a buy order of 100 tokenB pending, a pool of 1000 tokenA and 500 tokenB (price = 0.5 tokenA/tokenB), and price bounds (max 0.6, min 0.4), `maxAmountIn` is 50 tokenB due to price-adjusted constraints. This results in a swap of 50 tokenB for ~90.59 tokenA, updating `pending = 50`, `filled += 50`, `amountSent = 90.59` and `status = 2` (partially filled) via a single `ccUpdate` call in `_updateOrder` (CCSettlementRouter.sol). 
- **AmountSent Usage:**
`amountSent` tracks the actual tokens a recipient gets after a trade (e.g., tokenA for buy orders) in the `BuyOrderUpdate`/`SellOrderUpdate` structs.
  - **Calculation**: The system checks the recipient’s balance before and after a transfer to record `amountSent` (e.g., ~90.59 tokenA for 50 tokenB after fees).
  - **Partial Fills**: For partial trades (e.g., 50 of 100 tokenB), `amountSent` shows the tokens received each time. Is incremented for each partial fill. 
  - **Application**: Prepared in `CCUniPartial.sol` and applied via one `ccUpdate` call, updating the order’s Amounts struct.
- **Maximum Input Amount:** 
(`maxAmountIn`) ensures that the size of the swap doesn't push the execution price outside the `minPrice`/`maxPrice` boundaries set in the order.
  - **Calculate a Price-Adjusted Amount**: The system first calculates a theoretical maximum amount based on the current market price and the order's pending amount.
  - **Determine the True Maximum**: This is limited by;
    * The **`priceAdjustedAmount`**.
    * The order's actual **`pendingAmount`**.
    * The **`normalizedReserveIn`** (the total amount of the input token available in the Uniswap pool).
- **Minimum Output Amount:**
(`amountOutMin`) is used to determine the minimum output expected from the Uniswap v2 swap, as a safeguard against slippage. 
**`expectedAmountOut`** is calculated based on the current pool reserves and the size of the input amount (`denormAmountIn`) and is used directly as the value for the **`denormAmountOutMin`** parameter in the actual Uniswap `swapExactTokensForTokens` call. Slippage cannot exceed order's max/min price bounds.

# CCLiquidRouter

## Description 
As seen in [MFP](https://github.com/Peng-Protocol/Dexhune-P).

## Key Interactions
- **Liquid Settlement**: Similar to `MFPLiquidRouter`, but uses impact price based on Uniswap v2 LP balances (as seen in `CCSettlementRouter`) for consistency. 

# CCLiquidityRouter

## Description 

As seen in [MFP](https://github.com/Peng-Protocol/Dexhune-P).
