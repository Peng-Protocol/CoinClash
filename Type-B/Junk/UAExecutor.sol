// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.20;

/**
 * @title UAExecutor - Limit Order System for Automated Debt Looping
 * @notice Manages limit orders for position creation (winds) and unwinding with TP/SL
 * @dev Integrates with UADriver for position execution
 */
// File Version: 0.0.3 (14/12/2025) (15/12/2025)
// - 0.0.3 (14/12) (15/12) Merged wind and position structs, used mappings for associating winds and unwinds, refactored TP/SL to use fewer functions. Refactored position creation and cancellation to use new structs and mappings.
// - 0.0.2 (10/12): Monolithic refactor - support multiple pairs dynamically

import "./imports/ReentrancyGuard.sol"; // imports and inherits ownable
import "./imports/IERC20.sol";

interface IUADriver {
    function executeLoop(
        address collateralAsset,
        address borrowAsset,
        address onBehalfOf,
        uint256 initialMargin,
        uint256 targetLeverage,
        uint256 minHealthFactor,
        uint256 maxSlippage
    ) external;
    
    function unwindLoop(
        address collateralAsset,
        address borrowAsset,
        uint256 repayAmount,
        uint256 withdrawAmount,
        uint256 maxSlippage
    ) external;
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPool {
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}

contract UAExecutor is ReentrancyGuard {
    
    // ENUMS
    enum Status { PENDING, ACTIVE, CLOSED, CANCELLED }

    // STRUCTS
    struct Position {
        uint256 id;
        address maker;
        address collateralAsset;
        address borrowAsset;
        uint256 collateralAmount;
        uint256 debtAmount;        // 0 when PENDING
        uint256 targetLeverage;
        uint256 minHealthFactor;
        uint256 maxSlippage;
        uint256 entryPrice;        // Trigger price for PENDING, Execution price for ACTIVE
        bool entryDirection;       // true: >=, false: <=
        Status status;
        uint256 createdAt;
        uint256 executedAt;
    }

    struct UnwindOrder {
        uint256 id;
        uint256 positionId;
        uint256 targetPrice;
        bool priceDirection;       // true: >=, false: <=
        bool isTP;                 // true: TP, false: SL
        bool executed;
        bool cancelled;
    }
    
    // STATE VARIABLES
    
    IUADriver public uaDriver;
    IUniswapV2Factory public uniswapFactory;
    IPool public aavePool;
    
    // REMOVED: collateralAsset, borrowAsset, pairAddress for dynamism
    
// Mappings
    mapping(uint256 => Position) public positions;
    mapping(uint256 => UnwindOrder) public unwindOrders;
    
    // Simplified TP/SL Mappings (Position ID => Unwind Order ID)
    mapping(uint256 => uint256) public positionToTP;
    mapping(uint256 => uint256) public positionToSL;
    
    // Reverse mapping for internal checks
    mapping(uint256 => uint256) public unwindToPosition;
    
    // Order tracking 
    uint256 public nextUnwindOrderId = 1;
    uint256 public nextPositionId = 1;
    
    // User tracking
    mapping(address => uint256[]) public userPositions;
    
    // Constants
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS_PRECISION = 1e4;
    
    // Configuration
    bool public paused;
    
    // EVENTS
    
    event WindOrderCreated(
        uint256 indexed orderId,
        address indexed maker,
        address collateralAsset,
        address borrowAsset,
        uint256 collateralAmount,
        uint256 entryPrice,
        bool entryDirection
    );
    
    event WindOrderExecuted(
        uint256 indexed orderId,
        uint256 indexed positionId,
        uint256 executionPrice
    );
    
    event WindOrderCancelled(uint256 indexed orderId);
    
    event UnwindOrderCreated(
        uint256 indexed orderId,
        uint256 indexed positionId,
        uint256 targetPrice,
        bool isTP
    );
    
    event UnwindOrderExecuted(
        uint256 indexed orderId,
        uint256 indexed positionId,
        uint256 executionPrice,
        uint256 pnl
    );
    
    event UnwindOrderCancelled(uint256 indexed orderId);
    
    event PositionClosed(
        uint256 indexed positionId,
        address indexed maker,
        uint256 pnl
    );
    
    event PauseToggled(bool paused);
    
    // ERRORS
    
    error ContractPaused();
    error InvalidAmount();
    error InvalidPrice();
    error InvalidLeverage();
    error OrderNotFound();
    error OrderAlreadyExecuted();
    error OrderAlreadyCancelled();
    error Unauthorized();
    error PositionNotActive();
    error TPSLAlreadySet();
    error InvalidTPSLPrice();
    error PairNotFound();
    error SameAsset();
    
    // CONSTRUCTOR (Simplified - removed pair-specific params)
    
    // CONSTRUCTOR (Retained only for Ownable initialization)
    constructor() Ownable() {
        // Dependencies are now set via owner-only setters after deployment
    }
    
    // SETTER FUNCTIONS
    
    /**
     * @notice Sets the address of the UADriver contract
     */
    function setUADriver(address _uaDriver) external onlyOwner {
        require(_uaDriver != address(0), "Invalid driver");
        uaDriver = IUADriver(_uaDriver);
    }
    
    /**
     * @notice Sets the address of the Uniswap V2 Factory
     */
    function setUniswapFactory(address _uniswapFactory) external onlyOwner {
        require(_uniswapFactory != address(0), "Invalid factory");
        uniswapFactory = IUniswapV2Factory(_uniswapFactory);
    }
    
    /**
     * @notice Sets the address of the Aave Pool contract
     */
    function setAavePool(address _aavePool) external onlyOwner {
        require(_aavePool != address(0), "Invalid pool");
        aavePool = IPool(_aavePool);
    }
    
    // PRICE FUNCTIONS
    
    /**
     * @notice Get current price from Uniswap V2 pair for any asset pair
     * @return price Current price (borrowAsset per collateralAsset, scaled 1e18)
     */
    function getCurrentPrice(address collateralAsset, address borrowAsset) public view returns (uint256 price) {
        address pairAddress = uniswapFactory.getPair(collateralAsset, borrowAsset);
        if (pairAddress == address(0)) revert PairNotFound();
        
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        
        address token0 = pair.token0();
        
        // Determine which reserve is which
        if (token0 == collateralAsset) {
            // Price = borrowAsset / collateralAsset = reserve1 / reserve0
            price = (uint256(reserve1) * PRECISION) / uint256(reserve0);
        } else {
            // Price = borrowAsset / collateralAsset = reserve0 / reserve1
            price = (uint256(reserve0) * PRECISION) / uint256(reserve1);
        }
    }
    
    /**
     * @notice Check if price condition is met
     */
    function _checkPriceCondition(
        uint256 currentPrice,
        uint256 targetPrice,
        bool direction
    ) internal pure returns (bool) {
        if (direction) {
            return currentPrice >= targetPrice;
        } else {
            return currentPrice <= targetPrice;
        }
    }
    
    // WIND ORDER FUNCTIONS
    
   /**
     * @notice (0.0.3) Create a new Position (starts as PENDING wind order)
     */
    function createOrder(
        address collateralAsset,
        address borrowAsset,
        uint256 collateralAmount,
        uint256 targetLeverage,
        uint256 minHealthFactor,
        uint256 maxSlippage,
        uint256 entryPrice,
        bool entryDirection
    ) external nonReentrant returns (uint256 id) {
        if (paused) revert ContractPaused();
        if (collateralAsset == borrowAsset) revert SameAsset();
        if (collateralAmount == 0) revert InvalidAmount();
        
        IERC20(collateralAsset).transferFrom(msg.sender, address(this), collateralAmount);
        _approveIfNeeded(collateralAsset, address(uaDriver), collateralAmount);
        
        id = nextPositionId++;
        
        positions[id] = Position({
            id: id,
            maker: msg.sender,
            collateralAsset: collateralAsset,
            borrowAsset: borrowAsset,
            collateralAmount: collateralAmount,
            debtAmount: 0,
            targetLeverage: targetLeverage,
            minHealthFactor: minHealthFactor,
            maxSlippage: maxSlippage,
            entryPrice: entryPrice,
            entryDirection: entryDirection,
            status: Status.PENDING,
            createdAt: block.timestamp,
            executedAt: 0
        });

        userPositions[msg.sender].push(id);
        emit WindOrderCreated(id, msg.sender, collateralAsset, borrowAsset, collateralAmount, entryPrice, entryDirection);
    }
    
    /**
     * @notice (0.0.3) Execute multiple wind orders
     */
    function executeOrders(uint256[] calldata positionIds) external nonReentrant {
        if (paused) revert ContractPaused();

        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 id = positionIds[i];
            Position storage pos = positions[id];

            // Only execute PENDING orders
            if (pos.status != Status.PENDING) continue;

            uint256 currentPrice = getCurrentPrice(pos.collateralAsset, pos.borrowAsset);
            if (!_checkPriceCondition(currentPrice, pos.entryPrice, pos.entryDirection)) continue;

            // Execute Loop
            uaDriver.executeLoop(
                pos.collateralAsset,
                pos.borrowAsset,
                address(this),
                pos.collateralAmount,
                pos.targetLeverage,
                pos.minHealthFactor,
                pos.maxSlippage
            );

            // Fetch updated data from Aave
            (uint256 totalCollateral, uint256 totalDebt,,,,) = aavePool.getUserAccountData(address(this));

            // Update the EXISTING struct
            pos.status = Status.ACTIVE;
            pos.collateralAmount = totalCollateral;
            pos.debtAmount = totalDebt;
            pos.entryPrice = currentPrice; // Update entry price to actual execution price
            pos.executedAt = block.timestamp;

            // TP and SL mappings (positionToTP/SL) remain valid for this ID!
            
            emit WindOrderExecuted(id, id, currentPrice); // positionId is the same as orderId
        }
    }
    
/**
 * @notice Cancel a pending position
 */
function cancelPosition(uint256 positionId) external nonReentrant {
    Position storage pos = positions[positionId];
    
    if (pos.maker != msg.sender) revert Unauthorized();
    if (pos.status != Status.PENDING) revert PositionNotActive();
    
    pos.status = Status.CANCELLED;
    
    // Cancel associated TP/SL orders
    uint256 tpOrderId = positionToTP[positionId];
    uint256 slOrderId = positionToSL[positionId];
    
    if (tpOrderId != 0) {
        unwindOrders[tpOrderId].cancelled = true;
        delete positionToTP[positionId];
        delete unwindToPosition[tpOrderId];
        emit UnwindOrderCancelled(tpOrderId);
    }
    if (slOrderId != 0) {
        unwindOrders[slOrderId].cancelled = true;
        delete positionToSL[positionId];
        delete unwindToPosition[slOrderId];
        emit UnwindOrderCancelled(slOrderId);
    }
    
    // Return collateral to maker
    IERC20(pos.collateralAsset).transfer(pos.maker, pos.collateralAmount);
    
    emit WindOrderCancelled(positionId);
}
    
/**
 * @notice Bulk cancel pending positions
 */
function bulkCancelPositions(uint256[] calldata positionIds) external nonReentrant {
    for (uint256 i = 0; i < positionIds.length; i++) {
        uint256 positionId = positionIds[i];
        Position storage pos = positions[positionId];
        
        if (pos.maker != msg.sender) continue;
        if (pos.status != Status.PENDING) continue;
        
        pos.status = Status.CANCELLED;
        
        // Cancel associated TP/SL
        uint256 tpOrderId = positionToTP[positionId];
        uint256 slOrderId = positionToSL[positionId];
        
        if (tpOrderId != 0) {
            unwindOrders[tpOrderId].cancelled = true;
            delete positionToTP[positionId];
            delete unwindToPosition[tpOrderId];
            emit UnwindOrderCancelled(tpOrderId);
        }
        if (slOrderId != 0) {
            unwindOrders[slOrderId].cancelled = true;
            delete positionToSL[positionId];
            delete unwindToPosition[slOrderId];
            emit UnwindOrderCancelled(slOrderId);
        }
        
        IERC20(pos.collateralAsset).transfer(pos.maker, pos.collateralAmount);
        
        emit WindOrderCancelled(positionId);
    }
}
    
