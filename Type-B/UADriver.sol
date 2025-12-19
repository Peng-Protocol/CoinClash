// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.20;

/**
 * @title UADriver - Automated Debt Looping (Monolithic)
 * @notice Automates leverage creation through debt looping for any valid Aave/Uniswap asset pair.
 * Executes multiple borrow-swap-deposit cycles in a single transaction.
 */
// File Version: 0.0.8 (19/12/2025)
// - 0.0.8 (19/12): Fixed collateral asset decimal precision. 
// - 0.0.7 (18/12): Accounted for "max" input during unwind. 
// - 0.0.6 (18/12): Fixed aToken withdraw amount precision for unwind. 
// - 0.0.5 (17/12): Added aToken usage for collateral management. 
// - 0.0.4 (16/12): Fixed decimal precision for wind. 
 
import "./imports/ReentrancyGuard.sol"; //Imports and inherits ownable
import "./imports/IERC20.sol";

// INLINED INTERFACES - Aave V3 (Preserved from source)
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
    function getUserAccountData(address user) external view returns (uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor);
    function setUserUseReserveAsCollateral(address asset, bool useAsCollateral) external;
}

interface IAaveProtocolDataProvider {
    function getReserveTokensAddresses(address asset) external view returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);
    function getReserveConfigurationData(address asset) external view returns (uint256 decimals, uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus, uint256 reserveFactor, bool usageAsCollateralEnabled, bool borrowingEnabled, bool stableBorrowRateEnabled, bool isActive, bool isFrozen);
    function getUserReserveData(address asset, address user) external view returns (uint256 currentATokenBalance, uint256 currentStableDebt, uint256 currentVariableDebt, uint256 principalStableDebt, uint256 scaledVariableDebt, uint256 stableBorrowRate, uint256 liquidityRate, uint40 stableRateLastUpdated, bool usageAsCollateralEnabled);
    function getReserveData(address asset) external view returns (uint256 availableLiquidity, uint256 totalStableDebt, uint256 totalVariableDebt, uint256 liquidityRate, uint256 variableBorrowRate, uint256 stableBorrowRate, uint256 averageStableBorrowRate, uint256 liquidityIndex, uint256 variableBorrowIndex, uint40 lastUpdateTimestamp);
}

interface IAaveOracle {
    function getAssetPrice(address asset) external view returns (uint256);
}

// INLINED INTERFACES - Uniswap V2 (Preserved from source)
interface IUniswapV2Router02 {
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
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
    
    // STRUCTS (Updated to include asset addresses for Monolithic support)
    
    struct PreviewCache {
        address collateralAsset;
        address borrowAsset;
        uint256 collateralAssetDecimals; // NEW (0.0.8)
        uint256 borrowAssetDecimals;     // NEW (0.0.8)
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
    
    struct ExecuteCache {
        address collateralAsset;
        address borrowAsset;
        uint256 collateralAssetDecimals; // ←NEW (0.0.8)
        uint256 borrowAssetDecimals; // <--- NEW
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
    
IPool public aavePool;
IUniswapV2Router02 public uniswapRouter;
IAaveOracle public aaveOracle;
IAaveProtocolDataProvider public dataProvider;
IUniswapV2Factory public uniswapFactory;
// REMOVED: collateralAsset and borrowAsset to allow dynamism. 
    
    // Constants
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS_PRECISION = 1e4;
    uint256 private constant MAX_LOOPS = 10;
    uint256 private constant MIN_HEALTH_FACTOR = 1.05e18; 
    
    // Configuration
    uint256 public maxSlippageBps = 200; 
    bool public paused;

    // EVENTS
    
    event LoopExecuted(address indexed user, uint256 loopNumber, uint256 borrowed, uint256 swapped, uint256 collateralAdded, uint256 healthFactor);
    event LoopingCompleted(address indexed user, uint256 totalLoops, uint256 finalCollateral, uint256 finalDebt, uint256 finalHealthFactor, uint256 achievedLeverage);
    event LoopUnwound(address indexed user, uint256 debtRepaid, uint256 collateralWithdrawn, uint256 finalHealthFactor);
    event EmergencyWithdraw(address indexed user, address indexed asset, uint256 amount);
    event ConfigUpdated(uint256 maxSlippageBps);
    event PauseToggled(bool paused);

    // ERRORS
    
