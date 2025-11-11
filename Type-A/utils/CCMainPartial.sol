// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.2.0
// Changes:
// - v0.2.0: Updated ICCListing interface to match monolithic CCListingTemplate.sol v0.4.2.
// - Replaced individual getter functions with array-based getBuyOrder/getSellOrder.
// - Updated struct definitions to use address[], uint256[] arrays matching template.
// - Removed CCAgent dependency, listing template is now standalone.
// - Added uniswapV2Factory, uniswapV2Router, registryAddress, globalizerAddress getters.
// Compatible with CCListingTemplate.sol (v0.4.2), CCOrderRouter.sol (v0.2.0), CCLiquidityTemplate.sol (v0.2.0+).

import "../imports/IERC20.sol";
import "../imports/ReentrancyGuard.sol";

interface ICCListing {
    struct BuyOrderUpdate {
        uint8 structId; // 0: Core, 1: Pricing, 2: Amounts
        uint256 orderId;
        address[] addresses; // [0]: maker, [1]: recipient, [2]: startToken, [3]: endToken
        uint256[] prices; // [0]: maxPrice, [1]: minPrice
        uint256[] amounts; // [0]: pending, [1]: filled, [2]: amountSent
        uint8 status;
    }

    struct SellOrderUpdate {
        uint8 structId; // 0: Core, 1: Pricing, 2: Amounts
        uint256 orderId;
        address[] addresses; // [0]: maker, [1]: recipient, [2]: startToken, [3]: endToken
        uint256[] prices; // [0]: maxPrice, [1]: minPrice
        uint256[] amounts; // [0]: pending, [1]: filled, [2]: amountSent
        uint8 status;
    }

    struct HistoricalUpdate {
        address tokenA;
        address tokenB;
        uint256 price;
        uint256 xBalance;
        uint256 yBalance;
        uint256 xVolume;
        uint256 yVolume;
        uint256 timestamp;
    }

    struct HistoricalData {
        uint256 price;
        uint256 xBalance;
        uint256 yBalance;
        uint256 xVolume;
        uint256 yVolume;
        uint256 timestamp;
    }

    function prices(address tokenA, address tokenB) external view returns (uint256);
    function uniswapV2Factory() external view returns (address);
    function uniswapV2Router() external view returns (address);
    function registryAddress() external view returns (address);
    function globalizerAddress() external view returns (address);
    function getNextOrderId() external view returns (uint256);
    function getHistoricalDataView(address tokenA, address tokenB, uint256 index) external view returns (HistoricalData memory data);
    function historicalDataLengthView(address tokenA, address tokenB) external view returns (uint256 length);
    function pendingBuyOrdersView() external view returns (uint256[] memory);
    function pendingSellOrdersView() external view returns (uint256[] memory);
    function makerPendingOrdersView(address maker) external view returns (uint256[] memory);
    function getBuyOrder(uint256 orderId) external view returns (
        address[] memory addresses,
        uint256[] memory prices_,
        uint256[] memory amounts,
        uint8 status
    );
    function getSellOrder(uint256 orderId) external view returns (
        address[] memory addresses,
        uint256[] memory prices_,
        uint256[] memory amounts,
        uint8 status
    );
    function withdrawToken(address token, uint256 amount, address recipient) external;
    function setUniswapV2Factory(address _factory) external;
    function setUniswapV2Router(address _router) external;
    function setRegistry(address _registryAddress) external;
    function setGlobalizerAddress(address _globalizerAddress) external;
    function addRouter(address router) external;
    function removeRouter(address router) external;
    function ccUpdate(
        BuyOrderUpdate[] calldata buyUpdates,
        SellOrderUpdate[] calldata sellUpdates,
        HistoricalUpdate[] calldata historicalUpdates
    ) external;
    function routerAddressesView() external view returns (address[] memory);
}

interface ICCLiquidity {
    struct UpdateType {
        uint8 updateType; // 0=balance, 1=fees, 2=xSlot, 3=ySlot
        uint256 index; // 0=xFees/xLiquid, 1=yFees/yLiquid, or slot index
        uint256 value; // Normalized amount or allocation
        address addr; // Depositor address
        address recipient; // Unused recipient address
    }

    struct Slot {
        address depositor;
        address recipient;
        uint256 allocation;
        uint256 dFeesAcc;
        uint256 timestamp;
    }