    // UNWIND ORDER FUNCTIONS (TP/SL)
    
/**
     * @notice Sets or updates the Take Profit order for a position (Pending or Active)
     */
    function setTP(
        uint256 positionId,
        uint256 targetPrice,
        bool priceDirection
    ) external nonReentrant returns (uint256 orderId) {
        Position storage pos = positions[positionId];
        if (pos.maker != msg.sender) revert Unauthorized();
        if (pos.status == Status.CLOSED || pos.status == Status.CANCELLED) revert PositionNotActive();
        if (targetPrice == 0) revert InvalidPrice();

        uint256 existingId = positionToTP[positionId];

        if (existingId != 0) {
            // Update existing
            UnwindOrder storage order = unwindOrders[existingId];
            if (order.executed) revert OrderAlreadyExecuted();
            order.targetPrice = targetPrice;
            order.priceDirection = priceDirection;
            order.cancelled = false; // Reactivate if it was cancelled
            return existingId;
        } else {
            // Create new
            orderId = nextUnwindOrderId++;
            unwindOrders[orderId] = UnwindOrder({
                id: orderId,
                positionId: positionId,
                targetPrice: targetPrice,
                priceDirection: priceDirection,
                isTP: true,
                executed: false,
                cancelled: false
            });
            positionToTP[positionId] = orderId;
            unwindToPosition[orderId] = positionId;
            emit UnwindOrderCreated(orderId, positionId, targetPrice, true);
        }
    }

