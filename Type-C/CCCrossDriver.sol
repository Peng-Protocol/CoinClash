// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.5
// - 0.0.5 (02/01/2025): Added per pair payout integration, explicit pair token in addFees, ccDonate instead of raw transfer. 
// - 0.0.4 (Base Token Cross Model - Fixed Params)
// NOTICE: Requires via-IR to compile!

import "./imports/ReentrancyGuard.sol";
import "./imports/IERC20.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface ICCLiquidity {
    struct SettlementUpdate {
        address recipient;
        address token;
        address pairedToken; // Added
        uint256 amount;
    }
    function ssUpdate(SettlementUpdate[] calldata updates) external;
    function ccDonate(address token, address pairedToken, uint256 amount) external payable;
}

interface ICCFeeTemplate {
    function addFees(address tokenA, address tokenB, uint256 amount) external payable;
}

contract CCBaseCrossDriver is ReentrancyGuard {
    
    // --- Structs ---

    struct Position {
        uint256 id;
        address maker;
        address pair;
        uint256 entryPrice;
        uint256 initialMargin;    // Pending: Base Token | Active: Position Token
        uint256 leverageMultiplier;
        uint256 leverageAmount;   // Active: Position Token
        uint256 taxedMargin;      // Pending: Base Token | Active: Position Token
        uint256 excessMargin;     // Pending: Base Token | Active: 0 (Moved to Global)
        bool entryDirection; 
        uint256 status;           // 0: Closed, 1: Pending, 2: Active
        uint256 timestamp;   
        uint256 liquidationPrice; // Dynamic
        uint256 stopLoss;
        uint256 takeProfit;  
    }

    struct EntryParams {
        address pair;
        uint256 entryPrice;
        uint256 initialMargin;    // Amount to be leveraged (Base Token)
        uint256 excessMargin;     // Amount for safety cushion (Base Token)
        uint256 leverageMultiplier;
        bool entryDirection;
        address maker;
    }

    // --- State Variables ---

    address public liquidityTemplate;
    address public feeTemplate;
    address public uniswapV2Factory;
    
    address public baseToken; 

    uint256 public longIdCounter;
    uint256 public shortIdCounter;

    mapping(uint256 => Position) public longPositions;
    mapping(uint256 => Position) public shortPositions;
    
    mapping(address => uint256[]) private userLongIds;
    mapping(address => uint256[]) private userShortIds;

    // CROSS MARGIN: User -> Base Token Amount
    mapping(address => uint256) public userBaseMargin;

    // --- Events ---

    event PositionCreated(uint256 indexed id, address indexed maker, uint8 positionType, uint256 entryPrice);
    event PositionExecuted(uint256 indexed id, uint8 positionType, uint256 entryPrice, uint256 convertedMargin); 
    event PositionCancelled(uint256 indexed id, uint8 positionType, uint256 refundAmount);
    event PositionClosed(uint256 indexed id, uint8 positionType, uint256 payoutBase, int256 netGains);
    
    event BaseMarginAdded(address indexed maker, uint256 amount);
    event BaseMarginPulled(address indexed maker, uint256 amount);
    event AccountLiquidated(address indexed maker, uint256 totalBaseLoss);
    
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

    modifier onlyBaseSet() {
        require(baseToken != address(0), "Base token not set");
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

    function setBaseToken(address _baseToken) external onlyOwner {
        require(baseToken == address(0), "Base already set"); 
        baseToken = _baseToken;
    }

    // --- Core: Enter Positions ---

    function enterLong(EntryParams calldata params) external nonReentrant onlyFeeSet onlyBaseSet {
        // 1. Funding: Pulls (Initial + Excess)
        (uint256 taxedBase, uint256 excessBase) = _processEntryFunding(params);
        // 2. Storage
        _finalizeEntry(params, true, taxedBase, excessBase);
    }

    function enterShort(EntryParams calldata params) external nonReentrant onlyFeeSet onlyBaseSet {
        (uint256 taxedBase, uint256 excessBase) = _processEntryFunding(params);
        _finalizeEntry(params, false, taxedBase, excessBase);
    }

    function _processEntryFunding(EntryParams calldata params) private returns (uint256 taxedMargin, uint256 excessMargin) {
        require(params.initialMargin > 0, "Zero margin");
        require(params.leverageMultiplier >= 2 && params.leverageMultiplier <= 100, "Invalid leverage");

        // Calculate Fee
        uint256 feeRatio = ((params.leverageMultiplier - 1) * 1e18) / 100;
        uint256 feeAmount = (params.initialMargin * feeRatio) / 1e18;
        
        uint256 totalTransfer = params.initialMargin + params.excessMargin;
        _transferIn(baseToken, msg.sender, totalTransfer);
        
        if (feeAmount > 0) {
            IERC20(baseToken).approve(feeTemplate, feeAmount);
            
            // Determine paired token from params.pair for correct fee bucketing
            // Assumes baseToken is part of params.pair. If not, this might need fallback logic.
            address t0 = IUniswapV2Pair(params.pair).token0();
            address pairedToken = (t0 == baseToken) 
                ? IUniswapV2Pair(params.pair).token1() 
                : t0;

            ICCFeeTemplate(feeTemplate).addFees(baseToken, pairedToken, feeAmount);
        }

        taxedMargin = params.initialMargin - feeAmount;
        excessMargin = params.excessMargin;
    }

    function _finalizeEntry(EntryParams calldata params, bool isLong, uint256 taxedBase, uint256 excessBase) private {
        uint256 id = isLong ? ++longIdCounter : ++shortIdCounter;
        
        Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        pos.id = id;
        pos.maker = params.maker == address(0) ? msg.sender : params.maker;
        pos.pair = params.pair;
        
        // STORED IN BASE TOKEN (Pending State)
        pos.initialMargin = taxedBase; // We track net initial as margin
        pos.taxedMargin = taxedBase; 
        pos.excessMargin = excessBase; 
        
        pos.leverageMultiplier = params.leverageMultiplier;
        pos.entryDirection = params.entryDirection;
        pos.timestamp = block.timestamp;
        pos.entryPrice = params.entryPrice;
        pos.status = params.entryPrice == 0 ? 2 : 1; 

        if (isLong) userLongIds[pos.maker].push(id);
        else userShortIds[pos.maker].push(id);

        if (pos.status == 2) {
             _executePositionLogic(pos, isLong);
        } else {
             emit PositionCreated(id, pos.maker, isLong ? 0 : 1, params.entryPrice);
        }
    }

    // --- Execution Logic (Base -> Position Token Conversion) ---

    function executeEntry(uint256[] calldata ids, bool isLong) external nonReentrant {
        for (uint i = 0; i < ids.length; i++) {
            _tryExecuteEntry(ids[i], isLong);
        }
    }

    function _tryExecuteEntry(uint256 id, bool isLong) internal {
        Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        if (pos.status != 1) return;

        uint256 currentPrice = _getUniPrice(pos.pair);
        bool canExecute = pos.entryDirection 
            ? (currentPrice >= pos.entryPrice) 
            : (currentPrice <= pos.entryPrice);

        if (canExecute) {
            pos.status = 2;
            _executePositionLogic(pos, isLong);
        }
    }

    function _executePositionLogic(Position storage pos, bool isLong) internal {
        // 1. Identify Position Token
        address posToken = isLong 
            ? IUniswapV2Pair(pos.pair).token0() 
            : IUniswapV2Pair(pos.pair).token1();

        // 2. Convert Taxed Margin (Base -> PosToken)
        uint256 conversionRate = _getConversionRate(baseToken, posToken);
        uint256 baseValue = pos.taxedMargin;
        uint256 posTokenValue = (baseValue * conversionRate) / 1e18;

        // 3. Update Position State to Active (PosToken values)
        pos.initialMargin = posTokenValue;
        pos.taxedMargin = posTokenValue;
        pos.leverageAmount = posTokenValue * pos.leverageMultiplier;
        
        // 4. Handle Excess (Base -> Global Pool)
        // Excess was stored in Base, so we just add it to global
        if (pos.excessMargin > 0) {
            userBaseMargin[pos.maker] += pos.excessMargin;
            pos.excessMargin = 0; // Clear from position struct
        }

        if (pos.entryPrice == 0) pos.entryPrice = _getUniPrice(pos.pair);

        emit PositionExecuted(pos.id, isLong ? 0 : 1, pos.entryPrice, posTokenValue);
    }

    // --- Core: Cancel ---

    function cancelPosition(uint256 id, bool isLong) external nonReentrant {
        Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        require(pos.maker == msg.sender, "Not maker");
        
        if (pos.status == 1) {
            _cancelPending(pos, isLong);
        } else if (pos.status == 2) {
            _internalClose(pos, isLong); 
        }
    }

    function _cancelPending(Position storage pos, bool isLong) internal {
        pos.status = 0;
        // In Pending, both margins are still Base Token
        uint256 refund = pos.taxedMargin + pos.excessMargin; 
        
        if (refund > 0) {
            IERC20(baseToken).transfer(pos.maker, refund);
        }
        emit PositionCancelled(pos.id, isLong ? 0 : 1, refund);
    }

    // --- Core: Close (Return to Base Token) ---

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
        // 1. Calculate Payout in Position Token
        (uint256 payoutPosToken, int256 netGains) = _calculateCloseValues(pos, isLong);
        // 2. Convert Payout to Base Token
        address posToken = isLong 
            ? IUniswapV2Pair(pos.pair).token0() 
            : IUniswapV2Pair(pos.pair).token1();
        address pairedToken = isLong 
            ? IUniswapV2Pair(pos.pair).token1() 
            : IUniswapV2Pair(pos.pair).token0();
            
        uint256 payoutBase = 0;
        if (payoutPosToken > 0) {
            uint256 rate = _getConversionRate(posToken, baseToken);
            payoutBase = (payoutPosToken * rate) / 1e18;
        }

        // 3. Finalize
        pos.status = 0;
        // Send the locked PosToken margin to Liquidity Template via Donate
        if (pos.taxedMargin > 0) {
             IERC20(posToken).approve(liquidityTemplate, pos.taxedMargin);
             ICCLiquidity(liquidityTemplate).ccDonate(posToken, pairedToken, pos.taxedMargin);
        }

        // User receives Base Token via Settlement
        if (payoutBase > 0) {
            // Must specify pos.pair so settlement knows which bucket (Base/PosToken) to check?
            // Note: Base payout usually comes from the BaseToken bucket. 
            // We pass pos.pair assuming BaseToken is paired there.
            _executePayout(pos.maker, payoutBase, pos.pair);
        }
        
        emit PositionClosed(pos.id, isLong ? 0 : 1, payoutBase, netGains);
    }

    function _calculateCloseValues(Position storage pos, bool isLong) private view returns (uint256 payout, int256 netGains) {
        uint256 exitPrice = _getUniPrice(pos.pair);
        
        // Calculate Net Gains (in Position Token)
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
        
        // Add Taxed Margin (in Position Token)
        // Payout Calculation: 
        // Long (Margin=T0, Payout=T1) -> Margin * Price
        // Short (Margin=T1, Payout=T0) -> Margin / Price
        uint256 marginValue;
        if (isLong) {
            marginValue = (pos.taxedMargin * exitPrice) / 1e18;
        } else {
            marginValue = (pos.taxedMargin * 1e18) / exitPrice;
        }

        int256 prePayout = grossGains + int256(marginValue);

        if (prePayout > 0) {
            uint256 holdingHours = (block.timestamp - pos.timestamp) / 3600;
            uint256 feeFactor = holdingHours * 1e15; 
            if (feeFactor > 1e18) feeFactor = 1e18;
            payout = (uint256(prePayout) * (1e18 - feeFactor)) / 1e18;
        } else {
            payout = 0;
        }
    }

    function _executePayout(address maker, uint256 amountBase, address pair) private {
        ICCLiquidity.SettlementUpdate[] memory updates = new ICCLiquidity.SettlementUpdate[](1);
        updates[0].recipient = maker;
        updates[0].token = baseToken; 
        
        // Determine paired token for the payout bucket
        address t0 = IUniswapV2Pair(pair).token0();
        address pairedToken = (t0 == baseToken) ? IUniswapV2Pair(pair).token1() : t0;
        updates[0].pairedToken = pairedToken;

        updates[0].amount = amountBase;
        
        ICCLiquidity(liquidityTemplate).ssUpdate(updates);
    }

    // --- Liquidation Logic (Cross Currency) ---

    function executeExit(uint256[] calldata ids, bool isLong) external nonReentrant onlyLiquiditySet {
        for (uint i = 0; i < ids.length; i++) {
            _tryExecuteExit(ids[i], isLong);
        }
    }

    function _tryExecuteExit(uint256 id, bool isLong) internal {
        Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        if (pos.status != 2) return;

        // 1. Check Solvency
        // Convert Global Base Margin -> Position Token
        address posToken = isLong 
            ? IUniswapV2Pair(pos.pair).token0() 
            : IUniswapV2Pair(pos.pair).token1();

        uint256 rate = _getConversionRate(baseToken, posToken);
        uint256 globalMarginInPosToken = (userBaseMargin[pos.maker] * rate) / 1e18;

        uint256 liqPrice = _calcLiqPrice(pos, globalMarginInPosToken, isLong);
        uint256 currentPrice = _getUniPrice(pos.pair);

        bool liquidated = isLong ? (currentPrice <= liqPrice) : (currentPrice >= liqPrice);

        if (liquidated) {
            _liquidateAccount(pos.maker);
            return;
        }

        // 2. SL/TP Checks
        if (pos.stopLoss > 0) {
            if (isLong ? currentPrice <= pos.stopLoss : currentPrice >= pos.stopLoss) {
                _internalClose(pos, isLong);
                return;
            }
        }
        if (pos.takeProfit > 0) {
             if (isLong ? currentPrice >= pos.takeProfit : currentPrice <= pos.takeProfit) {
                _internalClose(pos, isLong);
            }
        }
    }

    function _calcLiqPrice(Position storage pos, uint256 globalMarginPosToken, bool isLong) private view returns (uint256) {
        uint256 totalAvailable = globalMarginPosToken + pos.taxedMargin;
        if (pos.leverageAmount == 0) return isLong ? 0 : type(uint256).max;
        
        uint256 marginRatio = (totalAvailable * 1e18) / pos.leverageAmount;
        uint256 priceDelta = (pos.entryPrice * marginRatio) / 1e18;

        return isLong 
            ? (priceDelta >= pos.entryPrice ? 0 : pos.entryPrice - priceDelta)
            : pos.entryPrice + priceDelta;
    }

    function _liquidateAccount(address maker) internal {
        // Track a pair to attribute the global base margin donation to
        address donationPairToken = address(0);

        // 1. Close All Longs
        uint256[] storage lIds = userLongIds[maker];
        for(uint i=0; i<lIds.length; i++) {
            Position storage p = longPositions[lIds[i]];
            if (p.status == 2) {
                p.status = 0;
                address pToken = IUniswapV2Pair(p.pair).token0();
                address paired = IUniswapV2Pair(p.pair).token1();
                
                // Capture a paired token for base donation if needed
                if (donationPairToken == address(0)) {
                    donationPairToken = (IUniswapV2Pair(p.pair).token0() == baseToken) ? paired : pToken;
                }

                if (p.taxedMargin > 0) {
                    IERC20(pToken).approve(liquidityTemplate, p.taxedMargin);
                    ICCLiquidity(liquidityTemplate).ccDonate(pToken, paired, p.taxedMargin);
                }
                emit PositionClosed(p.id, 0, 0, -int256(int(p.initialMargin)));
            }
        }

        // 2. Close All Shorts (Similar logic)
        uint256[] storage sIds = userShortIds[maker];
        for(uint i=0; i<sIds.length; i++) {
            Position storage p = shortPositions[sIds[i]];
            if (p.status == 2) {
                p.status = 0;
                address pToken = IUniswapV2Pair(p.pair).token1();
                address paired = IUniswapV2Pair(p.pair).token0();

                if (donationPairToken == address(0)) {
                    donationPairToken = (IUniswapV2Pair(p.pair).token0() == baseToken) ? paired : pToken;
                }

                if (p.taxedMargin > 0) {
                    IERC20(pToken).approve(liquidityTemplate, p.taxedMargin);
                    ICCLiquidity(liquidityTemplate).ccDonate(pToken, paired, p.taxedMargin);
                }
                emit PositionClosed(p.id, 1, 0, -int256(int(p.initialMargin)));
            }
        }

        // 3. Wipe Global Base Margin
        uint256 wipedBase = userBaseMargin[maker];
        if (wipedBase > 0) {
            userBaseMargin[maker] = 0;
            IERC20(baseToken).approve(liquidityTemplate, wipedBase);
            
            // If we found a pair from positions, use it. Otherwise, assume baseToken is isolated 
            // or we cannot donate correctly. Fallback: pairedToken = address(0) (if allowed) or burn.
            // Using address(0) as paired token for now if no positions existed (rare edge case).
            ICCLiquidity(liquidityTemplate).ccDonate(baseToken, donationPairToken, wipedBase);
        }

        emit AccountLiquidated(maker, wipedBase);
    }

    // --- Base Margin Management ---

    function addExcessMargin(uint256 amount) external nonReentrant onlyBaseSet {
        uint256 received = _transferIn(baseToken, msg.sender, amount);
        userBaseMargin[msg.sender] += received;
        emit BaseMarginAdded(msg.sender, received);
    }

    function pullMargin(uint256 amount) external nonReentrant {
        require(userBaseMargin[msg.sender] >= amount, "Insufficient margin");
        userBaseMargin[msg.sender] -= amount;
        IERC20(baseToken).transfer(msg.sender, amount);
        emit BaseMarginPulled(msg.sender, amount);
    }

    // --- Utils ---

    function _getConversionRate(address from, address to) internal view returns (uint256) {
        if (from == to) return 1e18;
        address pair = IUniswapV2Factory(uniswapV2Factory).getPair(from, to);
        require(pair != address(0), "No direct pair for conversion");
        (uint112 r0, uint112 r1, ) = IUniswapV2Pair(pair).getReserves();
        require(r0 > 0 && r1 > 0, "Empty reserves");
        address t0 = IUniswapV2Pair(pair).token0();
        if (t0 == from) return (uint256(r1) * 1e18) / uint256(r0);
        else return (uint256(r0) * 1e18) / uint256(r1);
    }

    function _getUniPrice(address pair) internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(pair).getReserves();
        require(reserve0 > 0 && reserve1 > 0, "Empty reserves");
        return (uint256(reserve1) * 1e18) / uint256(reserve0);
    }

    function _transferIn(address token, address from, uint256 amount) internal returns (uint256) {
        uint256 pre = IERC20(token).balanceOf(address(this));
        IERC20(token).transferFrom(from, address(this), amount);
        uint256 post = IERC20(token).balanceOf(address(this));
        return post - pre;
    }

    // Helpers for SL/TP...
    function updateSL(uint256 id, bool isLong, uint256 slPrice) external nonReentrant {
        Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        require(pos.maker == msg.sender, "Not maker");
        require(pos.status != 0, "Invalid position");
        pos.stopLoss = slPrice;
        emit SLUpdated(id, isLong ? 0 : 1, slPrice);
    }
    
    function updateTP(uint256 id, bool isLong, uint256 tpPrice) external nonReentrant {
         Position storage pos = isLong ? longPositions[id] : shortPositions[id];
        require(pos.maker == msg.sender, "Not maker");
        require(pos.status != 0, "Invalid position");
        pos.takeProfit = tpPrice;
        emit TPUpdated(id, isLong ? 0 : 1, tpPrice);
    }
}