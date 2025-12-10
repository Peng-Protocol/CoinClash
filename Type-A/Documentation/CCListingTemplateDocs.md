# CCListingTemplate Contract Documentation (v0.4.2)

The `CCListingTemplate` is a core smart contract in the CoinClash Type-B system. It functions by managing buy and sell orders and calculating prices directly using the state of Uniswap V2 pairs.

**Version**: 0.4.2 (10/11/2025)

## Key Concepts and Architecture

This contract is built to be a standalone system that tracks orders and historical trading data without managing the tokens themselves.

### 1\. Decentralized Pricing and Balances

  * **Real-time Price Discovery**: Price is determined on-demand by querying the reserves (balances) of the corresponding Uniswap V2 pair via the `prices()` view function.
      * The price is calculated as "tokenB per tokenA" and is **normalized to $1 \times 10^{18}$ precision**.

### 2\. Order Management

The contract manages buy and sell orders, storing their details and tracking their status.

  * **Order Storage**: Orders are stored in `buyOrders` and `sellOrders` mappings.
  * **Order Status**: Orders transition through four statuses:
      * **0**: Cancelled
      * **1**: Pending
      * **2**: Partially Filled
      * **3**: Filled
  * **Pending Orders**: New orders are tracked in dedicated arrays and also per-maker. They are removed when cancelled or fully filled.

### 3\. Historical Data Tracking

Trading volume is tracked over time on a per-token-pair basis using the `_historicalData` mapping.

  * **Volume Tracking**: The `xVolume` (Token A volume) and `yVolume` (Token B volume) fields in the `HistoricalData` struct track the cumulative volume (amounts) traded.
      * The volume changes are applied as **differences** when order amounts are updated via the `ccUpdate` function.
  * **Day Indices**: `_dayStartIndices` maps the midnight timestamp of a day to the index of the first `HistoricalData` entry for that day, enabling efficient fetching of daily data.

-----

## Core Components

### Interfaces (External Contracts)

| Interface | Purpose |
| :--- | :--- |
| **IERC20** | Standard token interface |
| **IUniswapV2Factory** | Uniswap V2 protocol integration |
| **ICCGlobalizer** | Optional component for globalizing order data |
| **ITokenRegistry** | Optional component for storing all tokens a maker has interacted with |

### Structs (Data Structures)

| Struct | Description | Key Fields |
| :--- | :--- | :--- |
| **HistoricalData** | Snapshot of a pair's trading history. | `price`, `xVolume`, `yVolume`, `timestamp` |
| **BuyOrder / SellOrder** | Details of a trading order. | `addresses` (maker, recipient, startToken, endToken), `amounts` (pending, filled, amountSent), `status` |
| **OrderUpdate** | Data passed to `ccUpdate` to modify orders. | `structId` (0: Core, 1: Pricing, 2: Amounts), `orderId`, related fields. |
| **OrderStatus** | Tracks if all components of an order have been received. | `hasCore`, `hasPricing`, `hasAmounts` |

-----

## Key Functions

### `ccUpdate` (External, Router-Only)

This is the main function for state modification, callable only by authorized routers.

**It processes three types of updates:**

1.  **Buy Order Updates**: Updates order details. For `structId=2` (Amounts), it updates the **yVolume** (filled amount) and **xVolume** (amountSent) in the latest historical data entry.
2.  **Sell Order Updates**: Updates order details. For `structId=2` (Amounts), it updates the **xVolume** (filled amount) and **yVolume** (amountSent) in the latest historical data entry.
3.  **Historical Updates**: Appends new price and volume snapshots to the per-pair historical data array and updates the day-start indices.

**Post-Processing Actions:**

  * **Completeness Check**: Verifies if all parts of an order update (Core, Pricing, Amounts) have been received.
  * **Globalization**: Calls `ICCGlobalizer.globalizeOrders` with the last updated maker and token.

### `prices(address tokenA, address tokenB)` (View)

Calculates the current price of `tokenB` in terms of `tokenA` (B/A) by querying the Uniswap V2 pair.

1.  Finds the pair address for `(tokenA, tokenB)`.
2.  Gets the balances (reserves) of both tokens from the pair.
3.  Normalizes balances to 1e18 precision.
4.  Calculates the price: $$(Normalized Balance_B \times 10^{18}) \div Normalized Balance_A$$.

### `withdrawToken(address token, uint256 amount, address recipient)` (External, Router-Only)

Allows authorized routers to withdraw tokens or native ETH from the contract's address.

-----

## Volume Calculation Logic

When an order's **Amounts** (`structId=2`) are updated, the difference between the new and old `filled` and `amountSent` is added to the historical volume.

| Order Type | Token Used (Input/Start) | Token Received (Output/End) | Volume Mapping (X/Y) |
| :--- | :--- | :--- | :--- |
| **Buy Order** | Token A (`amountSent`) | Token B (`filled`) | $\Delta \text{yVolume} += \Delta \text{filled}$<br> $\Delta \text{xVolume} += \Delta \text{amountSent}$ |
| **Sell Order** | Token A (`filled`) | Token B (`amountSent`) | $\Delta \text{xVolume} += \Delta \text{filled}$<br> $\Delta \text{yVolume} += \Delta \text{amountSent}$ |

-----