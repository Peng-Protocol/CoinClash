// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.20;

/**
 * @title UAExecutor - Limit Order System for Automated Debt Looping
 * @notice Manages limit orders for position creation (winds) and unwinding with TP/SL
 * @dev Integrates with UADriver for position execution
 */
// File Version: 0.0.2 (10/12/2025)
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
    
    // STRUCTS
    
    struct WindOrder {
        address maker;
        address collateralAsset;      // NEW: Store pair info in order
        address borrowAsset;           // NEW: Store pair info in order
        uint256 collateralAmount;
        uint256 targetLeverage;
        uint256 minHealthFactor;
        uint256 maxSlippage;
        uint256 entryPrice;            // Price at which to execute (scaled 1e18)
        bool entryDirection;           // true = execute when current >= entry, false = execute when current <= entry
        uint256 createdAt;
        bool executed;
        bool cancelled;
    }
    
    struct UnwindOrder {
        uint256 positionId;
        uint256 targetPrice;           // Price at which to unwind
        bool priceDirection;           // true = unwind when current >= target, false = unwind when current <= target
        bool isTP;                     // true = Take Profit, false = Stop Loss
        bool executed;
        bool cancelled;
    }
    
    struct Position {
        address maker;
        address collateralAsset;       // NEW: Store pair info in position
        address borrowAsset;           // NEW: Store pair info in position
        uint256 windOrderId;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 entryPrice;
        uint256 createdAt;
        bool active;
        uint256 tpOrderId;             // 0 if no TP set
        uint256 slOrderId;             // 0 if no SL set
    }
    
    // STATE VARIABLES
    
    IUADriver public immutable uaDriver;
    IUniswapV2Factory public immutable uniswapFactory;
    IPool public immutable aavePool;
    
    // REMOVED: collateralAsset, borrowAsset, pairAddress
    
    // Order tracking
    uint256 public nextWindOrderId = 1;
    uint256 public nextUnwindOrderId = 1;
    uint256 public nextPositionId = 1;
    
    mapping(uint256 => WindOrder) public windOrders;
    mapping(uint256 => UnwindOrder) public unwindOrders;
    mapping(uint256 => Position) public positions;
    
    // User tracking
    mapping(address => uint256[]) public userWindOrders;
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
    
    constructor(
        address _uaDriver,
        address _uniswapFactory,
        address _aavePool
    ) Ownable() {
        require(_uaDriver != address(0), "Invalid driver");
        require(_uniswapFactory != address(0), "Invalid factory");
        require(_aavePool != address(0), "Invalid pool");
        
        uaDriver = IUADriver(_uaDriver);
        uniswapFactory = IUniswapV2Factory(_uniswapFactory);
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
     * @notice Create a wind order (limit order to open leveraged position)
     */
    function createWindOrder(
        address collateralAsset,
        address borrowAsset,
        uint256 collateralAmount,
        uint256 targetLeverage,
        uint256 minHealthFactor,
        uint256 maxSlippage,
        uint256 entryPrice,
        bool entryDirection
    ) external nonReentrant returns (uint256 orderId) {
        if (paused) revert ContractPaused();
        if (collateralAsset == borrowAsset) revert SameAsset();
        if (collateralAmount == 0) revert InvalidAmount();
        if (entryPrice == 0) revert InvalidPrice();
        if (targetLeverage < PRECISION || targetLeverage > 10 * PRECISION) revert InvalidLeverage();
        
        // Verify pair exists
        address pair = uniswapFactory.getPair(collateralAsset, borrowAsset);
        if (pair == address(0)) revert PairNotFound();
        
        // Transfer collateral to this contract
        IERC20(collateralAsset).transferFrom(msg.sender, address(this), collateralAmount);
        
        // Approve UADriver to spend this collateral (dynamic approval)
        _approveIfNeeded(collateralAsset, address(uaDriver), collateralAmount);
        
        orderId = nextWindOrderId++;
        
        windOrders[orderId] = WindOrder({
            maker: msg.sender,
            collateralAsset: collateralAsset,
            borrowAsset: borrowAsset,
            collateralAmount: collateralAmount,
            targetLeverage: targetLeverage,
            minHealthFactor: minHealthFactor,
            maxSlippage: maxSlippage,
            entryPrice: entryPrice,
            entryDirection: entryDirection,
            createdAt: block.timestamp,
            executed: false,
            cancelled: false
        });
        
        userWindOrders[msg.sender].push(orderId);
        
        emit WindOrderCreated(orderId, msg.sender, collateralAsset, borrowAsset, collateralAmount, entryPrice, entryDirection);
    }
    
    /**
     * @notice Execute multiple wind orders
     */
    function executeWinds(uint256[] calldata orderIds) external nonReentrant {
        if (paused) revert ContractPaused();
        
        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];
            WindOrder storage order = windOrders[orderId];
            
            // Skip if order doesn't exist or already processed
            if (order.maker == address(0) || order.executed || order.cancelled) continue;
            
            // Get current price for this order's pair
            uint256 currentPrice = getCurrentPrice(order.collateralAsset, order.borrowAsset);
            
            // Check if price condition is met
            if (!_checkPriceCondition(currentPrice, order.entryPrice, order.entryDirection)) continue;
            
            // Execute the order
            _executeWindOrder(orderId, order, currentPrice);
        }
    }
    
    /**
     * @notice Internal function to execute a wind order
     */
    function _executeWindOrder(
        uint256 orderId,
        WindOrder storage order,
        uint256 executionPrice
    ) internal {
        // Mark as executed
        order.executed = true;
        
        // Execute loop via UADriver (creates position for this contract)
        uaDriver.executeLoop(
            order.collateralAsset,
            order.borrowAsset,
            address(this),
            order.collateralAmount,
            order.targetLeverage,
            order.minHealthFactor,
            order.maxSlippage
        );
        
        // Create position record
        uint256 positionId = nextPositionId++;
        
        // Get position data from Aave
        (uint256 totalCollateral, uint256 totalDebt,,,,) = aavePool.getUserAccountData(address(this));
        
        positions[positionId] = Position({
            maker: order.maker,
            collateralAsset: order.collateralAsset,
            borrowAsset: order.borrowAsset,
            windOrderId: orderId,
            collateralAmount: totalCollateral,
            debtAmount: totalDebt,
            entryPrice: executionPrice,
            createdAt: block.timestamp,
            active: true,
            tpOrderId: 0,
            slOrderId: 0
        });
        
        userPositions[order.maker].push(positionId);
        
        emit WindOrderExecuted(orderId, positionId, executionPrice);
    }
    
    /**
     * @notice Cancel a pending wind order
     */
    function cancelWindOrder(uint256 orderId) external nonReentrant {
        WindOrder storage order = windOrders[orderId];
        
        if (order.maker != msg.sender) revert Unauthorized();
        if (order.executed) revert OrderAlreadyExecuted();
        if (order.cancelled) revert OrderAlreadyCancelled();
        
        order.cancelled = true;
        
        // Return collateral to maker
        IERC20(order.collateralAsset).transfer(order.maker, order.collateralAmount);
        
        emit WindOrderCancelled(orderId);
    }
    
    /**
     * @notice Bulk cancel wind orders
     */
    function bulkCancelWindOrders(uint256[] calldata orderIds) external nonReentrant {
        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];
            WindOrder storage order = windOrders[orderId];
            
            if (order.maker != msg.sender) continue;
            if (order.executed || order.cancelled) continue;
            
            order.cancelled = true;
            IERC20(order.collateralAsset).transfer(order.maker, order.collateralAmount);
            
            emit WindOrderCancelled(orderId);
        }
    }
    
    // UNWIND ORDER FUNCTIONS (TP/SL)
    
    /**
     * @notice Create a Take Profit order
     */
    function createTPOrder(
        uint256 positionId,
        uint256 targetPrice,
        bool priceDirection
    ) external nonReentrant returns (uint256 orderId) {
        Position storage position = positions[positionId];
        
        if (position.maker != msg.sender) revert Unauthorized();
        if (!position.active) revert PositionNotActive();
        if (position.tpOrderId != 0) revert TPSLAlreadySet();
        if (targetPrice == 0) revert InvalidPrice();
        
        orderId = nextUnwindOrderId++;
        
        unwindOrders[orderId] = UnwindOrder({
            positionId: positionId,
            targetPrice: targetPrice,
            priceDirection: priceDirection,
            isTP: true,
            executed: false,
            cancelled: false
        });
        
        position.tpOrderId = orderId;
        
        emit UnwindOrderCreated(orderId, positionId, targetPrice, true);
    }
    
    /**
     * @notice Create a Stop Loss order
     */
    function createSLOrder(
        uint256 positionId,
        uint256 targetPrice,
        bool priceDirection
    ) external nonReentrant returns (uint256 orderId) {
        Position storage position = positions[positionId];
        
        if (position.maker != msg.sender) revert Unauthorized();
        if (!position.active) revert PositionNotActive();
        if (position.slOrderId != 0) revert TPSLAlreadySet();
        if (targetPrice == 0) revert InvalidPrice();
        
        orderId = nextUnwindOrderId++;
        
        unwindOrders[orderId] = UnwindOrder({
            positionId: positionId,
            targetPrice: targetPrice,
            priceDirection: priceDirection,
            isTP: false,
            executed: false,
            cancelled: false
        });
        
        position.slOrderId = orderId;
        
        emit UnwindOrderCreated(orderId, positionId, targetPrice, false);
    }
    
    /**
     * @notice Update Take Profit order
     */
    function updateTPOrder(
        uint256 positionId,
        uint256 newTargetPrice,
        bool newPriceDirection
    ) external nonReentrant {
        Position storage position = positions[positionId];
        
        if (position.maker != msg.sender) revert Unauthorized();
        if (!position.active) revert PositionNotActive();
        if (position.tpOrderId == 0) revert OrderNotFound();
        if (newTargetPrice == 0) revert InvalidPrice();
        
        UnwindOrder storage order = unwindOrders[position.tpOrderId];
        if (order.executed) revert OrderAlreadyExecuted();
        
        order.targetPrice = newTargetPrice;
        order.priceDirection = newPriceDirection;
    }
    
    /**
     * @notice Update Stop Loss order
     */
    function updateSLOrder(
        uint256 positionId,
        uint256 newTargetPrice,
        bool newPriceDirection
    ) external nonReentrant {
        Position storage position = positions[positionId];
        
        if (position.maker != msg.sender) revert Unauthorized();
        if (!position.active) revert PositionNotActive();
        if (position.slOrderId == 0) revert OrderNotFound();
        if (newTargetPrice == 0) revert InvalidPrice();
        
        UnwindOrder storage order = unwindOrders[position.slOrderId];
        if (order.executed) revert OrderAlreadyExecuted();
        
        order.targetPrice = newTargetPrice;
        order.priceDirection = newPriceDirection;
    }
    
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
            if (!position.active) continue;
            
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
        position.active = false;
        
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
        
        // Clear reference from position
        if (order.isTP) {
            position.tpOrderId = 0;
        } else {
            position.slOrderId = 0;
        }
        
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
                position.tpOrderId = 0;
            } else {
                position.slOrderId = 0;
            }
            
            emit UnwindOrderCancelled(orderId);
        }
    }
    
    /**
     * @notice Manually close an active position
     */
    function closePosition(uint256 positionId) external nonReentrant {
        Position storage position = positions[positionId];
        
        if (position.maker != msg.sender) revert Unauthorized();
        if (!position.active) revert PositionNotActive();
        
        position.active = false;
        
        // Cancel any pending TP/SL orders
        if (position.tpOrderId != 0) {
            unwindOrders[position.tpOrderId].cancelled = true;
        }
        if (position.slOrderId != 0) {
            unwindOrders[position.slOrderId].cancelled = true;
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
            if (!position.active) continue;
            
            position.active = false;
            
            // Cancel TP/SL
            if (position.tpOrderId != 0) {
                unwindOrders[position.tpOrderId].cancelled = true;
            }
            if (position.slOrderId != 0) {
                unwindOrders[position.slOrderId].cancelled = true;
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
     * @notice Get wind order details
     */
    function getWindOrder(uint256 orderId) external view returns (WindOrder memory) {
        return windOrders[orderId];
    }
    
    /**
     * @notice Get unwind order details
     */
    function getUnwindOrder(uint256 orderId) external view returns (UnwindOrder memory) {
        return unwindOrders[orderId];
    }
    
    /**
     * @notice Get position details
     */
    function getPosition(uint256 positionId) external view returns (Position memory) {
        return positions[positionId];
    }
    
    /**
     * @notice Get position with TP/SL details
     */
    function getPositionWithOrders(uint256 positionId) external view returns (
        Position memory position,
        UnwindOrder memory tpOrder,
        UnwindOrder memory slOrder
    ) {
        position = positions[positionId];
        
        if (position.tpOrderId != 0) {
            tpOrder = unwindOrders[position.tpOrderId];
        }
        if (position.slOrderId != 0) {
            slOrder = unwindOrders[position.slOrderId];
        }
    }
    
    /**
     * @notice Get all wind orders for a user
     */
    function getUserWindOrders(address user) external view returns (uint256[] memory) {
        return userWindOrders[user];
    }
    
    /**
     * @notice Get all positions for a user
     */
    function getUserPositions(address user) external view returns (uint256[] memory) {
        return userPositions[user];
    }
    
    /**
     * @notice Check if wind order can be executed
     */
    function canExecuteWind(uint256 orderId) external view returns (bool) {
        WindOrder memory order = windOrders[orderId];
        
        if (order.maker == address(0) || order.executed || order.cancelled) {
            return false;
        }
        
        uint256 currentPrice = getCurrentPrice(order.collateralAsset, order.borrowAsset);
        return _checkPriceCondition(currentPrice, order.entryPrice, order.entryDirection);
    }
    
    /**
     * @notice Check if unwind order can be executed
     */
    function canExecuteUnwind(uint256 orderId) external view returns (bool) {
        UnwindOrder memory order = unwindOrders[orderId];
        
        if (order.positionId == 0 || order.executed || order.cancelled) {
            return false;
        }
        
        Position memory position = positions[order.positionId];
        if (!position.active) {
            return false;
        }
        
        uint256 currentPrice = getCurrentPrice(position.collateralAsset, position.borrowAsset);
        return _checkPriceCondition(currentPrice, order.targetPrice, order.priceDirection);
    }
    
    // ADMIN FUNCTIONS
    
    function togglePause() external onlyOwner {
        paused = !paused;
        emit PauseToggled(paused);
    }
    
    /**
     * @notice Emergency withdraw function for stuck funds
     */
    function emergencyWithdraw(address asset, uint256 amount) external onlyOwner {
        IERC20(asset).transfer(owner(), amount);
    }
    
    receive() external payable {}
}
