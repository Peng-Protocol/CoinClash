// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.20;

import "./imports/ReentrancyGuard.sol"; //Imports and inherits Ownable 
import "./imports/IERC20.sol";

// =============================================================
// EULER V2 INTERFACES
// =============================================================

interface IEVC {
    function isOperator(address owner, address operator) external view returns (bool);
    function enableController(address owner, address vault) external;
    function enableCollateral(address owner, address vault) external;
}

interface IEVault {
    function asset() external view returns (address);
    function decimals() external view returns (uint8);
    function deposit(uint256 amount, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function borrow(uint256 assets, address receiver) external returns (uint256 debt);
    function repay(uint256 assets, address receiver) external returns (uint256 debt);
    function totalAssets() external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function convertToShares(uint256 assets) external view returns (uint256);
    
    // Configuration Views (Generic Adaptation)
    function ltv() external view returns (uint16); // Scaled by 1e4 usually, or specific Euler scale
    function liquidationThreshold() external view returns (uint16);
}

interface IPriceOracle {
    function getPrice(address asset) external view returns (uint256);
}

// =============================================================
// UNISWAP V2 INTERFACES (Preserved)
// =============================================================

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

// =============================================================
// MAIN CONTRACT: UEDriver
// =============================================================

/**
 * @title UEDriver - Automated Debt Looping (Euler V2 Modular)
 * @notice Automates leverage creation through debt looping for isolated Euler Vaults.
 * @dev Replaced Aave Monolithic Pool with Euler Vault/EVC architecture.
 * NOTE: This contract relies on the user performing a delegatecall OR being an EVC Operator 
 * to attribute debt correctly to the user.
 */
contract UEDriver is ReentrancyGuard {
    
    // STRUCTS 
    
    struct ExecuteCache {
        address collateralVault;
        address borrowVault;
        address collateralAsset;
        address borrowAsset;
        uint256 collateralDecimals;
        uint256 borrowDecimals;
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
        uint256 currentCollateral; // In Asset Terms
        uint256 totalDebt;         // In Asset Terms
        uint256 loopCount;
    }
    
    // STATE VARIABLES
    
    IEVC public evc;
    IUniswapV2Router02 public uniswapRouter;
    IUniswapV2Factory public uniswapFactory;
    IPriceOracle public oracle; // External Oracle for loop calculations

    // Constants
    uint256 private constant PRECISION = 1e18;
    uint256 private constant BPS_PRECISION = 1e4;
    uint256 private constant MAX_LOOPS = 10;
    
    // Configuration
    uint256 public maxSlippageBps = 200; 
    bool public paused;

    // EVENTS
    
    event LoopExecuted(address indexed user, uint256 loopNumber, uint256 borrowed, uint256 swapped, uint256 collateralAdded);
    event LoopingCompleted(address indexed user, uint256 totalLoops, uint256 finalCollateral, uint256 finalDebt, uint256 achievedLeverage);
    event LoopUnwound(address indexed user, uint256 debtRepaid, uint256 collateralWithdrawn);
    event ConfigUpdated(uint256 maxSlippageBps);
    event PauseToggled(bool paused);

    // ERRORS
    
    error ContractPaused();
    error InvalidLeverage();
    error SlippageExceeded();
    error HealthFactorTooLow();
    error MaxLoopsExceeded();
    error OracleFailure();
    error InvalidAmount();
    error PairDoesNotExist();
    error SameAsset();
    error InvalidVault();

    // CONSTRUCTOR
    
    constructor() Ownable() {
        // Initialization via setters
    }
    
    // ADMIN SETTER FUNCTIONS
    
    function setEVC(address _evc) external onlyOwner {
        require(_evc != address(0), "Invalid EVC");
        evc = IEVC(_evc);
    }
    
    function setUniswapRouter(address _router) external onlyOwner {
        require(_router != address(0), "Invalid router");
        uniswapRouter = IUniswapV2Router02(_router);
    }

    function setUniswapFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "Invalid factory");
        uniswapFactory = IUniswapV2Factory(_factory);
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "Invalid oracle");
        oracle = IPriceOracle(_oracle);
    }
    
    // MAIN EXECUTION FUNCTION
    
    /**
     * @notice Execute automated debt looping for specific Euler Vaults
     * @param collateralVault The Euler Vault address for the collateral asset
     * @param borrowVault The Euler Vault address for the debt asset
     */
    function executeLoop(
        address collateralVault,
        address borrowVault,
        uint256 initialMargin,
        uint256 targetLeverage,
        uint256 minHealthFactor,
        uint256 maxSlippage
    ) external nonReentrant {
        if (paused) revert ContractPaused();
        if (collateralVault == borrowVault) revert SameAsset();
        if (initialMargin == 0) revert InvalidAmount();
        if (targetLeverage < PRECISION || targetLeverage > 10 * PRECISION) revert InvalidLeverage();
        if (maxSlippage > maxSlippageBps) revert SlippageExceeded();

        // 1. Build Configuration Cache
        // Fetches asset addresses from Vaults and decimals
        ExecuteCache memory cache = _buildExecuteCache(collateralVault, borrowVault, initialMargin, targetLeverage, minHealthFactor, maxSlippage);

        // Check Liquidity Pair Exists
        address pair = uniswapFactory.getPair(cache.collateralAsset, cache.borrowAsset);
        if (pair == address(0)) revert PairDoesNotExist();

        // 2. Initial Transfer and Deposit
        IERC20(cache.collateralAsset).transferFrom(msg.sender, address(this), initialMargin);
        
        // Approve Collateral Vault
        _approveIfNeeded(cache.collateralAsset, collateralVault, initialMargin);
        
        // Deposit into Euler Vault
        // Note: Receiver is msg.sender (User) to establish base position
        IEVault(collateralVault).deposit(initialMargin, msg.sender);

        // 3. Initialize State
        ExecuteState memory state = ExecuteState({
            currentCollateral: initialMargin,
            totalDebt: 0,
            loopCount: 0
        });

        // 4. Execution Loop
        _executeLoopCycles(msg.sender, cache, state);
        
        if (state.loopCount >= MAX_LOOPS) revert MaxLoopsExceeded();
        
        _emitCompletion(msg.sender, state.currentCollateral, state.totalDebt, state.loopCount);
    }

    /**
     * @notice Internal helper to execute loop cycles
     *      */
    function _executeLoopCycles(
        address user,
        ExecuteCache memory cache,
        ExecuteState memory state
    ) internal {
        while (state.loopCount < MAX_LOOPS) {
            // Normalize collateral value to 18 decimals using specific decimals
            uint256 currentVal = (state.currentCollateral * cache.collateralPrice) / (10 ** cache.collateralDecimals);

            if (currentVal >= cache.targetCollateralValue) break;

            // Calculate borrow based on Euler Vault LTV logic
            uint256 borrowAmount = _calculateLoopBorrow(cache, state, currentVal);

            if (borrowAmount < 1000) break;

            // Execute Borrow
            // NOTE: In standard Euler V2, msg.sender takes the debt. 
            // If this contract is not executed via delegatecall, the Driver takes the debt.
            // For this implementation, we assume the Driver manages the cycle or user uses delegatecall.
            // Using address(this) as receiver to perform swap.
            
            IEVault(cache.borrowVault).borrow(borrowAmount, address(this));

            // Swap Borrowed Asset -> Collateral Asset
            _approveIfNeeded(cache.borrowAsset, address(uniswapRouter), borrowAmount);
            
            uint256 expectedOut = _getExpectedOutput(cache.borrowAsset, cache.collateralAsset, borrowAmount);
            uint256 minAmountOut = (expectedOut * (BPS_PRECISION - cache.maxSlippage)) / BPS_PRECISION;
            
            uint256 collateralReceived = _swapBorrowForCollateral(cache.borrowAsset, cache.collateralAsset, borrowAmount, minAmountOut);

            // Deposit new collateral for user
            _approveIfNeeded(cache.collateralAsset, cache.collateralVault, collateralReceived);
            IEVault(cache.collateralVault).deposit(collateralReceived, user);

            state.currentCollateral += collateralReceived;
            state.totalDebt += borrowAmount;
            state.loopCount++;

            emit LoopExecuted(user, state.loopCount, borrowAmount, borrowAmount, collateralReceived);
        }
    }
    
    // HELPER: Build Configuration Cache
    function _buildExecuteCache(
        address collateralVault,
        address borrowVault,
        uint256 initialMargin,
        uint256 targetLeverage,
        uint256 minHealthFactor,
        uint256 maxSlippage
    ) internal view returns (ExecuteCache memory cache) {
        cache.collateralVault = collateralVault;
        cache.borrowVault = borrowVault;
        
        // Fetch underlying assets from Vaults
        cache.collateralAsset = IEVault(collateralVault).asset();
        cache.borrowAsset = IEVault(borrowVault).asset();
        
        cache.initialMargin = initialMargin;
        cache.targetLeverage = targetLeverage;
        cache.minHealthFactor = minHealthFactor;
        cache.maxSlippage = maxSlippage;

        // Fetch Prices via external Oracle adapter
        cache.collateralPrice = oracle.getPrice(cache.collateralAsset);
        cache.borrowPrice = oracle.getPrice(cache.borrowAsset);

        // Fetch Decimals directly from Vault
        cache.collateralDecimals = IEVault(collateralVault).decimals();
        cache.borrowDecimals = IEVault(borrowVault).decimals();

        // Fetch LTV from Vault Config
        // NOTE: Euler V2 LTV is vault-specific
        uint256 ltv = uint256(IEVault(collateralVault).ltv());
        uint256 liqThreshold = uint256(IEVault(collateralVault).liquidationThreshold());

        cache.ltvScaled = (ltv * PRECISION) / BPS_PRECISION;
        cache.ltScaled = (liqThreshold * PRECISION) / BPS_PRECISION;

        // Normalize Target
        uint256 marginValue = (initialMargin * cache.collateralPrice) / (10 ** cache.collateralDecimals);
        cache.targetCollateralValue = (marginValue * targetLeverage) / PRECISION;
    }

    // HELPER: Calculate Borrow Amount (Euler Adapted Math Engine)
    function _calculateLoopBorrow(
        ExecuteCache memory cache, 
        ExecuteState memory state,
        uint256 currentCollateralValue
    ) internal pure returns (uint256) {
        // 1. Calculate Max Borrow Value ($) based on Vault LTV
        uint256 maxBorrowValue = (currentCollateralValue * cache.ltvScaled) / PRECISION;

        // 2. Convert current debt to Value ($)
        uint256 currentDebtValue = (state.totalDebt * cache.borrowPrice) / (10 ** cache.borrowDecimals);

        if (maxBorrowValue <= currentDebtValue) return 0;

        uint256 availableBorrowValue = maxBorrowValue - currentDebtValue;

        // 3. Convert Available Value ($) to Token Units
        uint256 borrowAmount = (availableBorrowValue * (10 ** cache.borrowDecimals)) / cache.borrowPrice;

        // 4. Health Check Simulation
        uint256 projectedDebt = state.totalDebt + borrowAmount;
        uint256 projectedDebtVal = (projectedDebt * cache.borrowPrice) / (10 ** cache.borrowDecimals);
        
        if (projectedDebtVal == 0) return borrowAmount;
        
        uint256 projectedHF = (currentCollateralValue * cache.ltScaled) / projectedDebtVal;

        if (projectedHF < cache.minHealthFactor) {
            uint256 maxDebtValue = (currentCollateralValue * cache.ltScaled) / cache.minHealthFactor;
            uint256 maxDebt = (maxDebtValue * (10 ** cache.borrowDecimals)) / cache.borrowPrice;
            
            if (maxDebt > state.totalDebt) {
                return maxDebt - state.totalDebt;
            } else {
                return 0;
            }
        }
        return borrowAmount;
    }

    function _emitCompletion(
        address user,
        uint256 currentCollateral, 
        uint256 totalDebt, 
        uint256 loopCount
    ) internal {
        uint256 achievedLeverage = currentCollateral > 0 
            ? (currentCollateral * PRECISION) / (currentCollateral - ((totalDebt * 10**18) / 10**18)) // Simplified for emission
            : 0;
            
        emit LoopingCompleted(user, loopCount, currentCollateral, totalDebt, achievedLeverage);
    }
    
    // UNWINDING FUNCTION (Euler Adapted)
    
    /**
     * @notice Unwind a leveraged position from Euler Vaults
     */
    function unwindLoop(
        address collateralVault,
        address borrowVault,
        uint256 repayAmount,
        uint256 withdrawAmount,
        uint256 maxSlippage
    ) external nonReentrant {
        if (paused) revert ContractPaused();
        
        address collateralAsset = IEVault(collateralVault).asset();
        address borrowAsset = IEVault(borrowVault).asset();

        // 1. Handle Repayment
        // In Euler, shares represent the deposit. 
        // We assume msg.sender has approved this contract to pull shares or assets if needed.
        // For repayment, we need the user to transfer Collateral Shares or Assets to us to swap?
        // Simpler: User sends Underlying Collateral to swap for Repayment.
        
        // NOTE: This implementation assumes the standard "Flash Unwind" pattern where
        // we pull collateral, swap to debt, and repay.
        
        uint256 userColBal = IEVault(collateralVault).convertToAssets(IERC20(collateralVault).balanceOf(msg.sender));
        
        if (repayAmount > 0 && userColBal > 0) {
            // Swap logic mirrors UADriver but interacts with Vaults
            // 1. Pull Collateral (Withdraw from Vault)
            // Note: Requires approval on Vault shares
             uint256 assetsToPull = repayAmount; // Simplified estimation
             
             // Transfer Shares from user (Shares = Vault Token)
             uint256 sharesToPull = IEVault(collateralVault).convertToShares(assetsToPull);
             IERC20(collateralVault).transferFrom(msg.sender, address(this), sharesToPull);
             
             // Withdraw Underlying
             uint256 withdrawnCol = IEVault(collateralVault).withdraw(assetsToPull, address(this), address(this));
             
             // Swap Collateral -> Borrow Asset
             _approveIfNeeded(collateralAsset, address(uniswapRouter), withdrawnCol);
             uint256 borrowReceived = _swapCollateralForBorrow(collateralAsset, borrowAsset, withdrawnCol, 0);
             
             // Repay Debt on behalf of user
             _approveIfNeeded(borrowAsset, borrowVault, borrowReceived);
             // Note: Euler repayment credits the 'receiver' (account holding debt)
             IEVault(borrowVault).repay(borrowReceived, msg.sender);
             
             emit LoopUnwound(msg.sender, borrowReceived, withdrawnCol);
        }
    }
    
    // INTERNAL FUNCTIONS - Uniswap V2 Swaps
    
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
    
    function _approveIfNeeded(address token, address spender, uint256 amount) internal {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (allowance < amount) {
            IERC20(token).approve(spender, type(uint256).max);
        }
    }

    // ADMIN FUNCTIONS
    
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