    /**
     * @notice Sets or updates the Stop Loss order for a position (Pending or Active)
     */
    function setSL(
        uint256 positionId,
        uint256 targetPrice,
        bool priceDirection
    ) external nonReentrant returns (uint256 orderId) {
        Position storage pos = positions[positionId];
        if (pos.maker != msg.sender) revert Unauthorized();
        if (pos.status == Status.CLOSED || pos.status == Status.CANCELLED) revert PositionNotActive();
        if (targetPrice == 0) revert InvalidPrice();

        uint256 existingId = positionToSL[positionId];

        if (existingId != 0) {
            // Update existing
            UnwindOrder storage order = unwindOrders[existingId];
            if (order.executed) revert OrderAlreadyExecuted();
            order.targetPrice = targetPrice;
            order.priceDirection = priceDirection;
            order.cancelled = false;
            return existingId;
        } else {
            // Create new
            orderId = nextUnwindOrderId++;
            unwindOrders[orderId] = UnwindOrder({
                id: orderId,
                positionId: positionId,
                targetPrice: targetPrice,
                priceDirection: priceDirection,
                isTP: false,
                executed: false,
                cancelled: false
            });
            positionToSL[positionId] = orderId;
            unwindToPosition[orderId] = positionId;
            emit UnwindOrderCreated(orderId, positionId, targetPrice, false);
        }
    }