    error ContractPaused();
    error InvalidLeverage();
    error InvalidHealthFactor();
    error SlippageExceeded();
    error HealthFactorTooLow();
    error MaxLoopsExceeded();
    error BorrowingDisabled();
    error OracleFailure();
    error InvalidAmount();
    error PairDoesNotExist();
    error SameAsset();

    // CONSTRUCTOR (Cleaned up parameters) [cite: 38]
    
    // CONSTRUCTOR 
    
    constructor() Ownable() {
        // No external contract addresses are set here; they are set via setter functions.
    }
    
    // ADMIN SETTER FUNCTIONS
    
    /**
     * @notice Sets the Aave Pool address
     * @param _aavePool The address of the Aave V3 Pool
     */
    function setAavePool(address _aavePool) external onlyOwner {
        require(_aavePool != address(0), "Invalid pool");
        aavePool = IPool(_aavePool);
    }
    
    /**
     * @notice Sets the Uniswap Router address
     * @param _uniswapRouter The address of the UniswapV2Router02
     */
    function setUniswapRouter(address _uniswapRouter) external onlyOwner {
        require(_uniswapRouter != address(0), "Invalid router");
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
    }

    /**
     * @notice Sets the Uniswap Factory address
     * @param _uniswapFactory The address of the UniswapV2Factory
     */
    function setUniswapFactory(address _uniswapFactory) external onlyOwner {
        require(_uniswapFactory != address(0), "Invalid factory");
        uniswapFactory = IUniswapV2Factory(_uniswapFactory);
    }

    /**
     * @notice Sets the Aave Oracle address
     * @param _aaveOracle The address of the Aave Oracle
     */
    function setAaveOracle(address _aaveOracle) external onlyOwner {
        require(_aaveOracle != address(0), "Invalid oracle");
        aaveOracle = IAaveOracle(_aaveOracle);
    }
    
    /**
     * @notice Sets the Aave Data Provider address
     * @param _dataProvider The address of the Aave Protocol Data Provider
     */
    function setDataProvider(address _dataProvider) external onlyOwner {
        require(_dataProvider != address(0), "Invalid data provider");
        dataProvider = IAaveProtocolDataProvider(_dataProvider);
    }
    
    // MAIN EXECUTION FUNCTION
    
    /**
     * @notice Execute automated debt looping on behalf of a user for a specific pair
     */
    function executeLoop(
        address collateralAsset,
        address borrowAsset,
        address onBehalfOf,
        uint256 initialMargin,
        uint256 targetLeverage,
        uint256 minHealthFactor,
        uint256 maxSlippage
    ) external nonReentrant {
        if (paused) revert ContractPaused();
        if (collateralAsset == borrowAsset) revert SameAsset();
        if (onBehalfOf == address(0)) revert InvalidAmount();
        if (initialMargin == 0) revert InvalidAmount();
        if (targetLeverage < PRECISION || targetLeverage > 10 * PRECISION) revert InvalidLeverage();
        if (minHealthFactor < MIN_HEALTH_FACTOR) revert InvalidHealthFactor();
        if (maxSlippage > maxSlippageBps) revert SlippageExceeded();

        // Check Liquidity Pair Exists
        address pair = uniswapFactory.getPair(collateralAsset, borrowAsset);
        if (pair == address(0)) revert PairDoesNotExist();

        // 1. Build Configuration Cache (includes asset addresses)
        ExecuteCache memory cache = _buildExecuteCache(collateralAsset, borrowAsset, initialMargin, targetLeverage, minHealthFactor, maxSlippage);
        
        // 2. Initial Transfer and Deposit
        IERC20(collateralAsset).transferFrom(msg.sender, address(this), initialMargin);
        
        // Dynamic Approval: Approve Aave to spend collateral 
        _approveIfNeeded(collateralAsset, address(aavePool), initialMargin);
        
        aavePool.supply(collateralAsset, initialMargin, onBehalfOf, 0);

        // 3. Initialize State
        ExecuteState memory state = ExecuteState({
            currentCollateral: initialMargin,
            totalDebt: 0,
            loopCount: 0
        });

        // 4. Execution Loop
        _executeLoopCycles(onBehalfOf, cache, state);
        
        if (state.loopCount >= MAX_LOOPS) revert MaxLoopsExceeded();
        
        _emitCompletion(onBehalfOf, state.currentCollateral, state.totalDebt, state.loopCount, cache.minHealthFactor);
    }

