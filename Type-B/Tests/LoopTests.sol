// SPDX-License-Identifier: BSL 1.1
pragma solidity ^0.8.20;

// INTERFACES (To avoid importing full artifacts)
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

contract LoopTests {
    // STATE
    IUADriver public driver;
    IMockDeployer public deployer;
    
    // CACHED ADDRESSES
    address public weth;  // Token18 (Collateral for Long)
    address public usdt;  // Token6 (Borrow for Long)
    address public aavePool;
    address public aaveOracle;
    address public uniRouter;
    
    address public owner;
    
    // Events for tracking test progress
    event TestLog(string message, uint256 value);
    event SetupCompleted(address deployer, address driver);
    
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
        
        // Ensure Oracle Prices (WETH=$2000, USDT=$1)
        IMockAaveOracle(aaveOracle).setAssetPrice(weth, 2000 * 1e18);
        IMockAaveOracle(aaveOracle).setAssetPrice(usdt, 1 * 1e18);
        
        emit TestLog("p1_1: Funds Minted", amount);
    }

    function p1_2_Execute2xLong() external {
        uint256 initialMargin = 10 * 1e18;
        
        driver.executeLoop(
            weth,           // Collateral Asset
            usdt,           // Borrow Asset
            address(this),  // OnBehalfOf
            initialMargin,  // Initial Margin
            2 * 1e18,       // Target Leverage (2.0)
            1.1 * 1e18,     // Min Health Factor
            200             // Max Slippage (2%)
        );
        
        // Verification
        (,,,,, uint256 hf) = IMockAavePool(aavePool).getUserAccountData(address(this));
        require(hf > 1.1 * 1e18, "HF too low");
        
        uint256 col = IMockAavePool(aavePool).userCollateral(address(this), weth);
        // 2x Leverage on 10 ETH = 20 ETH Total Position
        require(col >= 19 * 1e18, "Leverage target not met");
        
        emit TestLog("p1_2: 2x Long Executed. HF:", hf);
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
        
        IMockUniRouter(uniRouter).swapExactTokensForTokens(
            buyAmount,
            0,
            path,
            address(this),
            block.timestamp + 100
        );
        
        emit TestLog("p1_3: Pumped to $2200", 2200);
    }

    function p1_4_UnwindAndVerifyProfit() external {
        uint256 balBefore = IERC20(weth).balanceOf(address(this));
        
        driver.unwindLoop(
            weth,
            usdt,
            0,                 // Repay All
            type(uint256).max, // Withdraw All
            500                // 5% Slippage allowed for unwind
        );
        
        uint256 balAfter = IERC20(weth).balanceOf(address(this));
        uint256 profit = balAfter - balBefore;
        
        // Analysis:
        // Position: 20 ETH ($44k value at $2200). Debt: $20k USDT.
        // Net Equity: $24k.
        // Initial Equity: 10 ETH @ $2000 = $20k.
        // Profit: $4k. In WETH terms ($2200/ETH) -> ~1.81 ETH.
        // Due to fees/slippage, we expect at least 1.5 ETH profit.
        
        emit TestLog("p1_4: Profit (Wei)", profit);
        require(profit > 1.5 * 1e18, "Profit lower than expected");
    }

    // ============ PATH 2: 10x SHORT STRATEGY ============
    // Objective: Short ETH (Borrow WETH, Sell for USDT).
    // Initial: $20k USDT. Target: 10x Leverage.
    // Dangerous Setup: Low Health Factor expected.

    function p2_1_PrepareFunds() external {
        // Reset prices for clean slate
        IMockAaveOracle(aaveOracle).setAssetPrice(weth, 2000 * 1e18);
        IMockAaveOracle(aaveOracle).setAssetPrice(usdt, 1 * 1e18);

        uint256 amount = 20_000 * 1e6; // $20k USDT
        IERC20(usdt).mint(address(this), amount);
        IERC20(usdt).approve(address(driver), amount);
        
        emit TestLog("p2_1: USDT Funds Minted", amount);
    }

    function p2_2_Execute10xShort() external {
        uint256 initialMargin = 20_000 * 1e6;
        
        // 10x Short means:
        // Equity: $20k.
        // Total Position (Collateral USDT): $200k.
        // Debt (WETH): $180k worth (90 ETH).
        
        driver.executeLoop(
            usdt,           // Collateral (Long USDT)
            weth,           // Borrow (Short WETH)
            address(this),
            initialMargin,
            10 * 1e18,      // 10x
            1.01 * 1e18,    // Extremely tight HF allowed
            200
        );
        
        emit TestLog("p2_2: 10x Short Executed", 0);
    }

    function p2_3_VerifyRisk() external {
        (,,,,, uint256 hf) = IMockAavePool(aavePool).getUserAccountData(address(this));
        
        emit TestLog("p2_3: Health Factor", hf);
        
        // At 10x leverage, HF should be very close to liquidation threshold.
        // Depending on LTV (e.g. 80%), 10x might barely fit or be risky.
        // We ensure it is LOW (risk confirmed).
        require(hf < 1.25 * 1e18, "HF too safe, leverage failed?");
        require(hf > 0.99 * 1e18, "Already liquidated?");
    }
}