 // @notice Use cancelUnWindOrder for cancelling TP/Ss

/**
 * @notice Execute multiple unwind orders (TP/SL)
 */
function executeUnwinds(uint256[] calldata orderIds) external nonReentrant {
    if (paused) revert ContractPaused();
    
    for (uint256 i = 0; i < orderIds.length; i++) {
        uint256 orderId = orderIds[i];
        UnwindOrder storage order = unwindOrders[orderId];
        
        // Skip if order doesn't exist or already processed
        if (order.positionId == 0 || order.executed || order.cancelled) continue;
        
        Position storage position = positions[order.positionId];
        if (position.status != Status.ACTIVE) continue; // FIXED: use status enum
        
        // Get current price for this position's pair
        uint256 currentPrice = getCurrentPrice(position.collateralAsset, position.borrowAsset);
        
        // Check if price condition is met
        if (!_checkPriceCondition(currentPrice, order.targetPrice, order.priceDirection)) continue;
        
        // Execute the unwind
        _executeUnwindOrder(orderId, order, position, currentPrice);
    }
}
    
/**
 * @notice Internal function to execute an unwind order
 */
function _executeUnwindOrder(
    uint256 orderId,
    UnwindOrder storage order,
    Position storage position,
    uint256 executionPrice
) internal {
    // Mark as executed
    order.executed = true;
    position.status = Status.CLOSED; // FIXED: use status enum
    
    // Unwind via UADriver (repay = 0 means repay all)
    uaDriver.unwindLoop(
        position.collateralAsset,
        position.borrowAsset,
        0,
        0,
        200
    ); // 2% max slippage
    
    // Calculate P&L (simplified - actual implementation would be more complex)
    uint256 pnl = 0;
    if (executionPrice > position.entryPrice) {
        pnl = ((executionPrice - position.entryPrice) * position.collateralAmount) / PRECISION;
    }
    
    // Transfer remaining collateral to maker
    uint256 balance = IERC20(position.collateralAsset).balanceOf(address(this));
    if (balance > 0) {
        IERC20(position.collateralAsset).transfer(position.maker, balance);
    }
    
    // Clear TP/SL mappings
    delete positionToTP[position.id];
    delete positionToSL[position.id];
    
    emit UnwindOrderExecuted(orderId, order.positionId, executionPrice, pnl);
}
    
/**
 * @notice Cancel an unwind order (TP or SL)
 */
function cancelUnwindOrder(uint256 orderId) external nonReentrant {
    UnwindOrder storage order = unwindOrders[orderId];
    Position storage position = positions[order.positionId];
    
    if (position.maker != msg.sender) revert Unauthorized();
    if (order.executed) revert OrderAlreadyExecuted();
    if (order.cancelled) revert OrderAlreadyCancelled();
    
    order.cancelled = true;
    
    // Clear reference from position mappings
    if (order.isTP) {
        delete positionToTP[order.positionId];
    } else {
        delete positionToSL[order.positionId];
    }
    delete unwindToPosition[orderId];
    
    emit UnwindOrderCancelled(orderId);
}
    
/**
 * @notice Bulk cancel unwind orders
 */
function bulkCancelUnwindOrders(uint256[] calldata orderIds) external nonReentrant {
    for (uint256 i = 0; i < orderIds.length; i++) {
        uint256 orderId = orderIds[i];
        UnwindOrder storage order = unwindOrders[orderId];
        Position storage position = positions[order.positionId];
        
        if (position.maker != msg.sender) continue;
        if (order.executed || order.cancelled) continue;
        
        order.cancelled = true;
        
        if (order.isTP) {
            delete positionToTP[order.positionId];
        } else {
            delete positionToSL[order.positionId];
        }
        delete unwindToPosition[orderId];
        
        emit UnwindOrderCancelled(orderId);
    }
}
    
/**
 * @notice Manually close an active position
 */
function closePosition(uint256 positionId) external nonReentrant {
    Position storage position = positions[positionId];
    
    if (position.maker != msg.sender) revert Unauthorized();
    if (position.status != Status.ACTIVE) revert PositionNotActive();
    
    position.status = Status.CLOSED;
    
    // Cancel any pending TP/SL orders
    uint256 tpOrderId = positionToTP[positionId];
    uint256 slOrderId = positionToSL[positionId];
    
    if (tpOrderId != 0) {
        unwindOrders[tpOrderId].cancelled = true;
        delete positionToTP[positionId];
        delete unwindToPosition[tpOrderId];
    }
    if (slOrderId != 0) {
        unwindOrders[slOrderId].cancelled = true;
        delete positionToSL[positionId];
        delete unwindToPosition[slOrderId];
    }
    
    // Unwind position
    uaDriver.unwindLoop(
        position.collateralAsset,
        position.borrowAsset,
        0,
        0,
        200
    );
    
    // Transfer remaining collateral to maker
    uint256 balance = IERC20(position.collateralAsset).balanceOf(address(this));
    uint256 pnl = balance > position.collateralAmount ? balance - position.collateralAmount : 0;
    
    if (balance > 0) {
        IERC20(position.collateralAsset).transfer(position.maker, balance);
    }
    
    emit PositionClosed(positionId, position.maker, pnl);
}
    
/**
 * @notice Bulk close positions
 */
function bulkClosePositions(uint256[] calldata positionIds) external nonReentrant {
    for (uint256 i = 0; i < positionIds.length; i++) {
        uint256 positionId = positionIds[i];
        Position storage position = positions[positionId];
        
        if (position.maker != msg.sender) continue;
        if (position.status != Status.ACTIVE) continue;
        
        position.status = Status.CLOSED;
        
        // Cancel TP/SL
        uint256 tpOrderId = positionToTP[positionId];
        uint256 slOrderId = positionToSL[positionId];
        
        if (tpOrderId != 0) {
            unwindOrders[tpOrderId].cancelled = true;
            delete positionToTP[positionId];
            delete unwindToPosition[tpOrderId];
        }
        if (slOrderId != 0) {
            unwindOrders[slOrderId].cancelled = true;
            delete positionToSL[positionId];
            delete unwindToPosition[slOrderId];
        }
        
        // Unwind
        uaDriver.unwindLoop(
            position.collateralAsset,
            position.borrowAsset,
            0,
            0,
            200
        );
        
        // Transfer
        uint256 balance = IERC20(position.collateralAsset).balanceOf(address(this));
        uint256 pnl = balance > position.collateralAmount ? balance - position.collateralAmount : 0;
        
        if (balance > 0) {
            IERC20(position.collateralAsset).transfer(position.maker, balance);
        }
        
        emit PositionClosed(positionId, position.maker, pnl);
    }
}
    