    /**
     * @notice Internal helper to execute loop cycles
     */
    function _executeLoopCycles(
    address onBehalfOf,
    ExecuteCache memory cache,
    ExecuteState memory state
) internal {
    while (state.loopCount < MAX_LOOPS) {
        // FIX: Normalize collateral value to 18 decimals using specific decimals
        // This ensures it matches the 18-decimal debt value calculated later
        uint256 currentVal = (state.currentCollateral * cache.collateralPrice) / (10 ** cache.collateralAssetDecimals);

        if (currentVal >= cache.targetCollateralValue) break;

        uint256 borrowAmount = _calculateLoopBorrow(cache, state, currentVal);

        if (borrowAmount < 1000) break;

        uint256 liquidity = _getAvailableLiquidity(cache.borrowAsset);
        if (borrowAmount > liquidity) borrowAmount = liquidity;

        aavePool.borrow(cache.borrowAsset, borrowAmount, 2, 0, onBehalfOf);
        _approveIfNeeded(cache.borrowAsset, address(uniswapRouter), borrowAmount);

        uint256 expectedOut = _getExpectedOutput(cache.borrowAsset, cache.collateralAsset, borrowAmount);
        uint256 minAmountOut = (expectedOut * (BPS_PRECISION - cache.maxSlippage)) / BPS_PRECISION;

        uint256 collateralReceived = _swapBorrowForCollateral(cache.borrowAsset, cache.collateralAsset, borrowAmount, minAmountOut);
        _approveIfNeeded(cache.collateralAsset, address(aavePool), collateralReceived);
        aavePool.supply(cache.collateralAsset, collateralReceived, onBehalfOf, 0);

        state.currentCollateral += collateralReceived;
        state.totalDebt += borrowAmount;
        state.loopCount++;

        (, , , , , uint256 healthFactor) = aavePool.getUserAccountData(onBehalfOf);
        emit LoopExecuted(onBehalfOf, state.loopCount, borrowAmount, borrowAmount, collateralReceived, healthFactor);
        
        if (healthFactor < cache.minHealthFactor) revert HealthFactorTooLow();
    }
}
    
    // HELPER: Build Configuration Cache
    function _buildExecuteCache(
    address collateralAsset,
    address borrowAsset,
    uint256 initialMargin,
    uint256 targetLeverage,
    uint256 minHealthFactor,
    uint256 maxSlippage
) internal view returns (ExecuteCache memory cache) {
    cache.collateralAsset = collateralAsset;
    cache.borrowAsset = borrowAsset;
    cache.initialMargin = initialMargin;
    cache.targetLeverage = targetLeverage;
    cache.minHealthFactor = minHealthFactor;
    cache.maxSlippage = maxSlippage;

    cache.collateralPrice = _getAssetPrice(collateralAsset);
    cache.borrowPrice = _getAssetPrice(borrowAsset);

    // FETCH AND STORE DECIMALS
    (uint256 colDecimals, uint256 ltv, uint256 liquidationThreshold, , , , bool borrowingEnabled, , bool isActive, bool isFrozen) 
        = dataProvider.getReserveConfigurationData(collateralAsset);
    if (!borrowingEnabled || !isActive || isFrozen) revert BorrowingDisabled();
    
    cache.collateralAssetDecimals = colDecimals; // New field in struct

    (uint256 borrowDecimals, , , , , , , , , ) 
        = dataProvider.getReserveConfigurationData(borrowAsset);
    cache.borrowAssetDecimals = borrowDecimals;

    cache.ltvScaled = (ltv * PRECISION) / BPS_PRECISION;
    cache.ltScaled = (liquidationThreshold * PRECISION) / BPS_PRECISION;
    
    // NORMALIZE TARGET TO 18 DECIMALS
    // (Margin * Price) / 10^Decimals
    uint256 marginValue = (initialMargin * cache.collateralPrice) / (10 ** colDecimals);
    cache.targetCollateralValue = (marginValue * targetLeverage) / PRECISION;
}

// HELPER: Calculate Borrow Amount (Math Engine)
    function _calculateLoopBorrow(
        ExecuteCache memory cache, 
        ExecuteState memory state,
        uint256 currentCollateralValue
    ) internal pure returns (uint256) {
        // currentCollateralValue is passed in as 18 decimals
        uint256 maxBorrowValue = (currentCollateralValue * cache.ltvScaled) / PRECISION;
        
        // Convert current debt (Token Units) to Value ($ 18 decimals) using specific decimals
        uint256 currentDebtValue = (state.totalDebt * cache.borrowPrice) / (10 ** cache.borrowAssetDecimals);

        if (maxBorrowValue <= currentDebtValue) return 0;

        uint256 availableBorrowValue = maxBorrowValue - currentDebtValue;
        
        // Convert Value ($) to Borrow Amount (Token Units)
        uint256 borrowAmount = (availableBorrowValue * (10 ** cache.borrowAssetDecimals)) / cache.borrowPrice;
        
        uint256 projectedDebt = state.totalDebt + borrowAmount;
        
        // Recalculate Projected Debt Value for Health Factor check
        uint256 projectedDebtVal = (projectedDebt * cache.borrowPrice) / (10 ** cache.borrowAssetDecimals);
        
        if (projectedDebtVal == 0) return borrowAmount;
        
        uint256 projectedHF = (currentCollateralValue * cache.ltScaled) / projectedDebtVal;
        
        if (projectedHF < cache.minHealthFactor) {
            uint256 maxDebtValue = (currentCollateralValue * cache.ltScaled) / cache.minHealthFactor;
            
            // Convert Max Debt Value back to Token Units
            uint256 maxDebt = (maxDebtValue * (10 ** cache.borrowAssetDecimals)) / cache.borrowPrice;
            
            if (maxDebt > state.totalDebt) {
                return maxDebt - state.totalDebt;
            } else {
                return 0;
            }
        }
        return borrowAmount;
    }

