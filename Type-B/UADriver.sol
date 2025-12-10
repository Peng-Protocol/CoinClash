// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title UADriver - Automated Debt Looping on Aave with Uniswap V2 Integration
 * @notice This contract automates leverage creation through debt looping
 * Executes multiple borrow-swap-deposit cycles in a single transaction
 */
 // File Version: 0.0.2 (10/12/2025)
 // - 0.0.2 (10/12): Added third party position creation.
 // - 0.0.1 (07/12): Initial Implementation. 

import "./imports/ReentrancyGuard.sol"; //Imports and inherits ownable
import "./imports/IERC20.sol";


// INLINED INTERFACES - Aave V3

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;
    
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    
    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external returns (uint256);
    
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
    
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
}

interface IAaveProtocolDataProvider {
    function getReserveConfigurationData(address asset) external view returns (
        uint256 decimals,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 reserveFactor,
        bool usageAsCollateralEnabled,
        bool borrowingEnabled,
        bool stableBorrowRateEnabled,
        bool isActive,
        bool isFrozen
    );
    
    function getUserReserveData(address asset, address user) external view returns (
        uint256 currentATokenBalance,
        uint256 currentStableDebt,
        uint256 currentVariableDebt,
        uint256 principalStableDebt,
        uint256 scaledVariableDebt,
        uint256 stableBorrowRate,
        uint256 liquidityRate,
        uint40 stableRateLastUpdated,
        bool usageAsCollateralEnabled
    );
    
    function getReserveData(address asset) external view returns (
        uint256 availableLiquidity,
        uint256 totalStableDebt,
        uint256 totalVariableDebt,
        uint256 liquidityRate,
        uint256 variableBorrowRate,
        uint256 stableBorrowRate,
        uint256 averageStableBorrowRate,
        uint256 liquidityIndex,
        uint256 variableBorrowIndex,
        uint40 lastUpdateTimestamp
    );
}

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);
}

// INLINED INTERFACES - Uniswap V2

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
    
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

// MAIN CONTRACT

