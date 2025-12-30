// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.2
// - 0.0.2 (30/12/2025): Refactored to address stack issues. 

// NOTICE: Requires via-IR to compile, will not compile otherwise!

import "./imports/ReentrancyGuard.sol"; //Imports and inherita Ownable
import "./imports/IERC20.sol";

// --- Interfaces ---

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface ICCLiquidity {
    struct SettlementUpdate {
        address recipient;
        address token;
        uint256 amount;
    }
    // Replaces createPayout with router-privileged update
    function ssUpdate(SettlementUpdate[] calldata updates) external;
}

interface ICCFeeTemplate {
    function addFees(address tokenA, address tokenB, uint256 amount) external payable;
}

contract CCIsolatedDriver is ReentrancyGuard {
    
    // --- Structs ---

    struct Position {
        uint256 id;
        address maker;
        address pair;
        uint256 entryPrice;
        uint256 initialMargin;
        uint256 leverageMultiplier;
        uint256 leverageAmount;
        uint256 taxedMargin;
        uint256 excessMargin;
        bool entryDirection; 
        uint256 status;      // 0: Cancelled/Closed, 1: Pending, 2: Active
        uint256 timestamp;   
        uint256 liquidationPrice;
        uint256 stopLoss;    
        uint256 takeProfit;  
    }

    // Stack Mitigation: Grouping parameters
    struct EntryParams {
        address pair;
        uint256 entryPrice;
        uint256 initialMargin;
        uint256 leverageMultiplier;
        bool entryDirection;
        address maker;
    }

    // Stack Mitigation: Grouping local variables for Entry
    struct EntryContext {
        address token;
        address actualMaker;
        uint256 amountReceived;
        uint256 feeRatio;
        uint256 feeAmount;
        uint256 taxedMargin;
        uint256 leverageAmount;
    }

    // Stack Mitigation: Grouping local variables for Closing
    struct CloseContext {
        uint256 exitPrice;
        int256 netGains;
        int256 grossGains;
        uint256 marginValue;
        int256 prePayout;
        uint256 holdingTime;
        uint256 holdingFeeFactor;
        uint256 payout;
    }

    // --- State Variables ---

    address public liquidityTemplate;
    address public feeTemplate;
    address public uniswapV2Factory;

    uint256 public longIdCounter;
    uint256 public shortIdCounter;

    mapping(uint256 => Position) public longPositions;
    mapping(uint256 => Position) public shortPositions;

    mapping(address => uint256[]) private userLongIds;
    mapping(address => uint256[]) private userShortIds;

    // --- Events ---

    event PositionCreated(uint256 indexed id, address indexed maker, uint8 positionType, uint256 entryPrice);
    event PositionExecuted(uint256 indexed id, uint8 positionType, uint256 entryPrice, uint256 liquidationPrice);
    event PositionCancelled(uint256 indexed id, uint8 positionType, uint256 refundAmount, uint256 feeAmount);
    event PositionClosed(uint256 indexed id, uint8 positionType, uint256 payout, int256 netGains);
    event ExcessMarginAdded(uint256 indexed id, uint8 positionType, uint256 amount);
    event SLUpdated(uint256 indexed id, uint8 positionType, uint256 newSL);
    event TPUpdated(uint256 indexed id, uint8 positionType, uint256 newTP);

    // --- Modifiers ---

    modifier onlyLiquiditySet() {
        require(liquidityTemplate != address(0), "Liquidity template not set");
        _;
    }

    modifier onlyFeeSet() {
        require(feeTemplate != address(0), "Fee template not set");
        _;
    }

    // --- Admin Functions ---

    function setLiquidityTemplate(address _liquidityTemplate) external onlyOwner {
        liquidityTemplate = _liquidityTemplate;
    }

    function setFeeTemplate(address _feeTemplate) external onlyOwner {
        feeTemplate = _feeTemplate;
    }

    function setUniv2Factory(address _factory) external onlyOwner {
        uniswapV2Factory = _factory;
    }

// --- Core: Enter Positions (Twice Refactored for Stack Depth) ---

    function enterLong(EntryParams calldata params) external nonReentrant onlyFeeSet {
        // Phase 1: Funding (Stack clears after this call)
        (uint256 taxedMargin, uint256 leverageAmount) = _processEntryFunding(params, true);
        // Phase 2: Storage & Execution
        _finalizeEntry(params, true, taxedMargin, leverageAmount);
    }

    function enterShort(EntryParams calldata params) external nonReentrant onlyFeeSet {
        (uint256 taxedMargin, uint256 leverageAmount) = _processEntryFunding(params, false);
        _finalizeEntry(params, false, taxedMargin, leverageAmount);
    }

    // Phase 1: Handles transfers and fee calculations. Returns only what's needed for storage.
    
    function _processEntryFunding(EntryParams calldata params, bool isLong) private returns (uint256 taxedMargin, uint256 leverageAmount) {
    require(params.initialMargin > 0, "Zero margin");
    require(params.leverageMultiplier >= 2 && params.leverageMultiplier <= 100, "Invalid leverage");

    address token = isLong ? IUniswapV2Pair(params.pair).token0() : IUniswapV2Pair(params.pair).token1();
    uint256 received = _transferIn(token, msg.sender, params.initialMargin);
    
    // CORRECTED: Restore original precision
    uint256 feeRatio = ((params.leverageMultiplier - 1) * 1e18) / 100;
    uint256 feeAmount = (received * feeRatio) / 1e18;
    
    if (feeAmount > 0) {
        IERC20(token).approve(feeTemplate, feeAmount);
        if (isLong) ICCFeeTemplate(feeTemplate).addFees(token, address(0), feeAmount);
        else ICCFeeTemplate(feeTemplate).addFees(address(0), token, feeAmount);
    }

    return (received - feeAmount, received * params.leverageMultiplier);
}

    // Phase 2: Handles ID generation, storage, and execution logic.
    function _finalizeEntry(EntryParams calldata params, bool isLong, uint256 taxedMargin, uint256 leverageAmount) private {
    uint256 id = _generatePositionId(isLong);
    _storePositionData(id, params, isLong, taxedMargin, leverageAmount);
    _handlePositionExecution(id, params, isLong);
}

function _generatePositionId(bool isLong) private returns (uint256) {
    if (isLong) {
        longIdCounter++;
        return longIdCounter;
    } else {
        shortIdCounter++;
        return shortIdCounter;
    }
}

function _storePositionData(
    uint256 id,
    EntryParams calldata params,
    bool isLong,
    uint256 taxedMargin,
    uint256 leverageAmount
) private {
    Position storage pos = isLong ? longPositions[id] : shortPositions[id];
    pos.id = id;
    pos.maker = params.maker == address(0) ? msg.sender : params.maker;
    pos.pair = params.pair;
    pos.initialMargin = leverageAmount / params.leverageMultiplier;
    pos.leverageMultiplier = params.leverageMultiplier;
    pos.leverageAmount = leverageAmount;
    pos.taxedMargin = taxedMargin;
    pos.entryDirection = params.entryDirection;
    pos.timestamp = block.timestamp;
    pos.excessMargin = 0;
    pos.entryPrice = params.entryPrice;
    pos.status = params.entryPrice == 0 ? 2 : 1; // Active if market, Pending if limit
}

function _handlePositionExecution(uint256 id, EntryParams calldata params, bool isLong) private {
    Position storage pos = isLong ? longPositions[id] : shortPositions[id];
    
    if (params.entryPrice == 0) {
        pos.entryPrice = _getUniPrice(params.pair);
        _setLiquidationPrice(pos, isLong ? 0 : 1);
        emit PositionExecuted(id, isLong ? 0 : 1, pos.entryPrice, pos.liquidationPrice);
    }
    
    emit PositionCreated(id, pos.maker, isLong ? 0 : 1, pos.entryPrice);
    
    if (isLong) userLongIds[pos.maker].push(id);
    else userShortIds[pos.maker].push(id);
}

    function enterPositionWithSLTP(
    bool isLong,
    EntryParams calldata params,
    uint256 slPrice,
    uint256 tpPrice
) external {
    // Execute entry first
    if (isLong) {
        this.enterLong(params);
        uint256 id = longIdCounter;
        if (slPrice > 0) this.updateSL(id, true, slPrice);
        if (tpPrice > 0) this.updateTP(id, true, tpPrice);
    } else {
        this.enterShort(params);
        uint256 id = shortIdCounter;
        if (slPrice > 0) this.updateSL(id, false, slPrice);
        if (tpPrice > 0) this.updateTP(id, false, tpPrice);
    }
}

    
    // --- Core: Cancel ---

    function cancelPosition(uint256 id, bool isLong) external nonReentrant {
        Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        require(pos.maker == msg.sender, "Not maker");
        _internalCancel(pos, isLong);
    }

    function _internalCancel(Position storage pos, bool isLong) internal {
    require(pos.status != 0, "Already closed/cancelled");
    pos.status = 0;

    address token = isLong ? IUniswapV2Pair(pos.pair).token0() : IUniswapV2Pair(pos.pair).token1();
    (uint256 refund, uint256 fee) = _getRefundValues(pos);

    if (fee > 0) {
        IERC20(token).approve(feeTemplate, fee);
        if (isLong) ICCFeeTemplate(feeTemplate).addFees(token, address(0), fee);
        else ICCFeeTemplate(feeTemplate).addFees(address(0), token, fee);
    }
    
    if (refund > 0) {
        IERC20(token).transfer(pos.maker, refund);
    }

    emit PositionCancelled(pos.id, isLong ? 0 : 1, refund, fee);
}

    function _getRefundValues(Position storage pos) private view returns (uint256 refund, uint256 fee) {
        uint256 totalMargin = pos.taxedMargin + pos.excessMargin;
        uint256 holdingTime = (block.timestamp - pos.timestamp) / 3600;
        uint256 factor = (1e15 * holdingTime); // 0.1% = 0.001 = 1e15
        if (factor > 1e18) factor = 1e18;
        
        fee = (totalMargin * factor) / 1e18;
        refund = totalMargin - fee;
    }

    // --- Core: Close (Twice Refactored for Stack Depth) ---

    function closeLongPosition(uint256 id) external nonReentrant onlyLiquiditySet {
        Position storage pos = longPositions[id];
        require(pos.maker == msg.sender, "Not maker");
        _internalClose(pos, true);
    }

    function closeShortPosition(uint256 id) external nonReentrant onlyLiquiditySet {
        Position storage pos = shortPositions[id];
        require(pos.maker == msg.sender, "Not maker");
        _internalClose(pos, false);
    }

    function _internalClose(Position storage pos, bool isLong) internal {
        require(pos.status == 2, "Not active");
        
        // 1. Calculate Payouts in separate stack frame
        (uint256 payout, int256 netGains) = _calculateCloseValues(pos, isLong);
        
        // 2. Finalize & Emit
        _finalizeClose(pos, payout, isLong ? 0 : 1);
        emit PositionClosed(pos.id, isLong ? 0 : 1, payout, netGains);
    }

    function _calculateCloseValues(Position storage pos, bool isLong) private view returns (uint256 payout, int256 netGains) {
    uint256 exitPrice = _getUniPrice(pos.pair);
    
    // Net gains calculation is correct
    if (isLong) {
        netGains = exitPrice > pos.entryPrice 
            ? int256((exitPrice - pos.entryPrice) * pos.leverageAmount / 1e18)
            : -int256((pos.entryPrice - exitPrice) * pos.leverageAmount / 1e18);
    } else {
        netGains = pos.entryPrice > exitPrice 
            ? int256((pos.entryPrice - exitPrice) * pos.leverageAmount / 1e18)
            : -int256((exitPrice - pos.entryPrice) * pos.leverageAmount / 1e18);
    }

    int256 grossGains = netGains / int256(pos.leverageMultiplier);
    uint256 totalMargin = pos.taxedMargin + pos.excessMargin;
    
    // CORRECTED: Apply margin conversion per spec
    // Long: margin in T0, multiply by price to get T1 value
    // Short: margin in T1, divide by price to get T0 value
    uint256 marginValue = isLong 
        ? (totalMargin * exitPrice) / 1e18
        : (totalMargin * 1e18) / exitPrice;

    int256 prePayout = grossGains + int256(marginValue);

    // Holding fee
    if (prePayout > 0) {
        uint256 holdingHours = (block.timestamp - pos.timestamp) / 3600;
        uint256 feeFactor = holdingHours * 1e15; // 0.1% per hour
        if (feeFactor > 1e18) feeFactor = 1e18;
        
        payout = (uint256(prePayout) * (1e18 - feeFactor)) / 1e18;
    } else {
        payout = 0;
    }
}

    function _finalizeClose(Position storage pos, uint256 payout, uint256 pType) internal {
    pos.status = 0;

    address pair = pos.pair;
    address marginToken = pType == 0 ? IUniswapV2Pair(pair).token0() : IUniswapV2Pair(pair).token1();
    
    uint256 totalToLiq = pos.taxedMargin + pos.excessMargin;
    if (totalToLiq > 0) {
        IERC20(marginToken).transfer(liquidityTemplate, totalToLiq);
    }

    if (payout > 0) {
        _executePayout(pos.maker, pair, payout, pType);
    }
}

function _executePayout(address maker, address pair, uint256 amount, uint256 pType) private {
    address payoutToken = pType == 0 ? IUniswapV2Pair(pair).token1() : IUniswapV2Pair(pair).token0();
    
    ICCLiquidity.SettlementUpdate[] memory updates = new ICCLiquidity.SettlementUpdate[](1);
    updates[0].recipient = maker;
    updates[0].token = payoutToken;
    updates[0].amount = amount;
    
    ICCLiquidity(liquidityTemplate).ssUpdate(updates);
}

    // --- Batch Functions ---

    function closeMultiLongs(uint256[] calldata ids) external {
        for(uint i=0; i<ids.length; i++) this.closeLongPosition(ids[i]);
    }

    function closeMultiShort(uint256[] calldata ids) external {
        for(uint i=0; i<ids.length; i++) this.closeShortPosition(ids[i]);
    }

    function cancelMultiPendingLong(uint256[] calldata ids) external {
        for(uint i=0; i<ids.length; i++) {
            if (longPositions[ids[i]].status == 1) this.cancelPosition(ids[i], true);
        }
    }

    function cancelMultiActiveLong(uint256[] calldata ids) external {
        for(uint i=0; i<ids.length; i++) {
            if (longPositions[ids[i]].status == 2) this.cancelPosition(ids[i], true);
        }
    }

    function cancelMultiPendingShort(uint256[] calldata ids) external {
        for(uint i=0; i<ids.length; i++) {
            if (shortPositions[ids[i]].status == 1) this.cancelPosition(ids[i], false);
        }
    }

    function cancelMultiActiveShort(uint256[] calldata ids) external {
        for(uint i=0; i<ids.length; i++) {
            if (shortPositions[ids[i]].status == 2) this.cancelPosition(ids[i], false);
        }
    }

    // --- Margin & SL/TP Management ---

    function addExcessMargin(uint256 id, bool isLong, uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        require(pos.status != 0, "Invalid position");

        address token = isLong ? IUniswapV2Pair(pos.pair).token0() : IUniswapV2Pair(pos.pair).token1();
        uint256 received = _transferIn(token, msg.sender, amount);

        pos.excessMargin += received;
        
        if (pos.status == 2) {
            _setLiquidationPrice(pos, isLong ? 0 : 1);
        }
        
        emit ExcessMarginAdded(id, isLong ? 0 : 1, received);
    }

    function updateSL(uint256 id, bool isLong, uint256 slPrice) external nonReentrant {
        Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        require(pos.maker == msg.sender, "Not maker");
        require(pos.status != 0, "Invalid position");
        _updateSL(pos, slPrice, isLong ? 0 : 1);
    }

    function updateTP(uint256 id, bool isLong, uint256 tpPrice) external nonReentrant {
        Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        require(pos.maker == msg.sender, "Not maker");
        require(pos.status != 0, "Invalid position");
        _updateTP(pos, tpPrice, isLong ? 0 : 1);
    }

    function _updateSL(Position storage pos, uint256 slPrice, uint256 pType) internal {
        if (pType == 0 && slPrice > 0) require(pos.entryPrice > slPrice, "Long SL must be below entry");
        if (pType == 1 && slPrice > 0) require(slPrice > pos.entryPrice, "Short SL must be above entry");
        pos.stopLoss = slPrice;
        emit SLUpdated(pos.id, uint8(pType), slPrice);
    }

    function _updateTP(Position storage pos, uint256 tpPrice, uint256 pType) internal {
        if (pType == 0 && tpPrice > 0) require(tpPrice > pos.entryPrice, "Long TP must be above entry");
        if (pType == 1 && tpPrice > 0) require(pos.entryPrice > tpPrice, "Short TP must be below entry");
        pos.takeProfit = tpPrice;
        emit TPUpdated(pos.id, uint8(pType), tpPrice);
    }

    // --- Automation ---

    function executeEntry(uint256[] calldata ids, bool isLong) external nonReentrant {
        for (uint i = 0; i < ids.length; i++) {
            _tryExecuteEntry(ids[i], isLong);
        }
    }

    // Extracted logic for stack safety
    function _tryExecuteEntry(uint256 id, bool isLong) internal {
        Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        if (pos.status != 1) return;

        uint256 currentPrice = _getUniPrice(pos.pair);
        bool canExecute = pos.entryDirection 
            ? (currentPrice >= pos.entryPrice) 
            : (currentPrice <= pos.entryPrice);
        
        if (canExecute) {
            pos.status = 2; // Active
            // Keeping entryPrice as stated in original logic, but updating liq based on it.
            _setLiquidationPrice(pos, isLong ? 0 : 1);
            emit PositionExecuted(pos.id, isLong ? 0 : 1, pos.entryPrice, pos.liquidationPrice);
        }
    }

    function executeExit(uint256[] calldata ids, bool isLong) external nonReentrant onlyLiquiditySet {
        for (uint i = 0; i < ids.length; i++) {
            _tryExecuteExit(ids[i], isLong);
        }
    }

    function _tryExecuteExit(uint256 id, bool isLong) internal {
        Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        if (pos.status != 2) return;

        uint256 currentPrice = _getUniPrice(pos.pair);

        // 1. Liquidation Check
        bool liquidated = false;
        if (isLong) {
            if (currentPrice <= pos.liquidationPrice) liquidated = true;
        } else {
            if (currentPrice >= pos.liquidationPrice) liquidated = true;
        }

        if (liquidated) {
            _finalizeClose(pos, 0, isLong ? 0 : 1); // Full loss
            emit PositionClosed(pos.id, isLong ? 0 : 1, 0, -int256(pos.initialMargin));
            return;
        }

        // 2. SL Check
        if (pos.stopLoss > 0) {
            bool slHit = isLong ? (currentPrice <= pos.stopLoss) : (currentPrice >= pos.stopLoss);
            if (slHit) {
                _internalCancel(pos, isLong);
                return;
            }
        }

        // 3. TP Check
        if (pos.takeProfit > 0) {
            bool tpHit = isLong ? (currentPrice >= pos.takeProfit) : (currentPrice <= pos.takeProfit);
            if (tpHit) {
                _internalClose(pos, isLong);
            }
        }
    }

    // --- Helpers ---

    function _setLiquidationPrice(Position storage pos, uint256 pType) internal {
    if (pos.leverageAmount == 0) return;
    
    // CORRECTED: margin ratio = totalMargin / leverageAmount (no price multiplication!)
    uint256 marginRatio = ((pos.excessMargin + pos.taxedMargin) * 1e18) / pos.leverageAmount;
    uint256 priceDelta = (pos.entryPrice * marginRatio) / 1e18;

    pos.liquidationPrice = (pType == 0) // Long
        ? (priceDelta > pos.entryPrice ? 0 : pos.entryPrice - priceDelta)
        : pos.entryPrice + priceDelta; // Short
}

    function _transferIn(address token, address from, uint256 amount) internal returns (uint256) {
        uint256 pre = IERC20(token).balanceOf(address(this));
        IERC20(token).transferFrom(from, address(this), amount);
        uint256 post = IERC20(token).balanceOf(address(this));
        return post - pre;
    }

    function _getUniPrice(address pair) internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        require(reserve0 > 0 && reserve1 > 0, "Empty reserves");
        return (uint256(reserve1) * 1e18) / uint256(reserve0);
    }

    // --- Views ---

    function positionsByTypeView(bool isLong, uint256 step, uint256 maxIteration) external view returns (uint256[] memory) {
        uint256 count = 0;
        uint256 total = isLong ? longIdCounter : shortIdCounter;
        uint256[] memory result = new uint256[](maxIteration);
        
        for (uint i = step; i <= total && count < maxIteration; i++) {
            if (i == 0) continue;
            result[count] = i;
            count++;
        }
        return result;
    }

    function positionsByAddressView(address user, bool isLong, uint256 step, uint256 maxIteration) external view returns (uint256[] memory) {
        uint256[] storage ids = isLong ? userLongIds[user] : userShortIds[user];
        uint256[] memory result = new uint256[](maxIteration);
        uint256 count = 0;
        
        for (uint i = step; i < ids.length && count < maxIteration; i++) {
            result[count] = ids[i];
            count++;
        }
        return result;
    }

    function positionByIndex(uint256 id, bool isLong) external view returns (Position memory) {
        return isLong ? longPositions[id] : shortPositions[id];
    }
}