    function _getAvailableLiquidity(address asset) internal view returns (uint256) {
        (uint256 availableLiquidity, , , , , , , , , ) = dataProvider.getReserveData(asset);
        return availableLiquidity;
    }

    function _emitCompletion(
        address onBehalfOf,
        uint256 currentCollateral, 
        uint256 totalDebt, 
        uint256 loopCount,
        uint256 minHealthFactor
    ) internal {
        (uint256 totalCollateralBase, uint256 totalDebtBase, , , , uint256 finalHealthFactor) 
            = aavePool.getUserAccountData(onBehalfOf);

        if (finalHealthFactor < minHealthFactor) revert HealthFactorTooLow();
        
        uint256 achievedLeverage = totalCollateralBase > 0 
            ? (totalCollateralBase * PRECISION) / (totalCollateralBase - totalDebtBase)
            : 0;
            
        emit LoopingCompleted(onBehalfOf, loopCount, currentCollateral, totalDebt, finalHealthFactor, achievedLeverage);
    }
    
    // UNWINDING FUNCTION
    
/**
     * @notice Unwind a leveraged position
     * (0.0.6): Resolves type(uint256).max to actual balances to prevent arithmetic panics.
     */
    function unwindLoop(
        address collateralAsset,
        address borrowAsset,
        uint256 repayAmount,
        uint256 withdrawAmount,
        uint256 maxSlippage
    ) external nonReentrant {
        if (paused) revert ContractPaused();
        
        // 1. Resolve aToken address and user balance
        (address aTokenAddress, , ) = dataProvider.getReserveTokensAddresses(collateralAsset);
        uint256 userATokenBal = IERC20(aTokenAddress).balanceOf(msg.sender);

        // 2. Handle Repayment Phase
        uint256 totalRepaid = 0;
        if (repayAmount > 0 && userATokenBal > 0) {
            // Get actual debt to avoid passing max to Uniswap
            ( , , uint256 currentDebt, , , , , , ) = dataProvider.getUserReserveData(borrowAsset, msg.sender);
            uint256 actualRepay = (repayAmount == type(uint256).max || repayAmount > currentDebt) ? currentDebt : repayAmount;

            if (actualRepay > 0) {
                address[] memory path = new address[](2);
                path[0] = collateralAsset;
                path[1] = borrowAsset;
                
                uint256[] memory amountsIn = uniswapRouter.getAmountsIn(actualRepay, path);
                uint256 collateralNeeded = (amountsIn[0] * (BPS_PRECISION + maxSlippage)) / BPS_PRECISION;
                
                // Safety cap to user balance
                if (collateralNeeded > userATokenBal) collateralNeeded = userATokenBal;

                // Move aTokens to driver to perform withdrawal
                IERC20(aTokenAddress).transferFrom(msg.sender, address(this), collateralNeeded);
                aavePool.withdraw(collateralAsset, collateralNeeded, address(this));
                
                _approveIfNeeded(collateralAsset, address(uniswapRouter), collateralNeeded);
                uint256 borrowReceived = _swapCollateralForBorrow(collateralAsset, borrowAsset, collateralNeeded, 0);
                
                _approveIfNeeded(borrowAsset, address(aavePool), borrowReceived);
                totalRepaid = aavePool.repay(borrowAsset, borrowReceived, 2, msg.sender);
                
                // Update tracked balance
                userATokenBal = IERC20(aTokenAddress).balanceOf(msg.sender);
            }
        }

        // 3. Handle Remaining Withdrawal Phase
        if (withdrawAmount > 0 && userATokenBal > 0) {
            uint256 actualWithdraw = (withdrawAmount == type(uint256).max || withdrawAmount > userATokenBal) 
                ? userATokenBal 
                : withdrawAmount;

            IERC20(aTokenAddress).transferFrom(msg.sender, address(this), actualWithdraw);
            uint256 withdrawn = aavePool.withdraw(collateralAsset, actualWithdraw, msg.sender);
            
            (, , , , , uint256 hf) = aavePool.getUserAccountData(msg.sender);
            emit LoopUnwound(msg.sender, totalRepaid, withdrawn, hf);
        }
    }
    
