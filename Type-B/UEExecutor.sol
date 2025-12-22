// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.20;

import "./imports/ReentrancyGuard.sol"; //Imports and inherits Ownable
import "./imports/IERC20.sol";

// =============================================================
// INTERFACES
// =============================================================

interface IUEDriver {
    function executeLoop(
        address collateralVault,
        address borrowVault,
        uint256 initialMargin,
        uint256 targetLeverage,
        uint256 minHealthFactor,
        uint256 maxSlippage
    ) external;

    function unwindLoop(
        address collateralVault,
        address borrowVault,
        uint256 repayAmount,
        uint256 withdrawAmount,
        uint256 maxSlippage
    ) external;
}

interface IEVault {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    // Standard ERC20-like views for Shares
    function balanceOf(address account) external view returns (uint256);
    // Euler V2 Debt View (Generic wrapper)
    function debtOf(address account) external view returns (uint256); 
    function convertToAssets(uint256 shares) external view returns (uint256);
}

// Uniswap V2 Interfaces (Preserved for Limit Order Triggers)
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

// =============================================================
// MAIN CONTRACT
// =============================================================

/**
 * @title UEExecutor - Limit Order System for Euler V2
 * @notice Manages limit orders for position creation and unwinding on Euler Vaults.
 * @dev Holds custody of positions (Monolithic Executor model). Uses UEDriver for execution.
 */
