// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.4.2 (10/11)
// Changes:
// - (10/11/2025) v0.4.2: Removed _balances mapping and all balance-update logic. 
//           volumeBalances() now queries Uniswap pair reserves directly via balanceOf.
//           Removed Balance struct, BalanceUpdate struct, BalancesUpdated event, 
//           and balance-processing loop in ccUpdate().
//           Removed _balances from storage entirely.
// - (10/11/2025) v0.4.1: Made historical data and balances token-pair specific. Added mapping-based storage for historical data per pair.
//           Updated prices(), volumeBalances(), and all historical views to take token addresses as parameters.
//           Moved balance tracking to per-pair basis.
// - (10/11/2025) v0.4.0: Refactored to monolithic standalone template. Removed CCAgent dependency, added direct Uniswap Factory integration.
//           Routers now owner-only, added token withdrawal function, prices() now takes token addresses and queries factory.
//           Grouped order struct fields into arrays, added startToken/endToken to orders, removed agent references.

import "../imports/Ownable.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface ITokenRegistry {
    function initializeTokens(address user, address[] memory tokens) external;
}

interface ICCGlobalizer {
    function globalizeOrders(address maker, address token) external;
}

contract CCListingTemplate is Ownable {
    mapping(address router => bool isRouter) public routers;
    address[] private routerAddresses;
    
    address public uniswapV2Factory; // Uniswap V2 Factory address
    address public uniswapV2Router; // Uniswap V2 Router address
    address public registryAddress; // Token registry address
    address public globalizerAddress; // Globalizer address
    
    uint256 private nextOrderId;
    
    uint256[] private _pendingBuyOrders;
    uint256[] private _pendingSellOrders;
    mapping(address maker => uint256[] orderIds) private makerPendingOrders;
    
    // Per-pair historical data: tokenA => tokenB => HistoricalData[]
    mapping(address => mapping(address => HistoricalData[])) private _historicalData;
    
    // Per-pair day start indices: tokenA => tokenB => timestamp => index
    mapping(address => mapping(address => mapping(uint256 => uint256))) private _dayStartIndices;

    mapping(uint256 orderId => BuyOrder) private buyOrders;
    mapping(uint256 orderId => SellOrder) private sellOrders;
    mapping(uint256 orderId => OrderStatus) private orderStatus;

    
    struct HistoricalData {
        uint256 price;
        uint256 xBalance;
        uint256 yBalance;
        uint256 xVolume;
        uint256 yVolume;
        uint256 timestamp;
    }

    struct BuyOrder {
        address[] addresses; // [0]: maker, [1]: recipient, [2]: startToken, [3]: endToken
        uint256[] prices; // [0]: maxPrice, [1]: minPrice
        uint256[] amounts; // [0]: pending, [1]: filled, [2]: amountSent
        uint8 status; // 0: cancelled, 1: pending, 2: partially filled, 3: filled
    }

    struct SellOrder {
        address[] addresses; // [0]: maker, [1]: recipient, [2]: startToken, [3]: endToken
        uint256[] prices; // [0]: maxPrice, [1]: minPrice
        uint256[] amounts; // [0]: pending, [1]: filled, [2]: amountSent
        uint8 status; // 0: cancelled, 1: pending, 2: partially filled, 3: filled
    }

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
    
    struct OrderStatus {
        bool hasCore;
        bool hasPricing;
        bool hasAmounts;
    }
    
    event OrderUpdated(uint256 orderId, bool isBuy, uint8 status);
    event GlobalizerAddressSet(address indexed globalizer);
    event RegistryAddressSet(address indexed registry);
    event UniswapFactorySet(address indexed factory);
    event UniswapRouterSet(address indexed router);
    event RouterAdded(address indexed router);
    event RouterRemoved(address indexed router);
    event GlobalUpdateFailed(string reason);
    event RegistryUpdateFailed(address indexed user, address[] tokens, string reason);
    event ExternalCallFailed(address indexed target, string functionName, string reason);
    event TransactionFailed(address indexed recipient, string reason);
    event UpdateFailed(string reason);
    event OrderUpdateIncomplete(uint256 orderId, string reason);
    event OrderUpdatesComplete(uint256 orderId, bool isBuy);
    event TokensWithdrawn(address indexed token, address indexed recipient, uint256 amount);

    // Normalizes amount to 1e18 precision
    function normalize(uint256 amount, uint8 decimals) internal pure returns (uint256 normalized) {
        if (decimals == 18) return amount;
        else if (decimals < 18) return amount * 10 ** (uint256(18) - uint256(decimals));
        else return amount / 10 ** (uint256(decimals) - uint256(18));
    }

    // Denormalizes amount from 1e18 to token decimals
    function denormalize(uint256 amount, uint8 decimals) internal pure returns (uint256 denormalized) {
        if (decimals == 18) return amount;
        else if (decimals < 18) return amount / 10 ** (uint256(18) - uint256(decimals));
        else return amount * 10 ** (uint256(decimals) - uint256(18));
    }

    // Checks if two timestamps are on the same day
    function _isSameDay(uint256 time1, uint256 time2) internal pure returns (bool sameDay) {
        return (time1 / 86400) == (time2 / 86400);
    }

    // Rounds timestamp to midnight
    function _floorToMidnight(uint256 timestamp) internal pure returns (uint256 midnight) {
        return (timestamp / 86400) * 86400;
    }

    // Gets canonical token pair ordering
    function _getTokenPair(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "Identical tokens");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    // Updates token registry with balances for both tokens for a single user
    function _updateRegistry(address maker, address[] memory tokens) internal {
        if (registryAddress == address(0) || maker == address(0)) {
            emit RegistryUpdateFailed(maker, tokens, "Invalid registry or maker address");
            return;
        }
        try ITokenRegistry(registryAddress).initializeTokens(maker, tokens) {
        } catch (bytes memory reason) {
            string memory decodedReason = string(reason);
            emit RegistryUpdateFailed(maker, tokens, decodedReason);
            emit ExternalCallFailed(registryAddress, "initializeTokens", decodedReason);
        }
    }

    // Removes order ID from array
    function removePendingOrder(uint256[] storage orders, uint256 orderId) internal {
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i] == orderId) {
                orders[i] = orders[orders.length - 1];
                orders.pop();
                break;
            }
        }
    }

    // Calls globalizeOrders with latest order details
    function globalizeUpdate(address maker, address token) internal {
        if (globalizerAddress == address(0)) {
            emit GlobalUpdateFailed("Invalid globalizer address");
            return;
        }
        if (maker == address(0) || token == address(0)) {
            return;
        }
        try ICCGlobalizer(globalizerAddress).globalizeOrders(maker, token) {
        } catch (bytes memory reason) {
            string memory decodedReason = string(reason);
            emit ExternalCallFailed(globalizerAddress, "globalizeOrders", decodedReason);
            emit GlobalUpdateFailed(decodedReason);
        }
    }

    // Sets Uniswap V2 Factory address, restricted to owner
    function setUniswapV2Factory(address _factory) external onlyOwner {
        require(_factory != address(0), "Invalid factory address");
        uniswapV2Factory = _factory;
        emit UniswapFactorySet(_factory);
    }

    // Sets Uniswap V2 Router address, restricted to owner
    function setUniswapV2Router(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router address");
        uniswapV2Router = _router;
        emit UniswapRouterSet(_router);
    }

    // Sets registry address, restricted to owner
    function setRegistry(address _registryAddress) external onlyOwner {
        require(_registryAddress != address(0), "Invalid registry address");
        registryAddress = _registryAddress;
        emit RegistryAddressSet(_registryAddress);
    }

    // Sets globalizer address, restricted to owner
    function setGlobalizerAddress(address _globalizerAddress) external onlyOwner {
        require(_globalizerAddress != address(0), "Invalid globalizer address");
        globalizerAddress = _globalizerAddress;
        emit GlobalizerAddressSet(_globalizerAddress);
    }

    // Adds a router address, restricted to owner
    function addRouter(address router) external onlyOwner {
        require(router != address(0), "Invalid router address");
        require(!routers[router], "Router already exists");
        routers[router] = true;
        routerAddresses.push(router);
        emit RouterAdded(router);
    }

    // Removes a router address, restricted to owner
    function removeRouter(address router) external onlyOwner {
        require(router != address(0), "Invalid router address");
        require(routers[router], "Router does not exist");
        routers[router] = false;
        for (uint256 i = 0; i < routerAddresses.length; i++) {
            if (routerAddresses[i] == router) {
                routerAddresses[i] = routerAddresses[routerAddresses.length - 1];
                routerAddresses.pop();
                break;
            }
        }
        emit RouterRemoved(router);
    }

    // Allows routers to withdraw any token held by this contract
    function withdrawToken(address token, uint256 amount, address recipient) external {
        require(routers[msg.sender], "Caller not router");
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        
        if (token == address(0)) {
            // Withdraw native ETH
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool success, ) = recipient.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            // Withdraw ERC20 token
            require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient token balance");
            require(IERC20(token).transfer(recipient, amount), "Token transfer failed");
        }
        
        emit TokensWithdrawn(token, recipient, amount);
    }

    // Returns pending buy order IDs
    function pendingBuyOrdersView() external view returns (uint256[] memory) {
        return _pendingBuyOrders;
    }

    // Returns pending sell order IDs
    function pendingSellOrdersView() external view returns (uint256[] memory) {
        return _pendingSellOrders;
    }

    // Processes buy order updates
    function _processBuyOrderUpdate(BuyOrderUpdate memory update) internal {
        uint256 orderId = update.orderId;
        BuyOrder storage order = buyOrders[orderId];
        
        if (update.structId == 0) { // Core
            order.addresses = update.addresses;
            order.status = update.status;
            orderStatus[orderId].hasCore = true;
            
            if (update.status == 0 || update.status == 3) {
                removePendingOrder(_pendingBuyOrders, orderId);
                if (update.addresses.length > 0) {
                    removePendingOrder(makerPendingOrders[update.addresses[0]], orderId);
                }
            } else if (update.status == 1) {
                _pendingBuyOrders.push(orderId);
                if (update.addresses.length > 0) {
                    makerPendingOrders[update.addresses[0]].push(orderId);
                    address[] memory tokens = new address[](2);
                    tokens[0] = update.addresses[2]; // startToken
                    tokens[1] = update.addresses[3]; // endToken
                    _updateRegistry(update.addresses[0], tokens);
                }
                nextOrderId++;
            }
            emit OrderUpdated(orderId, true, update.status);
        } else if (update.structId == 1) { // Pricing
            order.prices = update.prices;
            orderStatus[orderId].hasPricing = true;
        } else if (update.structId == 2) { // Amounts
            uint256 oldFilled = order.amounts.length > 1 ? order.amounts[1] : 0;
            uint256 oldAmountSent = order.amounts.length > 2 ? order.amounts[2] : 0;
            order.amounts = update.amounts;
            orderStatus[orderId].hasAmounts = true;
            
            // Update historical volumes for the specific pair
            if (update.addresses.length >= 4) {
                address startToken = update.addresses[2];
                address endToken = update.addresses[3];
                (address token0, address token1) = _getTokenPair(startToken, endToken);
                
                if (_historicalData[token0][token1].length > 0) {
                    if (update.amounts.length > 1 && update.amounts[1] > oldFilled) {
                        _historicalData[token0][token1][_historicalData[token0][token1].length - 1].yVolume += (update.amounts[1] - oldFilled);
                    }
                    if (update.amounts.length > 2 && update.amounts[2] > oldAmountSent) {
                        _historicalData[token0][token1][_historicalData[token0][token1].length - 1].xVolume += (update.amounts[2] - oldAmountSent);
                    }
                }
            }
        } else {
            emit UpdateFailed("Invalid buy order structId");
        }
    }

    // Processes sell order updates
    function _processSellOrderUpdate(SellOrderUpdate memory update) internal {
        uint256 orderId = update.orderId;
        SellOrder storage order = sellOrders[orderId];
        
        if (update.structId == 0) { // Core
            order.addresses = update.addresses;
            order.status = update.status;
            orderStatus[orderId].hasCore = true;
            
            if (update.status == 0 || update.status == 3) {
                removePendingOrder(_pendingSellOrders, orderId);
                if (update.addresses.length > 0) {
                    removePendingOrder(makerPendingOrders[update.addresses[0]], orderId);
                }
            } else if (update.status == 1) {
                _pendingSellOrders.push(orderId);
                if (update.addresses.length > 0) {
                    makerPendingOrders[update.addresses[0]].push(orderId);
                    address[] memory tokens = new address[](2);
                    tokens[0] = update.addresses[2]; // startToken
                    tokens[1] = update.addresses[3]; // endToken
                    _updateRegistry(update.addresses[0], tokens);
                }
                nextOrderId++;
            }
            emit OrderUpdated(orderId, false, update.status);
        } else if (update.structId == 1) { // Pricing
            order.prices = update.prices;
            orderStatus[orderId].hasPricing = true;
        } else if (update.structId == 2) { // Amounts
            uint256 oldFilled = order.amounts.length > 1 ? order.amounts[1] : 0;
            uint256 oldAmountSent = order.amounts.length > 2 ? order.amounts[2] : 0;
            order.amounts = update.amounts;
            orderStatus[orderId].hasAmounts = true;
            
            // Update historical volumes for the specific pair
            if (update.addresses.length >= 4) {
                address startToken = update.addresses[2];
                address endToken = update.addresses[3];
                (address token0, address token1) = _getTokenPair(startToken, endToken);
                
                if (_historicalData[token0][token1].length > 0) {
                    if (update.amounts.length > 1 && update.amounts[1] > oldFilled) {
                        _historicalData[token0][token1][_historicalData[token0][token1].length - 1].xVolume += (update.amounts[1] - oldFilled);
                    }
                    if (update.amounts.length > 2 && update.amounts[2] > oldAmountSent) {
                        _historicalData[token0][token1][_historicalData[token0][token1].length - 1].yVolume += (update.amounts[2] - oldAmountSent);
                    }
                }
            }
        } else {
            emit UpdateFailed("Invalid sell order structId");
        }
    }

    // Updates historical data for a specific pair
    function _updateHistoricalData(HistoricalUpdate memory update) internal {
        (address token0, address token1) = _getTokenPair(update.tokenA, update.tokenB);
        
        _historicalData[token0][token1].push(HistoricalData({
            price: update.price,
            xBalance: update.xBalance,
            yBalance: update.yBalance,
            xVolume: update.xVolume,
            yVolume: update.yVolume,
            timestamp: update.timestamp > 0 ? update.timestamp : _floorToMidnight(block.timestamp)
        }));
    }

    // Updates day start index for a specific pair
    function _updateDayStartIndex(address tokenA, address tokenB, uint256 timestamp) internal {
        (address token0, address token1) = _getTokenPair(tokenA, tokenB);
        uint256 midnight = _floorToMidnight(timestamp);
        
        if (_dayStartIndices[token0][token1][midnight] == 0) {
            _dayStartIndices[token0][token1][midnight] = _historicalData[token0][token1].length - 1;
        }
    }

    // Processes historical data updates
    function _processHistoricalUpdate(HistoricalUpdate memory update) internal returns (bool historicalUpdated) {
        if (update.price == 0) {
            emit UpdateFailed("Invalid historical price");
            return false;
        }
        _updateHistoricalData(update);
        _updateDayStartIndex(update.tokenA, update.tokenB, update.timestamp);
        return true;
    }

    // Main update function for routers
    function ccUpdate(
        BuyOrderUpdate[] calldata buyUpdates,
        SellOrderUpdate[] calldata sellUpdates,
        HistoricalUpdate[] calldata historicalUpdates
    ) external {
        require(routers[msg.sender], "Not a router");

        address lastMaker;
        address lastToken;

        // Process buy order updates
        for (uint256 i = 0; i < buyUpdates.length; i++) {
            _processBuyOrderUpdate(buyUpdates[i]);
            if (buyUpdates[i].addresses.length > 0) {
                lastMaker = buyUpdates[i].addresses[0];
                lastToken = buyUpdates[i].addresses[3]; // endToken for buy orders
            }
        }

        // Process sell order updates
        for (uint256 i = 0; i < sellUpdates.length; i++) {
            _processSellOrderUpdate(sellUpdates[i]);
            if (sellUpdates[i].addresses.length > 0) {
                lastMaker = sellUpdates[i].addresses[0];
                lastToken = sellUpdates[i].addresses[2]; // startToken for sell orders
            }
        }
        // Process historical data updates
        for (uint256 i = 0; i < historicalUpdates.length; i++) {
            if (!_processHistoricalUpdate(historicalUpdates[i])) {
                emit UpdateFailed("Historical update failed");
            }
        }

        // Check order completeness
        for (uint256 i = 0; i < buyUpdates.length; i++) {
            uint256 orderId = buyUpdates[i].orderId;
            OrderStatus storage status = orderStatus[orderId];
            if (status.hasCore && status.hasPricing && status.hasAmounts) {
                emit OrderUpdatesComplete(orderId, true);
            } else {
                string memory reason = !status.hasCore ? "Missing Core" :
                                      !status.hasPricing ? "Missing Pricing" : "Missing Amounts";
                emit OrderUpdateIncomplete(orderId, reason);
            }
        }

        for (uint256 i = 0; i < sellUpdates.length; i++) {
            uint256 orderId = sellUpdates[i].orderId;
            OrderStatus storage status = orderStatus[orderId];
            if (status.hasCore && status.hasPricing && status.hasAmounts) {
                emit OrderUpdatesComplete(orderId, false);
            } else {
                string memory reason = !status.hasCore ? "Missing Core" :
                                      !status.hasPricing ? "Missing Pricing" : "Missing Amounts";
                emit OrderUpdateIncomplete(orderId, reason);
            }
        }

        // Call globalizer with last maker and token
        if (lastMaker != address(0) && lastToken != address(0)) {
            globalizeUpdate(lastMaker, lastToken);
        }
    }

    // Computes current price from Uniswap V2 pair for given tokens
    function prices(address tokenA, address tokenB) external view returns (uint256 price) {
        require(uniswapV2Factory != address(0), "Factory not set");
        
        address pairAddress = IUniswapV2Factory(uniswapV2Factory).getPair(tokenA, tokenB);
        if (pairAddress == address(0)) {
            return 0; // No pair exists
        }

        uint8 decimalsA = tokenA == address(0) ? 18 : IERC20(tokenA).decimals();
        uint8 decimalsB = tokenB == address(0) ? 18 : IERC20(tokenB).decimals();

        uint256 balanceA;
        uint256 balanceB;

        try IERC20(tokenA).balanceOf(pairAddress) returns (uint256 balA) {
            balanceA = normalize(balA, decimalsA);
        } catch {
            return 1;
        }

        try IERC20(tokenB).balanceOf(pairAddress) returns (uint256 balB) {
            balanceB = normalize(balB, decimalsB);
        } catch {
            return 1;
        }

        return balanceA == 0 ? 0 : (balanceB * 1e18) / balanceA;
    }

    // Returns router addresses
    function routerAddressesView() external view returns (address[] memory) {
        return routerAddresses;
    }

    // Returns next order ID
    function getNextOrderId() external view returns (uint256) {
        return nextOrderId;
    }

    // Returns buy order details
    function getBuyOrder(uint256 orderId) external view returns (
        address[] memory addresses,
        uint256[] memory prices_,
        uint256[] memory amounts,
        uint8 status
    ) {
        BuyOrder memory order = buyOrders[orderId];
        return (order.addresses, order.prices, order.amounts, order.status);
    }

    // Returns sell order details
    function getSellOrder(uint256 orderId) external view returns (
        address[] memory addresses,
        uint256[] memory prices_,
        uint256[] memory amounts,
        uint8 status
    ) {
        SellOrder memory order = sellOrders[orderId];
        return (order.addresses, order.prices, order.amounts, order.status);
    }

    // Returns pending orders for a maker
    function makerPendingOrdersView(address maker) external view returns (uint256[] memory) {
        return makerPendingOrders[maker];
    }

    // Returns historical data at index for a specific pair
    function getHistoricalDataView(address tokenA, address tokenB, uint256 index) external view returns (HistoricalData memory) {
        (address token0, address token1) = _getTokenPair(tokenA, tokenB);
        require(index < _historicalData[token0][token1].length, "Invalid index");
        return _historicalData[token0][token1][index];
    }

    // Returns historical data length for a specific pair
    function historicalDataLengthView(address tokenA, address tokenB) external view returns (uint256) {
        (address token0, address token1) = _getTokenPair(tokenA, tokenB);
        return _historicalData[token0][token1].length;
    }

    // Returns day start index for midnight timestamp for a specific pair
    function getDayStartIndex(address tokenA, address tokenB, uint256 midnightTimestamp) external view returns (uint256) {
        (address token0, address token1) = _getTokenPair(tokenA, tokenB);
        return _dayStartIndices[token0][token1][midnightTimestamp];
    }

    // Utility functions
    function floorToMidnightView(uint256 inputTimestamp) external pure returns (uint256) {
        return (inputTimestamp / 86400) * 86400;
    }

    function isSameDayView(uint256 firstTimestamp, uint256 secondTimestamp) external pure returns (bool) {
        return (firstTimestamp / 86400) == (secondTimestamp / 86400);
    }

    // Allows contract to receive ETH
    receive() external payable {}
}