contract UADriver is ReentrancyGuard {
    
    // STRUCTS FOR PREVIEW
    
    struct PreviewCache {
        uint256 collateralPrice;
        uint256 borrowPrice;
        uint256 ltvScaled;
        uint256 ltScaled;
        uint256 targetCollateralValue;
        uint256 minHealthFactor;
        uint256 initialMargin;
        uint256 targetLeverage;
    }

    struct PreviewState {
        uint256 currentCollateral;
        uint256 totalDebt;
        uint256 loops;
    }
    
    // STRUCTS FOR EXECUTION
    
    struct ExecuteCache {
        uint256 initialMargin;
        uint256 targetLeverage;
        uint256 minHealthFactor;
        uint256 maxSlippage;
        uint256 collateralPrice;
        uint256 borrowPrice;
        uint256 ltvScaled;
        uint256 ltScaled;
        uint256 targetCollateralValue;
    }

    struct ExecuteState {
        uint256 currentCollateral;
        uint256 totalDebt;
        uint256 loopCount;
    }
    
    // STATE VARIABLES
    
    IPool public immutable aavePool;
    IUniswapV2Router02 public immutable uniswapRouter;
    IAaveOracle public immutable aaveOracle;
    IAaveProtocolDataProvider public immutable dataProvider;
    IUniswapV2Factory public immutable uniswapFactory;
    
    address public immutable collateralAsset;
    address public immutable borrowAsset;
    
    // Constants
    uint256 private constant PRECISION = 1e18;
    uint256 private constant HEALTH_FACTOR_PRECISION = 1e18;
    uint256 private constant BPS_PRECISION = 1e4;
    uint256 private constant MAX_LOOPS = 10; // Safety limit
    uint256 private constant MIN_HEALTH_FACTOR = 1.05e18; // Absolute minimum (5% buffer)
    
    // Configuration
    uint256 public maxSlippageBps = 200; // 2% default
    bool public paused;

    // EVENTS
    
    event LoopExecuted(
        address indexed user,
        uint256 loopNumber,
        uint256 borrowed,
        uint256 swapped,
        uint256 collateralAdded,
        uint256 healthFactor
    );
    
    event LoopingCompleted(
        address indexed user,
        uint256 totalLoops,
        uint256 finalCollateral,
        uint256 finalDebt,
        uint256 finalHealthFactor,
        uint256 achievedLeverage
    );
    
    event LoopUnwound(
        address indexed user,
        uint256 debtRepaid,
        uint256 collateralWithdrawn,
        uint256 finalHealthFactor
    );
    
    event EmergencyWithdraw(address indexed user, address indexed asset, uint256 amount);
    
    event ConfigUpdated(uint256 maxSlippageBps);
    
    event PauseToggled(bool paused);

    // ERRORS
    
    error ContractPaused();
    error InvalidLeverage();
    error InvalidHealthFactor();
    error InsufficientLiquidity();
    error SlippageExceeded();
    error HealthFactorTooLow();
    error MaxLoopsExceeded();
    error BorrowingDisabled();
    error OracleFailure();
    error InvalidAmount();
    error TransferFailed();
    error PairDoesNotExist();
    
    // CONSTRUCTOR
    
    constructor(
        address _aavePool,
        address _uniswapRouter,
        address _uniswapFactory,
        address _aaveOracle,
        address _dataProvider,
        address _collateralAsset,
        address _borrowAsset
    ) Ownable() { // FIX 1: Removed (msg.sender)
        require(_aavePool != address(0), "Invalid pool");
        require(_uniswapRouter != address(0), "Invalid router");
        require(_uniswapFactory != address(0), "Invalid factory");
        require(_aaveOracle != address(0), "Invalid oracle");
        require(_dataProvider != address(0), "Invalid data provider");
        require(_collateralAsset != address(0), "Invalid collateral");
        require(_borrowAsset != address(0), "Invalid borrow asset");
        
        aavePool = IPool(_aavePool);
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        uniswapFactory = IUniswapV2Factory(_uniswapFactory);
        aaveOracle = IAaveOracle(_aaveOracle);
        dataProvider = IAaveProtocolDataProvider(_dataProvider);
        collateralAsset = _collateralAsset;
        borrowAsset = _borrowAsset;

        // Verify pair exists
        // FIX 2: Cast the address to the interface to access .getPair()
        address pair = IUniswapV2Factory(_uniswapFactory).getPair(_collateralAsset, _borrowAsset);
        
        if (pair == address(0)) revert PairDoesNotExist();
        
        // Approve max for gas efficiency
        IERC20(_collateralAsset).approve(_aavePool, type(uint256).max);
        IERC20(_borrowAsset).approve(_uniswapRouter, type(uint256).max);
        IERC20(_collateralAsset).approve(_uniswapRouter, type(uint256).max);
    }
    
    // MAIN EXECUTION FUNCTION
    
/**
 * @notice Execute automated debt looping on behalf of a user
 * @param onBehalfOf Address to create the position for
 * @param initialMargin Amount of collateral to deposit (in wei)
 * @param targetLeverage Desired leverage multiplier (e.g., 3e18 = 3x)
 * @param minHealthFactor Minimum acceptable health factor (e.g., 1.2e18)
 * @param maxSlippage Maximum acceptable slippage in basis points (e.g., 100 = 1%)
 */
function executeLoop(
    address onBehalfOf,
    uint256 initialMargin,
    uint256 targetLeverage,
    uint256 minHealthFactor,
    uint256 maxSlippage
) external nonReentrant {
    if (paused) revert ContractPaused();
    if (onBehalfOf == address(0)) revert InvalidAmount();
    if (initialMargin == 0) revert InvalidAmount();
    if (targetLeverage < PRECISION || targetLeverage > 10 * PRECISION) revert InvalidLeverage();
    if (minHealthFactor < MIN_HEALTH_FACTOR) revert InvalidHealthFactor();
    if (maxSlippage > maxSlippageBps) revert SlippageExceeded();

    // 1. Build Configuration Cache
    ExecuteCache memory cache = _buildExecuteCache(initialMargin, targetLeverage, minHealthFactor, maxSlippage);

    // 2. Initial Transfer (from msg.sender) and Deposit (to onBehalfOf)
    IERC20(collateralAsset).transferFrom(msg.sender, address(this), initialMargin);
    aavePool.supply(collateralAsset, initialMargin, onBehalfOf, 0);

    // 3. Initialize State
    ExecuteState memory state = ExecuteState({
        currentCollateral: initialMargin,
        totalDebt: 0,
        loopCount: 0
    });

    // 4. Execution Loop - use helper to avoid stack too deep
    _executeLoopCycles(onBehalfOf, cache, state);
    
    if (state.loopCount >= MAX_LOOPS) revert MaxLoopsExceeded();
    
    _emitCompletion(onBehalfOf, state.currentCollateral, state.totalDebt, state.loopCount, cache.minHealthFactor);
}

/**
 * @notice Internal helper to execute loop cycles (avoids stack too deep)
 */
function _executeLoopCycles(
    address onBehalfOf,
    ExecuteCache memory cache,
    ExecuteState memory state
) internal {
    while (state.loopCount < MAX_LOOPS) {
        uint256 currentVal = (state.currentCollateral * cache.collateralPrice) / PRECISION;
        
        // Break if target reached
        if (currentVal >= cache.targetCollateralValue) break;

        // Calculate Borrow Amount
        uint256 borrowAmount = _calculateLoopBorrow(cache, state, currentVal);

        // Stop if dust amount
        if (borrowAmount < 1000) break;

        // Check Liquidity availability
        uint256 liquidity = _getAvailableLiquidity(borrowAsset);
        if (borrowAmount > liquidity) borrowAmount = liquidity;

        // Execute: Borrow -> Swap -> Supply
        aavePool.borrow(borrowAsset, borrowAmount, 2, 0, onBehalfOf);
        
        // Calc minimum output for slippage
        uint256 expectedOut = _getExpectedOutput(borrowAmount);
        uint256 minAmountOut = (expectedOut * (BPS_PRECISION - cache.maxSlippage)) / BPS_PRECISION;
        
        // Swap
        uint256 collateralReceived = _swapBorrowForCollateral(borrowAmount, minAmountOut);
        
        // Supply
        aavePool.supply(collateralAsset, collateralReceived, onBehalfOf, 0);

        // Update State
        state.currentCollateral += collateralReceived;
        state.totalDebt += borrowAmount;
        state.loopCount++;

        // Safety Check
        (, , , , , uint256 healthFactor) = aavePool.getUserAccountData(onBehalfOf);
        emit LoopExecuted(onBehalfOf, state.loopCount, borrowAmount, borrowAmount, collateralReceived, healthFactor);
        
        if (healthFactor < cache.minHealthFactor) revert HealthFactorTooLow();
    }
}
    
    // HELPER: Build Configuration Cache
    function _buildExecuteCache(
        uint256 initialMargin,
        uint256 targetLeverage,
        uint256 minHealthFactor,
        uint256 maxSlippage
    ) internal view returns (ExecuteCache memory cache) {
        cache.initialMargin = initialMargin;
        cache.targetLeverage = targetLeverage;
        cache.minHealthFactor = minHealthFactor;
        cache.maxSlippage = maxSlippage;

        // Prices
        cache.collateralPrice = _getAssetPrice(collateralAsset);
        cache.borrowPrice = _getAssetPrice(borrowAsset);

        // Aave Config
        ( , uint256 ltv, uint256 liquidationThreshold, , , , bool borrowingEnabled, , bool isActive, bool isFrozen) 
            = dataProvider.getReserveConfigurationData(collateralAsset);
            
        if (!borrowingEnabled || !isActive || isFrozen) revert BorrowingDisabled();

        cache.ltvScaled = (ltv * PRECISION) / BPS_PRECISION;
        cache.ltScaled = (liquidationThreshold * PRECISION) / BPS_PRECISION;
        
        // Target Calc
        cache.targetCollateralValue = (initialMargin * targetLeverage * cache.collateralPrice) / (PRECISION * PRECISION);
    }

    // HELPER: Calculate Borrow Amount (Pure Math)
    function _calculateLoopBorrow(
        ExecuteCache memory cache, 
        ExecuteState memory state,
        uint256 currentCollateralValue
    ) internal pure returns (uint256) {
        // Max borrow based on LTV
        uint256 maxBorrowValue = (currentCollateralValue * cache.ltvScaled) / PRECISION;
        uint256 currentDebtValue = (state.totalDebt * cache.borrowPrice) / PRECISION;

        if (maxBorrowValue <= currentDebtValue) return 0;

        uint256 availableBorrowValue = maxBorrowValue - currentDebtValue;
        uint256 borrowAmount = (availableBorrowValue * PRECISION) / cache.borrowPrice;

        // Health Factor Check
        uint256 projectedDebt = state.totalDebt + borrowAmount;
        uint256 projectedDebtVal = (projectedDebt * cache.borrowPrice) / PRECISION;
        
        if (projectedDebtVal == 0) return borrowAmount;

        uint256 projectedHF = (currentCollateralValue * cache.ltScaled) / projectedDebtVal;

        if (projectedHF < cache.minHealthFactor) {
            uint256 maxDebtValue = (currentCollateralValue * cache.ltScaled) / cache.minHealthFactor;
            uint256 maxDebt = (maxDebtValue * PRECISION) / cache.borrowPrice;
            
            if (maxDebt > state.totalDebt) {
                return maxDebt - state.totalDebt;
            } else {
                return 0;
            }
        }
        return borrowAmount;
    }

    // HELPER: Get Liquidity (Avoids Tuple Stack Issues)
    function _getAvailableLiquidity(address asset) internal view returns (uint256) {
        (uint256 availableLiquidity, , , , , , , , , ) = dataProvider.getReserveData(asset);
        return availableLiquidity;
    }

// Updated (0.0.2) helper function
function _emitCompletion(
    address onBehalfOf, // Added parameter
    uint256 currentCollateral, 
    uint256 totalDebt, 
    uint256 loopCount,
    uint256 minHealthFactor
) internal {
    (uint256 totalCollateralBase, uint256 totalDebtBase, , , , uint256 finalHealthFactor) 
        = aavePool.getUserAccountData(onBehalfOf); // Changed

    if (finalHealthFactor < minHealthFactor) revert HealthFactorTooLow();
    
    uint256 achievedLeverage = totalCollateralBase > 0 
        ? (totalCollateralBase * PRECISION) / (totalCollateralBase - totalDebtBase)
        : 0; 

    emit LoopingCompleted(
        onBehalfOf, // Changed
        loopCount,
        currentCollateral,
        totalDebt,
        finalHealthFactor,
        achievedLeverage
    );
}
    
    // UNWINDING FUNCTION
    
    /**
     * @notice Unwind a leveraged position by repaying debt and withdrawing collateral
     * @param repayAmount Amount of debt to repay (0 = repay all)
     * @param withdrawAmount Amount of collateral to withdraw (0 = withdraw all available)
     * @param maxSlippage Maximum slippage tolerance in bps
     */
    function unwindLoop(
        uint256 repayAmount,
        uint256 withdrawAmount,
        uint256 maxSlippage
    ) external nonReentrant {
        if (paused) revert ContractPaused();
        
        // Get current debt
        (
            ,
            uint256 currentVariableDebt,
            ,
            ,
            ,
            ,
            ,
            ,
        ) = dataProvider.getUserReserveData(borrowAsset, msg.sender);
        
        uint256 actualRepayAmount = repayAmount == 0 ? currentVariableDebt : repayAmount;
        
        if (actualRepayAmount > 0) {
            // Calculate collateral needed for swap using Uniswap V2 getAmountsIn
            address[] memory path = new address[](2);
            path[0] = collateralAsset;
            path[1] = borrowAsset;
            
            uint256[] memory amountsIn = uniswapRouter.getAmountsIn(actualRepayAmount, path);
            uint256 collateralNeeded = amountsIn[0];
            
            // Add slippage buffer
            collateralNeeded = (collateralNeeded * (BPS_PRECISION + maxSlippage)) / BPS_PRECISION;
            
            // Withdraw collateral from Aave
            aavePool.withdraw(collateralAsset, collateralNeeded, address(this));
            
            // Swap collateral for borrow asset
            uint256 minAmountOut = (actualRepayAmount * (BPS_PRECISION - maxSlippage)) / BPS_PRECISION;
            uint256 borrowReceived = _swapCollateralForBorrow(
                collateralNeeded,
                minAmountOut
            );
            
            // Repay debt
            IERC20(borrowAsset).approve(address(aavePool), borrowReceived);
            aavePool.repay(borrowAsset, borrowReceived, 2, msg.sender);
        }
        
        // Withdraw remaining collateral if requested
        if (withdrawAmount > 0) {
            uint256 withdrawn = aavePool.withdraw(collateralAsset, withdrawAmount, msg.sender);
            
            (, , , , , uint256 finalHealthFactor) = aavePool.getUserAccountData(msg.sender);
            
            emit LoopUnwound(msg.sender, actualRepayAmount, withdrawn, finalHealthFactor);
        }
    }
    
    // INTERNAL FUNCTIONS - Uniswap V2 Swaps
    
    /**
     * @notice Swap borrowed asset for collateral asset
     */
    function _swapBorrowForCollateral(
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = borrowAsset;
        path[1] = collateralAsset;
        
        uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            block.timestamp
        );
        
        return amounts[1];
    }
    
    /**
     * @notice Swap collateral asset for borrowed asset
     */
    function _swapCollateralForBorrow(
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = collateralAsset;
        path[1] = borrowAsset;
        
        uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            block.timestamp
        );
        
        return amounts[1];
    }
    
    /**
     * @notice Get expected output for a swap using Uniswap V2 reserves
     */
    function _getExpectedOutput(uint256 amountIn) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = borrowAsset;
        path[1] = collateralAsset;
        
        uint256[] memory amounts = uniswapRouter.getAmountsOut(amountIn, path);
        return amounts[1];
    }
    
    /**
     * @notice Get expected input needed for desired output
     */
    function _getExpectedInput(uint256 amountOut) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = collateralAsset;
        path[1] = borrowAsset;
        
        uint256[] memory amounts = uniswapRouter.getAmountsIn(amountOut, path);
        return amounts[0];
    }
    
    function _getAssetPrice(address asset) internal view returns (uint256) {
        uint256 price = aaveOracle.getAssetPrice(asset);
        if (price == 0) revert OracleFailure();
        return price;
    }
    
    function _calculateExpectedSwapOutput(
        uint256 amountIn,
        uint256 priceIn,
        uint256 priceOut
    ) internal pure returns (uint256) {
        return (amountIn * priceIn) / priceOut;
    }
    
    // VIEW FUNCTIONS
    
    /**
     * @notice Preview loop execution without actually executing
     * @return estimatedLoops Number of loops required
     * @return estimatedFinalCollateral Estimated final collateral amount
     * @return estimatedFinalDebt Estimated final debt amount
     * @return estimatedHealthFactor Estimated final health factor
     */
    /**
     * @notice Preview loop execution (Refactored for Stack Too Deep)
     */
    function previewLoop(
        uint256 initialMargin,
        uint256 targetLeverage,
        uint256 minHealthFactor
    ) external view returns (
        uint256 estimatedLoops,
        uint256 estimatedFinalCollateral,
        uint256 estimatedFinalDebt,
        uint256 estimatedHealthFactor
    ) {
        // 1. Initialize Cache (Static Data)
        PreviewCache memory cache = _buildPreviewCache(initialMargin, targetLeverage, minHealthFactor);
        
        // 2. Initialize State (Dynamic Data)
        PreviewState memory state = PreviewState({
            currentCollateral: initialMargin,
            totalDebt: 0,
            loops: 0
        });

        // 3. Run Simulation Loop
        while (state.loops < MAX_LOOPS) { 
            // Calculate current value
            uint256 currentVal = (state.currentCollateral * cache.collateralPrice) / PRECISION;
            
            // Break if target reached
            if (currentVal >= cache.targetCollateralValue) break;

            // Calculate borrow amount based on LTV and HF constraints
            uint256 borrowAmount = _calculateSafeBorrow(cache, state, currentVal);

            // Stop if borrow amount is negligible
            if (borrowAmount < 1000) break;

            // Estimate Swap Output (Borrow -> Collateral)
            address[] memory path = new address[](2);
            path[0] = borrowAsset;
            path[1] = collateralAsset;
            
            // Uniswap estimation
            uint256[] memory amounts = uniswapRouter.getAmountsOut(borrowAmount, path);
            uint256 collateralReceived = amounts[1];

            // Update State
            state.currentCollateral += collateralReceived;
            state.totalDebt += borrowAmount;
            state.loops++;
        }

        return _finalizePreview(cache, state);
    }
    
    function _buildPreviewCache(
        uint256 initialMargin, 
        uint256 targetLeverage, 
        uint256 minHealthFactor
    ) internal view returns (PreviewCache memory cache) {
        cache.initialMargin = initialMargin;
        cache.targetLeverage = targetLeverage;
        cache.minHealthFactor = minHealthFactor;
        
        // Fetch Prices
        cache.collateralPrice = aaveOracle.getAssetPrice(collateralAsset);
        cache.borrowPrice = aaveOracle.getAssetPrice(borrowAsset);

        // Fetch Config
        (, uint256 ltv, uint256 liquidationThreshold, , , , , , , ) = 
            dataProvider.getReserveConfigurationData(collateralAsset);

        // Scale Config
        cache.ltvScaled = (ltv * PRECISION) / BPS_PRECISION;
        cache.ltScaled = (liquidationThreshold * PRECISION) / BPS_PRECISION;
        
        // Calculate Target
        cache.targetCollateralValue = (initialMargin * targetLeverage * cache.collateralPrice) / (PRECISION * PRECISION);
    }

    function _calculateSafeBorrow(
        PreviewCache memory cache, 
        PreviewState memory state,
        uint256 currentCollateralValue
    ) internal pure returns (uint256) {
        // 1. Max borrow based on LTV
        uint256 maxBorrowValue = (currentCollateralValue * cache.ltvScaled) / PRECISION;
        uint256 currentDebtValue = (state.totalDebt * cache.borrowPrice) / PRECISION;

        if (maxBorrowValue <= currentDebtValue) return 0;

        uint256 availableBorrowValue = maxBorrowValue - currentDebtValue;
        uint256 borrowAmount = (availableBorrowValue * PRECISION) / cache.borrowPrice;

        // 2. Health Factor Constraint Check
        uint256 projectedDebt = state.totalDebt + borrowAmount;
        uint256 projectedDebtVal = (projectedDebt * cache.borrowPrice) / PRECISION;

        // Avoid division by zero
        if (projectedDebtVal == 0) return borrowAmount;

        uint256 projectedHF = (currentCollateralValue * cache.ltScaled) / projectedDebtVal;

        if (projectedHF < cache.minHealthFactor) {
            // Recalculate to satisfy Min Health Factor
            uint256 maxSafeDebtValue = (currentCollateralValue * cache.ltScaled) / cache.minHealthFactor;
            uint256 maxSafeDebt = (maxSafeDebtValue * PRECISION) / cache.borrowPrice;
            
            if (maxSafeDebt > state.totalDebt) {
                return maxSafeDebt - state.totalDebt;
            } else {
                return 0;
            }
        }

        return borrowAmount;
    }

    function _finalizePreview(
        PreviewCache memory cache, 
        PreviewState memory state
    ) internal pure returns (uint256, uint256, uint256, uint256) {
        uint256 finalCollateralValue = (state.currentCollateral * cache.collateralPrice) / PRECISION;
        uint256 finalDebtValue = (state.totalDebt * cache.borrowPrice) / PRECISION;
        
        uint256 healthFactor = finalDebtValue > 0 
            ? (finalCollateralValue * cache.ltScaled) / finalDebtValue 
            : type(uint256).max;

        return (state.loops, state.currentCollateral, state.totalDebt, healthFactor);
    }
    
    /**
     * @notice Get current Uniswap V2 pair reserves
     */
    function getPairReserves() external view returns (
        uint112 reserve0,
        uint112 reserve1,
        uint32 blockTimestampLast,
        address token0,
        address token1
    ) {
        address pair = uniswapFactory.getPair(collateralAsset, borrowAsset);
        if (pair == address(0)) revert PairDoesNotExist();
        
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        (reserve0, reserve1, blockTimestampLast) = pairContract.getReserves();
        token0 = pairContract.token0();
        token1 = pairContract.token1();
    }
    
    /**
     * @notice Get expected swap output for quote purposes
     */
    function getSwapQuote(uint256 amountIn, bool borrowToCollateral) external view returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        
        if (borrowToCollateral) {
            path[0] = borrowAsset;
            path[1] = collateralAsset;
        } else {
            path[0] = collateralAsset;
            path[1] = borrowAsset;
        }
        
        uint256[] memory amounts = uniswapRouter.getAmountsOut(amountIn, path);
        return amounts[1];
    }
    
    // ADMIN FUNCTIONS
    
    function setMaxSlippage(uint256 _maxSlippageBps) external onlyOwner {
        require(_maxSlippageBps <= 1000, "Slippage too high"); // Max 10%
        maxSlippageBps = _maxSlippageBps;
        emit ConfigUpdated(_maxSlippageBps);
    }
    
    function togglePause() external onlyOwner {
        paused = !paused;
        emit PauseToggled(paused);
    }
    
    /**
     * @notice Emergency withdraw function for stuck funds
     */
    function emergencyWithdraw(address asset, uint256 amount) external onlyOwner {
        IERC20(asset).transfer(owner(), amount);
        emit EmergencyWithdraw(owner(), asset, amount);
    }
    
    /**
     * @notice Receive ETH (if needed for WETH operations)
     */
    receive() external payable {}
}