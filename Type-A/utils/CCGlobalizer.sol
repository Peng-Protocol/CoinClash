/*
 SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
 Version: 0.2.13
 Changes:
 - v0.2.13: Modified globalizeOrders to initialize tokenListings for both tokenA and tokenB from ICCListingTemplate. Added _isListingGlobalized to check listing in tokenListings. Modified getAllListingOrders to restrict to globalized listings using _isListingGlobalized. Updated getAllUserActiveOrders, getAllUserOrdersHistory, getAllUserTokenActiveOrders, and getAllUserTokenOrdersHistory to filter listings with _isListingGlobalized. Maintained compatibility with CCLiquidityTemplate.sol (v0.1.4) and CCListingTemplate.sol (v0.2.7).
 - v0.2.12: Modified _isTemplateGlobalized to remove token parameter, checking template globalization via ICCAgent.isValidListing and ICCLiquidityTemplate.listingAddress. Updated getAllTemplateLiquidity to remove token parameter and return all X and Y liquidity slot IDs using activeXLiquiditySlotsView and activeYLiquiditySlotsView. Adjusted getAllUserActiveLiquidity, getAllUserTokenActiveLiquidity, and getAllTokenLiquidity to use updated _isTemplateGlobalized.
 - v0.2.11: Fixed TypeError in _isTemplateGlobalized by removing invalid tokenListings.length iteration, added token parameter to check template in tokenLiquidityTemplates[token]. Updated getAllTemplateLiquidity, getAllUserActiveLiquidity, and getAllUserTokenActiveLiquidity to pass token to _isTemplateGlobalized. Modified getAllListingOrders to use ICCAgent.isValidListing for globalization check.
 - v0.2.10: Modified getAllTemplateLiquidity to return data only if template is globalized. Added getAllListingOrders for globalized listing orders.
 - v0.2.9: Modified globalizeLiquidity to remove external fetches to ICCLiquidityTemplate (except ICCAgent validation), accepting only depositor and token, storing valid liquidity address. Removed depositorSlotSnapshots and slotStatus mappings. Removed getAllUserLiquidityHistory, getAllUserTokenLiquidityHistory, and _fetchHistoricalSlotData. Added getUserHistoricalTemplates.
*/

//To-Do: Monolithic refactor for listing template, new Type-C monolithic liquidity template integration.

pragma solidity ^0.8.2;

import "../imports/Ownable.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
}

interface ICCLiquidityTemplate {
    function listingAddress() external view returns (address);
    function userXIndexView(address user) external view returns (uint256[] memory indices);
    function userYIndexView(address user) external view returns (uint256[] memory indices);
    function getXSlotView(uint256 index) external view returns (Slot memory slot);
    function getYSlotView(uint256 index) external view returns (Slot memory slot);
    function activeXLiquiditySlotsView() external view returns (uint256[] memory slots);
    function activeYLiquiditySlotsView() external view returns (uint256[] memory slots);
    struct Slot {
        address depositor;
        address recipient;
        uint256 allocation;
        uint256 dFeesAcc;
        uint256 timestamp;
    }
}

interface ICCListingTemplate {
    function makerPendingBuyOrdersView(address maker, uint256 step, uint256 maxIterations) external view returns (uint256[] memory orderIds);
    function makerPendingSellOrdersView(address maker, uint256 step, uint256 maxIterations) external view returns (uint256[] memory orderIds);
    function pendingBuyOrdersView() external view returns (uint256[] memory orderIds);
    function pendingSellOrdersView() external view returns (uint256[] memory orderIds);
    function tokenA() external view returns (address);
    function tokenB() external view returns (address);
    function makerOrdersView(address maker, uint256 step, uint256 maxIterations) external view returns (uint256[] memory orderIds);
}

interface ICCAgent {
    function isValidListing(address listingAddress) external view returns (bool isValid, ListingDetails memory details);
    struct ListingDetails {
        address listingAddress;
        address liquidityAddress;
        address tokenA;
        address tokenB;
        uint256 listingId;
    }
}