    // INTERNAL FUNCTIONS - Uniswap V2 Swaps (Refactored to accept assets)
    
    function _swapBorrowForCollateral(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = assetIn;
        path[1] = assetOut;
        
        uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            block.timestamp
        );
        return amounts[1];
    }
    
    function _swapCollateralForBorrow(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = assetIn;
        path[1] = assetOut;
        
        uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            block.timestamp
        );
        return amounts[1];
    }
    
    function _getExpectedOutput(address tokenIn, address tokenOut, uint256 amountIn) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint256[] memory amounts = uniswapRouter.getAmountsOut(amountIn, path);
        return amounts[1];
    }
    
    function _getAssetPrice(address asset) internal view returns (uint256) {
        uint256 price = aaveOracle.getAssetPrice(asset);
        if (price == 0) revert OracleFailure();
        return price;
    }
    
    // NEW: Dynamic Approval Helper
    function _approveIfNeeded(address token, address spender, uint256 amount) internal {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (allowance < amount) {
            // Approve max to save gas on future calls for this pair
            IERC20(token).approve(spender, type(uint256).max);
        }
    }
    
    // VIEW FUNCTIONS
    
    /**
     * @notice Preview loop execution
     */
    function previewLoop(
        address collateralAsset,
        address borrowAsset,
        uint256 initialMargin,
        uint256 targetLeverage,
        uint256 minHealthFactor
    ) external view returns (
        uint256 estimatedLoops,
        uint256 estimatedFinalCollateral,
        uint256 estimatedFinalDebt,
        uint256 estimatedHealthFactor
    ) {
        // 1. Initialize Cache
        PreviewCache memory cache = _buildPreviewCache(collateralAsset, borrowAsset, initialMargin, targetLeverage, minHealthFactor);
        // 2. Initialize State
        PreviewState memory state = PreviewState({
            currentCollateral: initialMargin,
            totalDebt: 0,
            loops: 0
        });
        // 3. Run Simulation
        while (state.loops < MAX_LOOPS) { 
            // FIX: Use specific decimals
            uint256 currentVal = (state.currentCollateral * cache.collateralPrice) / (10 ** cache.collateralAssetDecimals);
            
            if (currentVal >= cache.targetCollateralValue) break;

            uint256 borrowAmount = _calculateSafeBorrow(cache, state, currentVal);
            if (borrowAmount < 1000) break;
            
            address[] memory path = new address[](2);
            path[0] = borrowAsset;
            path[1] = collateralAsset;
            
            uint256[] memory amounts = uniswapRouter.getAmountsOut(borrowAmount, path);
            uint256 collateralReceived = amounts[1];

            state.currentCollateral += collateralReceived;
            state.totalDebt += borrowAmount;
            state.loops++;
        }

        return _finalizePreview(cache, state);
    }
    
    function _buildPreviewCache(
        address collateralAsset,
        address borrowAsset,
        uint256 initialMargin, 
        uint256 targetLeverage, 
        uint256 minHealthFactor
    ) internal view returns (PreviewCache memory cache) {
        cache.collateralAsset = collateralAsset;
        cache.borrowAsset = borrowAsset;
        cache.initialMargin = initialMargin;
        cache.targetLeverage = targetLeverage;
        cache.minHealthFactor = minHealthFactor;
        
        cache.collateralPrice = aaveOracle.getAssetPrice(collateralAsset);
        cache.borrowPrice = aaveOracle.getAssetPrice(borrowAsset);
        
        (uint256 colDec, uint256 ltv, uint256 liquidationThreshold, , , , , , , ) = 
            dataProvider.getReserveConfigurationData(collateralAsset);
        cache.collateralAssetDecimals = colDec; // NEW

        (uint256 borDec, , , , , , , , , ) = 
            dataProvider.getReserveConfigurationData(borrowAsset);
        cache.borrowAssetDecimals = borDec;     // NEW

        cache.ltvScaled = (ltv * PRECISION) / BPS_PRECISION;
        cache.ltScaled = (liquidationThreshold * PRECISION) / BPS_PRECISION;
        
        // Normalize Initial Margin to Value (18 decimals)
        uint256 marginValue = (initialMargin * cache.collateralPrice) / (10 ** colDec);
        cache.targetCollateralValue = (marginValue * targetLeverage) / PRECISION;
    }

    function _calculateSafeBorrow(
        PreviewCache memory cache, 
        PreviewState memory state,
        uint256 currentCollateralValue
    ) internal pure returns (uint256) {
        uint256 maxBorrowValue = (currentCollateralValue * cache.ltvScaled) / PRECISION;
        
        // FIX: Use specific decimals instead of PRECISION
        uint256 currentDebtValue = (state.totalDebt * cache.borrowPrice) / (10 ** cache.borrowAssetDecimals);

        if (maxBorrowValue <= currentDebtValue) return 0;

        uint256 availableBorrowValue = maxBorrowValue - currentDebtValue;
        
        // FIX: Use specific decimals instead of PRECISION
        uint256 borrowAmount = (availableBorrowValue * (10 ** cache.borrowAssetDecimals)) / cache.borrowPrice;

        uint256 projectedDebt = state.totalDebt + borrowAmount;
        
        // FIX: Use specific decimals instead of PRECISION
        uint256 projectedDebtVal = (projectedDebt * cache.borrowPrice) / (10 ** cache.borrowAssetDecimals);

        if (projectedDebtVal == 0) return borrowAmount;
        uint256 projectedHF = (currentCollateralValue * cache.ltScaled) / projectedDebtVal;

        if (projectedHF < cache.minHealthFactor) {
            uint256 maxSafeDebtValue = (currentCollateralValue * cache.ltScaled) / cache.minHealthFactor;
            
            // FIX: Use specific decimals instead of PRECISION
            uint256 maxSafeDebt = (maxSafeDebtValue * (10 ** cache.borrowAssetDecimals)) / cache.borrowPrice;
            
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
        // FIX: Use specific decimals instead of PRECISION
        uint256 finalCollateralValue = (state.currentCollateral * cache.collateralPrice) / (10 ** cache.collateralAssetDecimals);
        uint256 finalDebtValue = (state.totalDebt * cache.borrowPrice) / (10 ** cache.borrowAssetDecimals);
        
        uint256 healthFactor = finalDebtValue > 0 
            ? (finalCollateralValue * cache.ltScaled) / finalDebtValue 
            : type(uint256).max;
            
        return (state.loops, state.currentCollateral, state.totalDebt, healthFactor);
    }
    
    /**
     * @notice Get reserves for any valid pair
     */
    function getPairReserves(address tokenA, address tokenB) external view returns (
        uint112 reserve0,
        uint112 reserve1,
        uint32 blockTimestampLast,
        address token0,
        address token1
    ) {
        address pair = uniswapFactory.getPair(tokenA, tokenB);
        if (pair == address(0)) revert PairDoesNotExist();
        
        IUniswapV2Pair pairContract = IUniswapV2Pair(pair);
        (reserve0, reserve1, blockTimestampLast) = pairContract.getReserves();
        token0 = pairContract.token0();
        token1 = pairContract.token1();
    }
    
    /**
     * @notice Get swap quote
     */
    function getSwapQuote(
        address tokenIn, 
        address tokenOut, 
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint256[] memory amounts = uniswapRouter.getAmountsOut(amountIn, path);
        return amounts[1];
    }
    
    // ADMIN FUNCTIONS (Unchanged logic)
    
    function setMaxSlippage(uint256 _maxSlippageBps) external onlyOwner {
        require(_maxSlippageBps <= 1000, "Slippage too high");
        maxSlippageBps = _maxSlippageBps;
        emit ConfigUpdated(_maxSlippageBps);
    }
    
    function togglePause() external onlyOwner {
        paused = !paused;
        emit PauseToggled(paused);
    }
    
    receive() external payable {}
}