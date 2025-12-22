// SPDX-License-Identifier: BSL 1.1
pragma solidity ^0.8.20;

// File Version : 0.0.6 (21/12/2025)
// - 0.0.6 (21/12): Reduced leverage in p2. 
// - 0.0.5 (18/12): Added profit check in 1_4. 
// - 0.0.4 (18/12): Added aToken allowance to driver in 1_4. 
// - 0.0.3 (17/12): Added aToken implementation for realistic collateral management. 
// - 0.0.2 (16/12): Improved debugging of external calls with try/catch and error decoding. 

// INTERFACES
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

    function transferOwnership(address newOwner) external;
}

interface IMockDeployer {
    function token18() external view returns (address);
    function token6() external view returns (address);
    function weth() external view returns (address);
    function uniRouter() external view returns (address);
    function aavePool() external view returns (address);
    function aaveOracle() external view returns (address);
    function driver() external view returns (address);
    function aaveDataProvider() external view returns (address);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

interface IMockAaveOracle {
    function setAssetPrice(address asset, uint256 price) external;
}

interface IMockUniRouter {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

interface IMockAavePool {
    function aTokens(address asset) external view returns (address); // Added this (0.0.3)
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
    function userCollateral(address user, address asset) external view returns (uint256);
}

interface IAavePoolDataProvider {
    function getReserveTokensAddresses(address asset) external view returns (
        address aTokenAddress, 
        address stableDebtTokenAddress, 
        address variableDebtTokenAddress
    );
}

contract LoopTests {
    // STATE
    IUADriver public driver;
    IMockDeployer public deployer;
    IAavePoolDataProvider public dataProvider; // (0.0.4)
    
    // CACHED ADDRESSES
    address public weth; // Token18 (Collateral for Long)
    address public usdt; // Token6 (Borrow for Long)
    address public aavePool;
    address public aaveOracle;
    address public uniRouter;
    
    address public owner;

    // EVENTS
    event TestLog(string message, uint256 value);
    event SetupCompleted(address deployer, address driver);
    // NEW: Debug Event to capture revert reasons
    event DebugError(string reason, bytes lowLevelData);

    constructor() {
        owner = msg.sender;
    }

    // ============ SETUP FUNCTIONS ============

    function setDeployer(address _deployer) external {
        require(msg.sender == owner, "Auth");
        deployer = IMockDeployer(_deployer);
        
        // Load mocks from the deployer
        weth = deployer.token18();
        usdt = deployer.token6();
        aavePool = deployer.aavePool();
        aaveOracle = deployer.aaveOracle();
        uniRouter = deployer.uniRouter();
        
        // Fetch driver address from deployer
        driver = IUADriver(deployer.driver());
        emit SetupCompleted(address(deployer), address(driver));
    }

    // ============ PATH 1: 2x LONG STRATEGY ============
    // Objective: Long ETH (WETH) using USDT debt.
    // Initial: 10 ETH. Target: 2x Leverage ($40k Exposure).

    function p1_1_PrepareFunds() external {
        uint256 amount = 10 * 1e18; // 10 ETH
        IERC20(weth).mint(address(this), amount);
        IERC20(weth).approve(address(driver), amount);
        
// Initialize the dataProvider using the deployer's address
        dataProvider = IAavePoolDataProvider(deployer.aaveDataProvider());
        
        weth = deployer.token18();
        usdt = deployer.token6();
        
        // Ensure Oracle Prices (WETH=$2000, USDT=$1)
        IMockAaveOracle(aaveOracle).setAssetPrice(weth, 2000 * 1e18);
        IMockAaveOracle(aaveOracle).setAssetPrice(usdt, 1 * 1e18);
        
        emit TestLog("p1_1: Funds Minted", amount);
    }

    function p1_2_Execute2xLong() external {
        uint256 initialMargin = 10 * 1e18;
        
        // DEBUG: Try/Catch wrapper
        try driver.executeLoop(
            weth,           // Collateral Asset
            usdt,           // Borrow Asset
            address(this),  // OnBehalfOf
            initialMargin,  // Initial Margin
            2 * 1e18,       // Target Leverage (2.0)
            1.1 * 1e18,     // Min Health Factor
            200             // Max Slippage (2%)
        ) {
            // VERIFICATION
            (,,,,, uint256 hf) = IMockAavePool(aavePool).getUserAccountData(address(this));
            require(hf > 1.1 * 1e18, "HF too low");
            
            uint256 col = IMockAavePool(aavePool).userCollateral(address(this), weth);
            require(col >= 19 * 1e18, "Leverage target not met");
            
            emit TestLog("p1_2: SUCCESS - 2x Long Executed. HF:", hf);

        } catch Error(string memory reason) {
            emit DebugError(reason, "");
            revert(string(abi.encodePacked("p1_2 Failed: ", reason)));
        } catch (bytes memory lowLevelData) {
            emit DebugError("Low Level Error", lowLevelData);
            revert("p1_2 Failed: Low Level Error (Check Logs)");
        }
    }

    function p1_3_SimulatePump() external {
        // Pump WETH price by +10% (to $2200)
        // 1. Update Oracle
        IMockAaveOracle(aaveOracle).setAssetPrice(weth, 2200 * 1e18);

        // 2. Buy WETH on Uni to match oracle (Simulate real market move)
        uint256 buyAmount = 2_000_000 * 1e6; // $2M USDT
        IERC20(usdt).mint(address(this), buyAmount);
        IERC20(usdt).approve(uniRouter, buyAmount);
        
        address[] memory path = new address[](2);
        path[0] = usdt; 
        path[1] = weth;
        
        // DEBUG: Try/Catch wrapper for Mock Swap
        try IMockUniRouter(uniRouter).swapExactTokensForTokens(
            buyAmount,
            0,
            path,
            address(this),
            block.timestamp + 100
        ) {
            emit TestLog("p1_3: Pumped to $2200", 2200);
        } catch Error(string memory reason) {
            emit DebugError(reason, "");
            revert(string(abi.encodePacked("p1_3 Swap Failed: ", reason)));
        } catch (bytes memory lowLevelData) {
            emit DebugError("Low Level Error", lowLevelData);
            revert("p1_3 Swap Failed: Low Level Error");
        }
    }

    function p1_4_UnwindAndVerifyProfit() external {
        // 1. MUST APPROVE aToken to Driver
        // Since p1 is WETH collateral, we need the aWETH address
        (address aWeth, , ) = dataProvider.getReserveTokensAddresses(weth);
        
        // Grant allowance so the driver can move your collateral receipts
        IERC20(aWeth).approve(address(driver), type(uint256).max);
        
        emit TestLog("p1_4: aToken Approved", 0);
        
        uint256 balanceBefore = IERC20(weth).balanceOf(address(this));

        // 2. Execute Unwind
        try driver.unwindLoop(
            weth, 
            usdt, 
            type(uint256).max, // Repay all debt
            type(uint256).max, // Withdraw all remaining collateral
            200                // 2% slippage
        ) {
            emit TestLog("p1_4: Unwind Successful", 0);
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Unwind Failed: ", reason)));
        } catch (bytes memory lowLevelData) {
            emit DebugError("Low Level Error during Unwind", lowLevelData);
            revert("Unwind Failed: Low Level Error");
        }
        // Verify profit
        uint256 balanceAfter = IERC20(weth).balanceOf(address(this));
uint256 profit = balanceAfter - balanceBefore;
require(profit >= 1.5 * 1e18, "Expected profit not achieved");
emit TestLog("p1_4: Net Profit (ETH)", profit);
    }

    // ============ PATH 2: 10x SHORT STRATEGY ============
    // Objective: Short ETH (Borrow WETH, Sell for USDT).
    // Initial: $1k USDT. Target: 3.5x Leverage.
    // Dangerous Setup: Low Health Factor expected.

    function p2_1_PrepareFunds() external {
        // Reset prices for clean slate
        IMockAaveOracle(aaveOracle).setAssetPrice(weth, 2000 * 1e18);
        IMockAaveOracle(aaveOracle).setAssetPrice(usdt, 1 * 1e18);

        // [FIX] Reduced Initial Margin 
        uint256 amount = 1_000 * 1e6; // $1,000 USDT
        
        IERC20(usdt).mint(address(this), amount);
        IERC20(usdt).approve(address(driver), amount);
        
        emit TestLog("p2_1: USDT Funds Minted (Reduced)", amount);
    }

    function p2_2_Execute3_5xShort() external {
        // [FIX] Match the reduced margin from p2_1
        uint256 initialMargin = 1_000 * 1e6; 

        // DEBUG: Try/Catch wrapper
        try driver.executeLoop(
            usdt,           // Collateral (Long USDT)
            weth,           // Borrow (Short WETH)
            address(this),
            initialMargin,
            
            // [FIX] Adjusted Target Leverage to 3.5x
            // Why? With 75% LTV, the mathematical max is 4x (1 / (1-0.75)). 
            // 10x is impossible without changing the Mock LTV. 
            // 3.5x is sufficiently risky (HF ~1.12) to verify risk parameters.
            3.5 * 1e18,      

            1.05 * 1e18,    // Min Health Factor (Expecting ~1.12)
            200             // Max Slippage
        ) {
            emit TestLog("p2_2: Short Executed (Adjusted to Max Feasible 3.5x)", 0);
        } catch Error(string memory reason) {
            emit DebugError(reason, "");
            revert(string(abi.encodePacked("p2_2 Short Failed: ", reason)));
        } catch (bytes memory lowLevelData) {
            emit DebugError("Low Level Error", lowLevelData);
            revert("p2_2 Short Failed: Low Level Error");
        }
    }

    function p2_3_VerifyRisk() external {
        (,,,,, uint256 hf) = IMockAavePool(aavePool).getUserAccountData(address(this));
        emit TestLog("p2_3: Health Factor", hf);
        
        // At 3.5x leverage, HF should be very close to liquidation threshold.
        require(hf < 1.25 * 1e18, "HF too safe, leverage failed?");
        require(hf > 0.99 * 1e18, "Already liquidated?");
    }
}