contract CCGlobalizer is Ownable {
    address public agent;
    mapping(address => mapping(address => address[])) public makerTokensByListing; // maker -> listing -> tokens
    mapping(address => mapping(address => address[])) public depositorTokensByLiquidity; // depositor -> liquidity -> tokens
    mapping(address => address[]) public makerListings; // maker -> listings
    mapping(address => address[]) public depositorLiquidityTemplates; // depositor -> liquidity templates
    mapping(address => address[]) public tokenListings; // token -> listings
    mapping(address => address[]) public tokenLiquidityTemplates; // token -> liquidity templates

    // Structs for grouped output
    struct OrderGroup {
        address listing;
        uint256[] orderIds;
    }
    struct SlotGroup {
        address template;
        uint256[] slotIndices;
        bool[] isX;
    }

    // Private struct for internal data management
    struct OrderData {
        uint256[] buyIds;
        uint256[] sellIds;
        uint256 totalOrders;
    }
    struct SlotData {
        uint256[] slotIndices;
        bool[] isX;
        uint256 totalSlots;
    }

    event AgentSet(address indexed agent);
    event OrdersGlobalized(address indexed maker, address indexed listing, address indexed token);
    event LiquidityGlobalized(address indexed depositor, address indexed liquidity, address indexed token);
    event GlobalizeLiquidityFailed(address indexed depositor, address indexed liquidity, address indexed token, string reason);
    event GlobalizeOrdersFailed(address indexed maker, address indexed listing, address indexed token, string reason);

    // Sets agent address, callable once by owner
    function setAgent(address _agent) external onlyOwner {
        // Validates and sets agent address, emits failure event if invalid
        if (agent != address(0) || _agent == address(0)) {
            emit GlobalizeOrdersFailed(address(0), address(0), address(0), "Agent already set or invalid");
            return;
        }
        agent = _agent;
        emit AgentSet(_agent);
    }

    // Helper to check if an address is in an array
    function isInArray(address[] memory array, address element) internal pure returns (bool) {
        // Returns true if element exists in array
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == element) return true;
        }
        return false;
    }

    // Removes an address from an array
    function removeFromArray(address[] storage array, address element) internal {
        // Removes element from array by swapping with last and popping
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == element) {
                array[i] = array[array.length - 1];
                array.pop();
                break;
            }
        }
    }

    // Updates depositor liquidity mappings, callable by valid liquidity templates
    function globalizeLiquidity(address depositor, address token) external {
        // Validates inputs and updates mappings without fetching slot data
        if (agent == address(0)) {
            emit GlobalizeLiquidityFailed(depositor, msg.sender, token, "Agent not set");
            return;
        }
        if (depositor == address(0)) {
            emit GlobalizeLiquidityFailed(depositor, msg.sender, token, "Invalid depositor address");
            return;
        }
        if (token == address(0)) {
            emit GlobalizeLiquidityFailed(depositor, msg.sender, token, "Invalid token address");
            return;
        }
        address listingAddress;
        try ICCLiquidityTemplate(msg.sender).listingAddress() returns (address addr) {
            listingAddress = addr;
        } catch (bytes memory reason) {
            emit GlobalizeLiquidityFailed(depositor, msg.sender, token, string(abi.encodePacked("Failed to fetch listing address: ", reason)));
            return;
        }
        if (listingAddress == address(0)) {
            emit GlobalizeLiquidityFailed(depositor, msg.sender, token, "Invalid listing address");
            return;
        }
        (bool isValid, ICCAgent.ListingDetails memory details) = ICCAgent(agent).isValidListing(listingAddress);
        if (!isValid) {
            emit GlobalizeLiquidityFailed(depositor, msg.sender, token, "Invalid listing");
            return;
        }
        if (details.liquidityAddress != msg.sender) {
            emit GlobalizeLiquidityFailed(depositor, msg.sender, token, "Liquidity address mismatch");
            return;
        }
        if (details.tokenA != token && details.tokenB != token) {
            emit GlobalizeLiquidityFailed(depositor, msg.sender, token, "Token not in listing");
            return;
        }

        // Update mappings and arrays
        if (!isInArray(depositorTokensByLiquidity[depositor][msg.sender], token)) {
            depositorTokensByLiquidity[depositor][msg.sender].push(token);
        }
        if (!isInArray(depositorLiquidityTemplates[depositor], msg.sender)) {
            depositorLiquidityTemplates[depositor].push(msg.sender);
        }
        if (!isInArray(tokenLiquidityTemplates[token], msg.sender)) {
            tokenLiquidityTemplates[token].push(msg.sender);
        }
        emit LiquidityGlobalized(depositor, msg.sender, token);
    }

    // Updates maker order mappings, callable by valid listings
    function globalizeOrders(address maker, address token) external {
        // Validates inputs and updates order mappings
        if (agent == address(0)) {
            emit GlobalizeOrdersFailed(maker, msg.sender, token, "Agent not set");
            return;
        }
        if (maker == address(0)) {
            emit GlobalizeOrdersFailed(maker, msg.sender, token, "Invalid maker address");
            return;
        }
        if (token == address(0)) {
            emit GlobalizeOrdersFailed(maker, msg.sender, token, "Invalid token address");
            return;
        }
        (bool isValid, ICCAgent.ListingDetails memory details) = ICCAgent(agent).isValidListing(msg.sender);
        if (!isValid) {
            emit GlobalizeOrdersFailed(maker, msg.sender, token, "Invalid listing");
            return;
        }
        if (details.listingAddress != msg.sender) {
            emit GlobalizeOrdersFailed(maker, msg.sender, token, "Listing address mismatch");
            return;
        }
        if (details.tokenA != token && details.tokenB != token) {
            emit GlobalizeOrdersFailed(maker, msg.sender, token, "Token not in listing");
            return;
        }

        // Fetch tokenA and tokenB to initialize tokenListings
        address tokenA = ICCListingTemplate(msg.sender).tokenA();
        address tokenB = ICCListingTemplate(msg.sender).tokenB();
        
        // Update mappings and arrays
        if (!isInArray(makerTokensByListing[maker][msg.sender], token)) {
            makerTokensByListing[maker][msg.sender].push(token);
        }
        if (!isInArray(makerListings[maker], msg.sender)) {
            makerListings[maker].push(msg.sender);
        }
        if (!isInArray(tokenListings[tokenA], msg.sender)) {
            tokenListings[tokenA].push(msg.sender);
        }
        if (!isInArray(tokenListings[tokenB], msg.sender)) {
            tokenListings[tokenB].push(msg.sender);
        }
        emit OrdersGlobalized(maker, msg.sender, token);
    }

    // Helper: Fetches order data for a listing (pending orders only)
    function _fetchOrderData(address listing, address user) internal view returns (OrderData memory data) {
        // Fetches pending buy and sell order IDs for a user in a listing
        uint256[] memory buyIds = ICCListingTemplate(listing).makerPendingBuyOrdersView(user, 0, type(uint256).max);
        uint256[] memory sellIds = ICCListingTemplate(listing).makerPendingSellOrdersView(user, 0, type(uint256).max);
        return OrderData(buyIds, sellIds, buyIds.length + sellIds.length);
    }

    // Helper: Fetches all order data for a listing (all orders)
    function _fetchAllOrderData(address listing, address user) internal view returns (OrderData memory data) {
        // Fetches all order IDs for a user in a listing
        uint256[] memory buyIds = ICCListingTemplate(listing).makerOrdersView(user, 0, type(uint256).max);
        uint256[] memory sellIds = ICCListingTemplate(listing).makerOrdersView(user, 0, type(uint256).max);
        return OrderData(buyIds, sellIds, buyIds.length + sellIds.length);
    }

    // Helper: Combines order IDs
    function _combineOrderIds(OrderData memory data) internal pure returns (uint256[] memory combinedIds) {
        // Combines buy and sell order IDs into a single array
        combinedIds = new uint256[](data.totalOrders);
        uint256 index = 0;
        for (uint256 i = 0; i < data.buyIds.length; i++) {
            combinedIds[index] = data.buyIds[i];
            index++;
        }
        for (uint256 i = 0; i < data.sellIds.length; i++) {
            combinedIds[index] = data.sellIds[i];
            index++;
        }
    }

    // Helper: Checks if a listing is globalized
    function _isListingGlobalized(address listing) internal view returns (bool) {
        // Returns true if listing is associated with any token in tokenListings
        if (agent == address(0)) return false;
        address tokenA = ICCListingTemplate(listing).tokenA();
        address tokenB = ICCListingTemplate(listing).tokenB();
        return isInArray(tokenListings[tokenA], listing) || isInArray(tokenListings[tokenB], listing);
    }

    // Returns all user order IDs grouped by listing (pending orders only)
    function getAllUserActiveOrders(address user, uint256 step, uint256 maxIterations) external view returns (OrderGroup[] memory orderGroups) {
        // Returns pending order IDs grouped by listing in reverse order (latest first)
        uint256 length = makerListings[user].length;
        if (step >= length) return new OrderGroup[](0);
        uint256 limit = maxIterations < (length - step) ? maxIterations : (length - step);
        uint256 validCount = 0;
        for (uint256 i = 0; i < limit; i++) {
            address listing = makerListings[user][length - 1 - (step + i)];
            if (_isListingGlobalized(listing)) {
                validCount++;
            }
        }
        orderGroups = new OrderGroup[](validCount);
        uint256 index = 0;
        for (uint256 i = 0; i < limit && index < validCount; i++) {
            address listing = makerListings[user][length - 1 - (step + i)];
            if (_isListingGlobalized(listing)) {
                OrderData memory data = _fetchOrderData(listing, user);
                orderGroups[index] = OrderGroup(listing, _combineOrderIds(data));
                index++;
            }
        }
    }

    // Returns all user order IDs grouped by listing (all orders)
    function getAllUserOrdersHistory(address user, uint256 step, uint256 maxIterations) external view returns (OrderGroup[] memory orderGroups) {
        // Returns all order IDs grouped by listing in reverse order (latest first)
        uint256 length = makerListings[user].length;
        if (step >= length) return new OrderGroup[](0);
        uint256 limit = maxIterations < (length - step) ? maxIterations : (length - step);
        uint256 validCount = 0;
        for (uint256 i = 0; i < limit; i++) {
            address listing = makerListings[user][length - 1 - (step + i)];
            if (_isListingGlobalized(listing)) {
                validCount++;
            }
        }
        orderGroups = new OrderGroup[](validCount);
        uint256 index = 0;
        for (uint256 i = 0; i < limit && index < validCount; i++) {
            address listing = makerListings[user][length - 1 - (step + i)];
            if (_isListingGlobalized(listing)) {
                OrderData memory data = _fetchAllOrderData(listing, user);
                orderGroups[index] = OrderGroup(listing, _combineOrderIds(data));
                index++;
            }
        }
    }

    // Helper: Counts valid listings for a token
    function _countValidListings(address user, address token, uint256 step, uint256 maxIterations) internal view returns (uint256 validCount) {
        // Counts listings containing the specified token
        uint256 length = makerListings[user].length;
        uint256 limit = maxIterations < (length - step) ? maxIterations : (length - step);
        for (uint256 i = 0; i < limit; i++) {
            address listing = makerListings[user][length - 1 - (step + i)];
            if (isInArray(makerTokensByListing[user][listing], token) && _isListingGlobalized(listing)) {
                validCount++;
            }
        }
    }

    // Returns user order IDs for a specific token grouped by listing (pending orders)
    function getAllUserTokenActiveOrders(address user, address token, uint256 step, uint256 maxIterations) external view returns (OrderGroup[] memory orderGroups) {
        // Returns pending order IDs for a token in reverse order (latest first)
        uint256 length = makerListings[user].length;
        if (step >= length) return new OrderGroup[](0);
        uint256 validCount = _countValidListings(user, token, step, maxIterations);
        orderGroups = new OrderGroup[](validCount);
        uint256 limit = maxIterations < (length - step) ? maxIterations : (length - step);
        uint256 index = 0;
        for (uint256 i = 0; i < limit && index < validCount; i++) {
            address listing = makerListings[user][length - 1 - (step + i)];
            if (isInArray(makerTokensByListing[user][listing], token) && _isListingGlobalized(listing)) {
                OrderData memory data = _fetchOrderData(listing, user);
                orderGroups[index] = OrderGroup(listing, _combineOrderIds(data));
                index++;
            }
        }
    }

    // Returns user order IDs for a specific token grouped by listing (all orders)
    function getAllUserTokenOrdersHistory(address user, address token, uint256 step, uint256 maxIterations) external view returns (OrderGroup[] memory orderGroups) {
        // Returns all order IDs for a token in reverse order (latest first)
        uint256 length = makerListings[user].length;
        if (step >= length) return new OrderGroup[](0);
        uint256 validCount = _countValidListings(user, token, step, maxIterations);
        orderGroups = new OrderGroup[](validCount);
        uint256 limit = maxIterations < (length - step) ? maxIterations : (length - step);
        uint256 index = 0;
        for (uint256 i = 0; i < limit && index < validCount; i++) {
            address listing = makerListings[user][length - 1 - (step + i)];
            if (isInArray(makerTokensByListing[user][listing], token) && _isListingGlobalized(listing)) {
                OrderData memory data = _fetchAllOrderData(listing, user);
                orderGroups[index] = OrderGroup(listing, _combineOrderIds(data));
                index++;
            }
        }
    }

    // Helper: Fetches active slot data for a template
    function _fetchSlotData(address template, address user) internal view returns (SlotData memory data) {
        // Fetches active X and Y slot indices for a user in a template
        uint256[] memory xIndices = ICCLiquidityTemplate(template).userXIndexView(user);
        uint256[] memory yIndices = ICCLiquidityTemplate(template).userYIndexView(user);
        uint256[] memory slotIndices = new uint256[](xIndices.length + yIndices.length);
        bool[] memory isX = new bool[](xIndices.length + yIndices.length);
        uint256 index = 0;
        for (uint256 i = 0; i < xIndices.length; i++) {
            ICCLiquidityTemplate.Slot memory slot = ICCLiquidityTemplate(template).getXSlotView(xIndices[i]);
            if (slot.depositor == user && slot.allocation > 0) {
                slotIndices[index] = xIndices[i];
                isX[index] = true;
                index++;
            }
        }
        for (uint256 i = 0; i < yIndices.length; i++) {
            ICCLiquidityTemplate.Slot memory slot = ICCLiquidityTemplate(template).getYSlotView(yIndices[i]);
            if (slot.depositor == user && slot.allocation > 0) {
                slotIndices[index] = yIndices[i];
                isX[index] = false;
                index++;
            }
        }
        uint256[] memory resizedIndices = new uint256[](index);
        bool[] memory resizedIsX = new bool[](index);
        for (uint256 i = 0; i < index; i++) {
            resizedIndices[i] = slotIndices[i];
            resizedIsX[i] = isX[i];
        }
        return SlotData(resizedIndices, resizedIsX, index);
    }

    // Helper: Fetches all active slot data for a template
    function _fetchTemplateSlotData(address template) internal view returns (SlotData memory data) {
        // Fetches all active X and Y slot indices for a template
        uint256[] memory xIndices = ICCLiquidityTemplate(template).activeXLiquiditySlotsView();
        uint256[] memory yIndices = ICCLiquidityTemplate(template).activeYLiquiditySlotsView();
        uint256[] memory slotIndices = new uint256[](xIndices.length + yIndices.length);
        bool[] memory isX = new bool[](xIndices.length + yIndices.length);
        uint256 index = 0;
        for (uint256 i = 0; i < xIndices.length; i++) {
            ICCLiquidityTemplate.Slot memory slot = ICCLiquidityTemplate(template).getXSlotView(xIndices[i]);
            if (slot.allocation > 0) {
                slotIndices[index] = xIndices[i];
                isX[index] = true;
                index++;
            }
        }
        for (uint256 i = 0; i < yIndices.length; i++) {
            ICCLiquidityTemplate.Slot memory slot = ICCLiquidityTemplate(template).getYSlotView(yIndices[i]);
            if (slot.allocation > 0) {
                slotIndices[index] = yIndices[i];
                isX[index] = false;
                index++;
            }
        }
        uint256[] memory resizedIndices = new uint256[](index);
        bool[] memory resizedIsX = new bool[](index);
        for (uint256 i = 0; i < index; i++) {
            resizedIndices[i] = slotIndices[i];
            resizedIsX[i] = isX[i];
        }
        return SlotData(resizedIndices, resizedIsX, index);
    }

    // Helper: Checks if a template is globalized
    function _isTemplateGlobalized(address template) internal view returns (bool) {
        // Returns true if template is associated with a valid listing
        if (agent == address(0)) return false;
        address listingAddress;
        try ICCLiquidityTemplate(template).listingAddress() returns (address addr) {
            listingAddress = addr;
        } catch {
            return false;
        }
        if (listingAddress == address(0)) return false;
        (bool isValid, ICCAgent.ListingDetails memory details) = ICCAgent(agent).isValidListing(listingAddress);
        return isValid && details.liquidityAddress == template;
    }

    // Helper: Counts valid templates with active slots
    function _countValidTemplates(address user, uint256 step, uint256 maxIterations) internal view returns (uint256 validCount) {
        // Counts templates with non-empty active slots for a user
        uint256 length = depositorLiquidityTemplates[user].length;
        uint256 limit = maxIterations < (length - step) ? maxIterations : (length - step);
        for (uint256 i = 0; i < limit; i++) {
            address template = depositorLiquidityTemplates[user][length - 1 - (step + i)];
            if (_isTemplateGlobalized(template)) {
                SlotData memory data = _fetchSlotData(template, user);
                if (data.totalSlots > 0) {
                    validCount++;
                }
            }
        }
    }

    // Helper: Counts valid templates for a token with active slots
    function _countValidTokenTemplates(address user, address token, uint256 step, uint256 maxIterations) internal view returns (uint256 validCount) {
        // Counts templates with non-empty active slots for a user and token
        uint256 length = depositorLiquidityTemplates[user].length;
        uint256 limit = maxIterations < (length - step) ? maxIterations : (length - step);
        for (uint256 i = 0; i < limit; i++) {
            address template = depositorLiquidityTemplates[user][length - 1 - (step + i)];
            if (isInArray(depositorTokensByLiquidity[user][template], token) && _isTemplateGlobalized(template)) {
                SlotData memory data = _fetchSlotData(template, user);
                if (data.totalSlots > 0) {
                    validCount++;
                }
            }
        }
    }

    // Returns all user active liquidity slot indices grouped by template
    function getAllUserActiveLiquidity(address user, uint256 step, uint256 maxIterations) external view returns (SlotGroup[] memory slotGroups) {
        // Returns active slot indices grouped by template in reverse order (latest first)
        uint256 length = depositorLiquidityTemplates[user].length;
        if (step >= length) return new SlotGroup[](0);
        uint256 validCount = _countValidTemplates(user, step, maxIterations);
        slotGroups = new SlotGroup[](validCount);
        uint256 limit = maxIterations < (length - step) ? maxIterations : (length - step);
        uint256 index = 0;
        for (uint256 i = 0; i < limit && index < validCount; i++) {
            address template = depositorLiquidityTemplates[user][length - 1 - (step + i)];
            if (_isTemplateGlobalized(template)) {
                SlotData memory data = _fetchSlotData(template, user);
                if (data.totalSlots > 0) {
                    slotGroups[index] = SlotGroup(template, data.slotIndices, data.isX);
                    index++;
                }
            }
        }
    }

    // Returns user active liquidity slot indices for a specific token grouped by template
    function getAllUserTokenActiveLiquidity(address user, address token, uint256 step, uint256 maxIterations) external view returns (SlotGroup[] memory slotGroups) {
        // Returns active slot indices for a token in reverse order (latest first)
        uint256 length = depositorLiquidityTemplates[user].length;
        if (step >= length) return new SlotGroup[](0);
        uint256 validCount = _countValidTokenTemplates(user, token, step, maxIterations);
        slotGroups = new SlotGroup[](validCount);
        uint256 limit = maxIterations < (length - step) ? maxIterations : (length - step);
        uint256 index = 0;
        for (uint256 i = 0; i < limit && index < validCount; i++) {
            address template = depositorLiquidityTemplates[user][length - 1 - (step + i)];
            if (isInArray(depositorTokensByLiquidity[user][template], token) && _isTemplateGlobalized(template)) {
                SlotData memory data = _fetchSlotData(template, user);
                if (data.totalSlots > 0) {
                    slotGroups[index] = SlotGroup(template, data.slotIndices, data.isX);
                    index++;
                }
            }
        }
    }

    // Returns all liquidity slot indices for a token grouped by template
    function getAllTokenLiquidity(address token, uint256 step, uint256 maxIterations) external view returns (SlotGroup[] memory slotGroups) {
        // Returns active slot indices for a token in reverse order (latest first)
        uint256 length = tokenLiquidityTemplates[token].length;
        if (step >= length) return new SlotGroup[](0);
        uint256 limit = maxIterations < (length - step) ? maxIterations : (length - step);
        slotGroups = new SlotGroup[](limit);
        for (uint256 i = 0; i < limit; i++) {
            address template = tokenLiquidityTemplates[token][length - 1 - (step + i)];
            if (_isTemplateGlobalized(template)) {
                SlotData memory data = _fetchSlotData(template, address(0));
                slotGroups[i] = SlotGroup(template, data.slotIndices, data.isX);
            }
        }
    }

    // Returns all liquidity slot indices for a template
    function getAllTemplateLiquidity(address template, uint256 step, uint256 maxIterations) external view returns (SlotGroup memory slotGroup) {
        // Returns active slot indices for a template in reverse order (latest first) if globalized
        if (!_isTemplateGlobalized(template)) {
            return SlotGroup(address(0), new uint256[](0), new bool[](0));
        }
        SlotData memory data = _fetchTemplateSlotData(template);
        return SlotGroup(template, data.slotIndices, data.isX);
    }

    // Returns all historical liquidity templates for a user
    function getUserHistoricalTemplates(address user, uint256 step, uint256 maxIterations) external view returns (address[] memory templates) {
        // Returns liquidity templates in reverse order (latest first)
        uint256 length = depositorLiquidityTemplates[user].length;
        if (step >= length) return new address[](0);
        uint256 limit = maxIterations < (length - step) ? maxIterations : (length - step);
        templates = new address[](limit);
        for (uint256 i = 0; i < limit; i++) {
            templates[i] = depositorLiquidityTemplates[user][length - 1 - (step + i)];
        }
    }

    // Returns all order IDs for a listing
    function getAllListingOrders(address listing, uint256 step, uint256 maxIterations) external view returns (OrderGroup memory orderGroup) {
        // Returns pending order IDs for a listing in reverse order (latest first) if globalized
        if (!_isListingGlobalized(listing)) {
            return OrderGroup(address(0), new uint256[](0));
        }
        uint256[] memory buyIds = ICCListingTemplate(listing).pendingBuyOrdersView();
        uint256[] memory sellIds = ICCListingTemplate(listing).pendingSellOrdersView();
        uint256 totalOrders = buyIds.length + sellIds.length;
        uint256[] memory combinedIds = new uint256[](totalOrders);
        uint256 index = 0;
        for (uint256 i = 0; i < buyIds.length; i++) {
            combinedIds[index] = buyIds[i];
            index++;
        }
        for (uint256 i = 0; i < sellIds.length; i++) {
            combinedIds[index] = sellIds[i];
            index++;
        }
        return OrderGroup(listing, combinedIds);
    }
}