    struct PreparedWithdrawal {
        uint256 amountA;
        uint256 amountB;
    }

    struct LongPayoutStruct {
        address makerAddress;
        address recipientAddress;
        uint256 required;
        uint256 filled;
        uint256 amountSent;
        uint256 orderId;
        uint8 status; // 0: cancelled, 1: pending, 2: partially filled, 3: filled
    }

    struct ShortPayoutStruct {
        address makerAddress;
        address recipientAddress;
        uint256 amount;
        uint256 filled;
        uint256 amountSent;
        uint256 orderId;
        uint8 status; // 0: cancelled, 1: pending, 2: partially filled, 3: filled
    }

    struct PayoutUpdate {
        uint8 payoutType; // 0: Long, 1: Short
        address recipient;
        uint256 orderId;
        uint256 required;
        uint256 filled;
        uint256 amountSent;
    }

    function routerAddressesView() external view returns (address[] memory);
    function setRouters(address[] memory _routers) external;
    function setListingId(uint256 _listingId) external;
    function setListingAddress(address _listingAddress) external;
    function setTokens(address _tokenA, address _tokenB) external;
    function ccUpdate(address depositor, UpdateType[] memory updates) external;
    function transactToken(address depositor, address token, uint256 amount, address recipient) external;
    function transactNative(address depositor, uint256 amount, address recipient) external;
    function liquidityAmounts() external view returns (uint256 xAmount, uint256 yAmount);
    function liquidityDetailsView() external view returns (uint256 xLiquid, uint256 yLiquid, uint256 xFees, uint256 yFees, uint256 xFeesAcc, uint256 yFeesAcc);
    function userXIndexView(address user) external view returns (uint256[] memory);
    function userYIndexView(address user) external view returns (uint256[] memory);
    function getXSlotView(uint256 index) external view returns (Slot memory);
    function getYSlotView(uint256 index) external view returns (Slot memory);
    function getActiveXLiquiditySlots() external view returns (uint256[] memory slots);
    function getActiveYLiquiditySlots() external view returns (uint256[] memory slots);
    function ssUpdate(PayoutUpdate[] calldata updates) external;
    function longPayoutByIndexView() external view returns (uint256[] memory);
    function shortPayoutByIndexView() external view returns (uint256[] memory);
    function userPayoutIDsView(address user) external view returns (uint256[] memory);
    function activeLongPayoutsView() external view returns (uint256[] memory);
    function activeShortPayoutsView() external view returns (uint256[] memory);
    function activeUserPayoutIDsView(address user) external view returns (uint256[] memory);
    function getLongPayout(uint256 orderId) external view returns (LongPayoutStruct memory);
    function getShortPayout(uint256 orderId) external view returns (ShortPayoutStruct memory);
}

contract CCMainPartial is ReentrancyGuard {
    address internal listingTemplate; // Single monolithic listing template

    struct BuyOrderDetails {
        uint256 orderId;
        address maker;
        address receiver;
        address startToken;
        address endToken;
        uint256 pending;
        uint256 filled;
        uint256 maxPrice;
        uint256 minPrice;
        uint8 status;
    }

    struct SellOrderDetails {
        uint256 orderId;
        address maker;
        address receiver;
        address startToken;
        address endToken;
        uint256 pending;
        uint256 filled;
        uint256 maxPrice;
        uint256 minPrice;
        uint8 status;
    }

    struct OrderClearData {
        uint256 id;
        bool isBuy;
        uint256 amount;
    }

    function normalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        // Normalizes amount to 18 decimals
        if (decimals == 18) return amount;
        else if (decimals < 18) return amount * 10 ** (uint256(18) - uint256(decimals));
        else return amount / 10 ** (uint256(decimals) - uint256(18));
    }

    function denormalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        // Denormalizes amount from 18 decimals to token decimals
        if (decimals == 18) return amount;
        else if (decimals < 18) return amount / 10 ** (uint256(18) - uint256(decimals));
        else return amount * 10 ** (uint256(decimals) - uint256(18));
    }

    function setListingTemplate(address _listingTemplate) external onlyOwner {
        // Sets listing template address
        require(_listingTemplate != address(0), "Invalid template address");
        listingTemplate = _listingTemplate;
    }

    function listingTemplateView() external view returns (address) {
        // Returns listing template address
        return listingTemplate;
    }
}