    // INTERNAL HELPERS
    
    /**
     * @notice Dynamic approval helper
     */
    function _approveIfNeeded(address token, address spender, uint256 amount) internal {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (allowance < amount) {
            IERC20(token).approve(spender, type(uint256).max);
        }
    }
    
    // VIEW FUNCTIONS
    
/**
 * @notice Get position with associated TP/SL details
 */
function getPositionWithOrders(uint256 positionId) external view returns (
    Position memory position,
    UnwindOrder memory tpOrder,
    UnwindOrder memory slOrder
) {
    position = positions[positionId];
    
    uint256 tpOrderId = positionToTP[positionId];
    uint256 slOrderId = positionToSL[positionId];
    
    if (tpOrderId != 0) {
        tpOrder = unwindOrders[tpOrderId];
    }
    if (slOrderId != 0) {
        slOrder = unwindOrders[slOrderId];
    }
}

/**
 * @notice Get all pending positions (wind orders) for a user
 */
function getUserPendingPositions(address user) external view returns (uint256[] memory) {
    uint256[] memory allPositions = userPositions[user];
    uint256 count = 0;
    
    // Count pending positions
    for (uint256 i = 0; i < allPositions.length; i++) {
        if (positions[allPositions[i]].status == Status.PENDING) {
            count++;
        }
    }
    
    // Create result array
    uint256[] memory pending = new uint256[](count);
    uint256 index = 0;
    for (uint256 i = 0; i < allPositions.length; i++) {
        if (positions[allPositions[i]].status == Status.PENDING) {
            pending[index] = allPositions[i];
            index++;
        }
    }
    
    return pending;
}

/**
 * @notice Get all active positions for a user
 */
function getUserActivePositions(address user) external view returns (uint256[] memory) {
    uint256[] memory allPositions = userPositions[user];
    uint256 count = 0;
    
    // Count active positions
    for (uint256 i = 0; i < allPositions.length; i++) {
        if (positions[allPositions[i]].status == Status.ACTIVE) {
            count++;
        }
    }
    
    // Create result array
    uint256[] memory active = new uint256[](count);
    uint256 index = 0;
    for (uint256 i = 0; i < allPositions.length; i++) {
        if (positions[allPositions[i]].status == Status.ACTIVE) {
            active[index] = allPositions[i];
            index++;
        }
    }
    
    return active;
}

/**
 * @notice Check if unwind order can be executed
 */
function canExecuteUnwind(uint256 orderId) external view returns (bool) {
    UnwindOrder memory order = unwindOrders[orderId];
    
    if (order.executed || order.cancelled) {
        return false;
    }
    
    uint256 positionId = unwindToPosition[orderId];
    if (positionId == 0) {
        return false;
    }
    
    Position memory position = positions[positionId];
    if (position.status != Status.ACTIVE) {
        return false;
    }
    
    uint256 currentPrice = getCurrentPrice(position.collateralAsset, position.borrowAsset);
    return _checkPriceCondition(currentPrice, order.targetPrice, order.priceDirection);
}

/**
 * @notice Get TP/SL order IDs for a position
 */
function getPositionTPSL(uint256 positionId) external view returns (uint256 tpOrderId, uint256 slOrderId) {
    tpOrderId = positionToTP[positionId];
    slOrderId = positionToSL[positionId];
}

/**
 * @notice Check if position can be executed (for PENDING positions)
 */
function canExecutePosition(uint256 positionId) external view returns (bool) {
    Position memory pos = positions[positionId];
    
    if (pos.maker == address(0) || pos.status != Status.PENDING) {
        return false;
    }
    
    uint256 currentPrice = getCurrentPrice(pos.collateralAsset, pos.borrowAsset);
    return _checkPriceCondition(currentPrice, pos.entryPrice, pos.entryDirection);
}
    
    // ADMIN FUNCTIONS
    
    function togglePause() external onlyOwner {
        paused = !paused;
        emit PauseToggled(paused);
    }
    
    receive() external payable {}
}