contract UEExecutor is ReentrancyGuard {
    
    // ENUMS
    enum Status { PENDING, ACTIVE, CLOSED, CANCELLED }

    // STRUCTS
    struct Position {
        uint256 id;
        address maker;
        address collateralVault; // Euler Vault Address
        address borrowVault;     // Euler Vault Address
        uint256 collateralAmount;
        uint256 debtAmount;      // Tracked debt
        uint256 targetLeverage;
        uint256 minHealthFactor;
        uint256 maxSlippage;
        uint256 entryPrice;      // Trigger price
        bool entryDirection;     // true: >=, false: <=
        Status status;
        uint256 createdAt;
        uint256 executedAt;
    }

    struct UnwindOrder {
        uint256 id;
        uint256 positionId;
        uint256 targetPrice;
        bool priceDirection;     // true: >=, false: <=
        bool isTP;               // true: TP, false: SL
        bool executed;
        bool cancelled;
    }
    
    // STATE VARIABLES
    
    IUEDriver public ueDriver;
    IUniswapV2Factory public uniswapFactory;
    
    // Mappings
    mapping(uint256 => Position) public positions;
    mapping(uint256 => UnwindOrder) public unwindOrders;
    
    // Simplified TP/SL Mappings (Position ID => Unwind Order ID)
    mapping(uint256 => uint256) public positionToTP;
    mapping(uint256 => uint256) public positionToSL;
    
    // Reverse mapping
    mapping(uint256 => uint256) public unwindToPosition;
    
    // Tracking 
    uint256 public nextUnwindOrderId = 1;
    uint256 public nextPositionId = 1;
    mapping(address => uint256[]) public userPositions;

    // Constants
    uint256 private constant PRECISION = 1e18;
    
    // Configuration
    bool public paused;
    
    // EVENTS
    
    event WindOrderCreated(uint256 indexed orderId, address indexed maker, address collateralVault, address borrowVault, uint256 collateralAmount, uint256 entryPrice);
    event WindOrderExecuted(uint256 indexed orderId, uint256 indexed positionId, uint256 executionPrice);
    event WindOrderCancelled(uint256 indexed orderId);
    
    event UnwindOrderCreated(uint256 indexed orderId, uint256 indexed positionId, uint256 targetPrice, bool isTP);
    event UnwindOrderExecuted(uint256 indexed orderId, uint256 indexed positionId, uint256 executionPrice, uint256 pnl);
    event UnwindOrderCancelled(uint256 indexed orderId);
    event PositionClosed(uint256 indexed positionId, address indexed maker, uint256 pnl);
    event PauseToggled(bool paused);

    // ERRORS
    
    error ContractPaused();
    error InvalidAmount();
    error InvalidPrice();
    error Unauthorized();
    error PositionNotActive();
    error OrderAlreadyExecuted();
    error OrderAlreadyCancelled();
    error PairNotFound();
    error SameAsset();
    error InvalidVault();

    // CONSTRUCTOR 
    constructor() Ownable() {
        // Dependencies set via setters
    }
    
    // SETTER FUNCTIONS
    
    function setUEDriver(address _ueDriver) external onlyOwner {
        require(_ueDriver != address(0), "Invalid driver");
        ueDriver = IUEDriver(_ueDriver);
    }
    
    function setUniswapFactory(address _uniswapFactory) external onlyOwner {
        require(_uniswapFactory != address(0), "Invalid factory");
        uniswapFactory = IUniswapV2Factory(_uniswapFactory);
    }
    
    // PRICE FUNCTIONS (Uniswap V2 Trigger Logic)
    
    function getCurrentPrice(address collateralAsset, address borrowAsset) public view returns (uint256 price) {
        address pairAddress = uniswapFactory.getPair(collateralAsset, borrowAsset);
        if (pairAddress == address(0)) revert PairNotFound();
        
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        
        address token0 = pair.token0();
        if (token0 == collateralAsset) {
            price = (uint256(reserve1) * PRECISION) / uint256(reserve0);
        } else {
            price = (uint256(reserve0) * PRECISION) / uint256(reserve1);
        }
    }
    
    function _checkPriceCondition(uint256 currentPrice, uint256 targetPrice, bool direction) internal pure returns (bool) {
        return direction ? currentPrice >= targetPrice : currentPrice <= targetPrice;
    }
    
    // WIND ORDER FUNCTIONS
    
   /**
     * @notice Create a new Position (starts as PENDING wind order)
     * @param collateralVault The Euler Vault for collateral
     * @param borrowVault The Euler Vault for debt
     */
    function createOrder(
        address collateralVault,
        address borrowVault,
        uint256 collateralAmount,
        uint256 targetLeverage,
        uint256 minHealthFactor,
        uint256 maxSlippage,
        uint256 entryPrice,
        bool entryDirection
    ) external nonReentrant returns (uint256 id) {
        if (paused) revert ContractPaused();
        if (collateralVault == borrowVault) revert SameAsset();
        if (collateralAmount == 0) revert InvalidAmount();
        
        // 1. Resolve Underlying Asset from Vault
        address collateralAsset = IEVault(collateralVault).asset();
        
        // 2. Transfer Underlying to Executor (Custody)
        IERC20(collateralAsset).transferFrom(msg.sender, address(this), collateralAmount);
        
        // 3. Approve Driver to spend Underlying (for when execution happens)
        _approveIfNeeded(collateralAsset, address(ueDriver), collateralAmount);

        id = nextPositionId++;
        
        positions[id] = Position({
            id: id,
            maker: msg.sender,
            collateralVault: collateralVault,
            borrowVault: borrowVault,
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
        emit WindOrderCreated(id, msg.sender, collateralVault, borrowVault, collateralAmount, entryPrice);
    }
    
    /**
     * @notice Execute multiple wind orders
     */
    function executeOrders(uint256[] calldata positionIds) external nonReentrant {
        if (paused) revert ContractPaused();
        
        for (uint256 i = 0; i < positionIds.length; i++) {
            uint256 id = positionIds[i];
            Position storage pos = positions[id];

            if (pos.status != Status.PENDING) continue;
            
            // Resolve underlying assets for Price Check
            address colAsset = IEVault(pos.collateralVault).asset();
            address borAsset = IEVault(pos.borrowVault).asset();
            
            uint256 currentPrice = getCurrentPrice(colAsset, borAsset);
            
            if (!_checkPriceCondition(currentPrice, pos.entryPrice, pos.entryDirection)) continue;

            // Execute Loop via Driver
            // NOTE: Driver will pull funds from Executor (address(this))
            // The position is opened in the name of Executor (address(this))
            ueDriver.executeLoop(
                pos.collateralVault,
                pos.borrowVault,
                pos.collateralAmount,
                pos.targetLeverage,
                pos.minHealthFactor,
                pos.maxSlippage
            );

            // Update Position State
            pos.status = Status.ACTIVE;
            
            // Fetch Updated Collateral Balance (Shares -> Assets)
            uint256 shares = IEVault(pos.collateralVault).balanceOf(address(this));
            pos.collateralAmount = IEVault(pos.collateralVault).convertToAssets(shares);
            
            // Fetch Updated Debt
            // Assuming standard "debtOf" or similar. 
            // In a real integration, we might need a specific adapter if the vault is non-standard.
            pos.debtAmount = IEVault(pos.borrowVault).debtOf(address(this));
            
            pos.entryPrice = currentPrice;
            pos.executedAt = block.timestamp;
            
            emit WindOrderExecuted(id, id, currentPrice);
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
        
        // Cancel TP/SL
        _cancelAssociatedOrders(positionId);
        
        // Return collateral to maker
        address colAsset = IEVault(pos.collateralVault).asset();
        IERC20(colAsset).transfer(pos.maker, pos.collateralAmount);
        
        emit WindOrderCancelled(positionId);
    }

    // UNWIND ORDER FUNCTIONS (TP/SL)
    
    function setTP(uint256 positionId, uint256 targetPrice, bool priceDirection) external nonReentrant returns (uint256) {
        return _setUnwindOrder(positionId, targetPrice, priceDirection, true);
    }

    function setSL(uint256 positionId, uint256 targetPrice, bool priceDirection) external nonReentrant returns (uint256) {
        return _setUnwindOrder(positionId, targetPrice, priceDirection, false);
    }

    function _setUnwindOrder(uint256 positionId, uint256 targetPrice, bool priceDirection, bool isTP) internal returns (uint256) {
        Position storage pos = positions[positionId];
        if (pos.maker != msg.sender) revert Unauthorized();
        if (pos.status == Status.CLOSED || pos.status == Status.CANCELLED) revert PositionNotActive();
        if (targetPrice == 0) revert InvalidPrice();

        // Logic matches UAExecutor: Check existing, update or create new
        uint256 existingId = isTP ? positionToTP[positionId] : positionToSL[positionId];
        
        if (existingId != 0) {
            UnwindOrder storage order = unwindOrders[existingId];
            if (order.executed) revert OrderAlreadyExecuted();
            order.targetPrice = targetPrice;
            order.priceDirection = priceDirection;
            order.cancelled = false;
            return existingId;
        } else {
            uint256 orderId = nextUnwindOrderId++;
            unwindOrders[orderId] = UnwindOrder({
                id: orderId,
                positionId: positionId,
                targetPrice: targetPrice,
                priceDirection: priceDirection,
                isTP: isTP,
                executed: false,
                cancelled: false
            });
            
            if (isTP) positionToTP[positionId] = orderId;
            else positionToSL[positionId] = orderId;
            
            unwindToPosition[orderId] = positionId;
            emit UnwindOrderCreated(orderId, positionId, targetPrice, isTP);
            return orderId;
        }
    }

    /**
     * @notice Execute multiple unwind orders (TP/SL)
     */
    function executeUnwinds(uint256[] calldata orderIds) external nonReentrant {
        if (paused) revert ContractPaused();
        
        for (uint256 i = 0; i < orderIds.length; i++) {
            uint256 orderId = orderIds[i];
            UnwindOrder storage order = unwindOrders[orderId];
            
            if (order.positionId == 0 || order.executed || order.cancelled) continue;
            
            Position storage position = positions[order.positionId];
            if (position.status != Status.ACTIVE) continue;
            
            // Resolve Assets for Price Check
            address colAsset = IEVault(position.collateralVault).asset();
            address borAsset = IEVault(position.borrowVault).asset();

            uint256 currentPrice = getCurrentPrice(colAsset, borAsset);
            
            if (!_checkPriceCondition(currentPrice, order.targetPrice, order.priceDirection)) continue;
            
            _executeUnwindOrder(orderId, order, position, currentPrice);
        }
    }
    
    function _executeUnwindOrder(uint256 orderId, UnwindOrder storage order, Position storage position, uint256 executionPrice) internal {
        order.executed = true;
        position.status = Status.CLOSED;
        
        // Unwind via UEDriver
        // Note: Driver will manage the swap and repay debt for Executor (address(this))
        ueDriver.unwindLoop(
            position.collateralVault,
            position.borrowVault,
            0, // Repay All
            0, // Withdraw All
            200 // Max Slippage
        );
        
        // Calculate PnL and Transfer
        _settlePosition(position, executionPrice);
        
        // Clean up
        delete positionToTP[position.id];
        delete positionToSL[position.id];
        
        // Emit PnL is calculated in settlement but we need it here for event
        // Simplified PnL for event (actual transfer happened in settle)
        uint256 pnl = 0;
        if (executionPrice > position.entryPrice) {
            pnl = ((executionPrice - position.entryPrice) * position.collateralAmount) / PRECISION;
        }
        emit UnwindOrderExecuted(orderId, order.positionId, executionPrice, pnl);
    }
    
    function closePosition(uint256 positionId) external nonReentrant {
        Position storage position = positions[positionId];
        if (position.maker != msg.sender) revert Unauthorized();
        if (position.status != Status.ACTIVE) revert PositionNotActive();
        
        position.status = Status.CLOSED;
        _cancelAssociatedOrders(positionId);
        
        ueDriver.unwindLoop(
            position.collateralVault,
            position.borrowVault,
            0, 
            0, 
            200
        );
        
        _settlePosition(position, 0); // Price 0 as manual close
        emit PositionClosed(positionId, position.maker, 0);
    }
    
    // INTERNAL HELPERS
    
    function _settlePosition(Position storage position, uint256 /*executionPrice*/) internal {
        address colAsset = IEVault(position.collateralVault).asset();
        
        // Check Executor's balance of underlying
        uint256 balance = IERC20(colAsset).balanceOf(address(this));
        
        // Transfer all retrieved collateral back to Maker
        if (balance > 0) {
            IERC20(colAsset).transfer(position.maker, balance);
        }
    }

    function _cancelAssociatedOrders(uint256 positionId) internal {
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
    }

    function _approveIfNeeded(address token, address spender, uint256 amount) internal {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (allowance < amount) {
            IERC20(token).approve(spender, type(uint256).max);
        }
    }
    
    // ADMIN
    function togglePause() external onlyOwner {
        paused = !paused;
        emit PauseToggled(paused);
    }

    receive() external payable {}
}