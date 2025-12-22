// SPDX-License-Identifier: BSL 1.1
pragma solidity ^0.8.20;

// File Version: 0.0.1 (22/12/2025)

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

interface IMockEulerDeployer {
    function token18() external view returns (address);
    function token6() external view returns (address);
    function weth() external view returns (address);
    function uniRouter() external view returns (address);
    function uniFactory() external view returns (address);
    function evc() external view returns (address);
    function oracle() external view returns (address);
    function wethVault() external view returns (address);
    function usdtVault() external view returns (address);
    function driver() external view returns (address);
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

interface IMockOracle {
    function setPrice(address asset, uint256 price) external;
}

interface IMockEVault {
    function balanceOf(address account) external view returns (uint256);
    function debtOf(address account) external view returns (uint256);
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

// =============================================================
// TEST CONTRACT
// =============================================================

contract EulerLoopTests {
    // STATE
    IUEDriver public driver;
    IMockEulerDeployer public deployer;
    
    // CACHED ADDRESSES
    address public weth; // Token18 (Collateral for Long)
    address public usdt; // Token6 (Borrow for Long)
    address public wethVault;
    address public usdtVault;
    address public oracle;
    address public uniRouter;
    
    address public owner;

    // EVENTS
    event TestLog(string message, uint256 value);
    event SetupCompleted(address deployer, address driver);
    event DebugError(string reason, bytes lowLevelData);

    constructor() {
        owner = msg.sender;
    }

    // ============ SETUP FUNCTIONS ============

    function setDeployer(address _deployer) external {
        require(msg.sender == owner, "Auth");
        deployer = IMockEulerDeployer(_deployer);
        
        // Load mocks from the deployer
        weth = deployer.token18();
        usdt = deployer.token6();
        wethVault = deployer.wethVault();
        usdtVault = deployer.usdtVault();
        oracle = deployer.oracle();
        uniRouter = deployer.uniRouter();
        
        // Fetch driver address from deployer
        driver = IUEDriver(deployer.driver());
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
        IMockOracle(oracle).setPrice(weth, 2000 * 1e18);
        IMockOracle(oracle).setPrice(usdt, 1 * 1e18);
        
        emit TestLog("p1_1: Funds Minted", amount);
    }

    function p1_2_Execute2xLong() external {
        uint256 initialMargin = 10 * 1e18;
        
        try driver.executeLoop(
            wethVault,      // Collateral Vault
            usdtVault,      // Borrow Vault
            initialMargin,  // Initial Margin
            2 * 1e18,       // Target Leverage (2.0)
            1.1 * 1e18,     // Min Health Factor
            200             // Max Slippage (2%)
        ) {
            // VERIFICATION
            uint256 colShares = IMockEVault(wethVault).balanceOf(address(this));
            require(colShares >= 19 * 1e18, "Leverage target not met");
            
            uint256 debt = IMockEVault(usdtVault).debtOf(address(this));
            
            // Calculate HF: (Collateral * LT) / Debt
            // LT = 91% (9100/10000)
            uint256 colVal = colShares * 2000; // $2000 per ETH
            uint256 debtVal = debt * 1; // $1 per USDT (normalized to 18 decimals)
            uint256 hf = (colVal * 9100 / 10000) * 1e18 / debtVal;
            
            require(hf > 1.1 * 1e18, "HF too low");
            
            emit TestLog("p1_2: SUCCESS - 2x Long Executed. HF:", hf);
            emit TestLog("p1_2: Collateral Shares", colShares);

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
        IMockOracle(oracle).setPrice(weth, 2200 * 1e18);

        // Buy WETH on Uni to match oracle (Simulate real market move)
        uint256 buyAmount = 2_000_000 * 1e6; // $2M USDT
        IERC20(usdt).mint(address(this), buyAmount);
        IERC20(usdt).approve(uniRouter, buyAmount);
        
        address[] memory path = new address[](2);
        path[0] = usdt; 
        path[1] = weth;
        
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
        // Approve vault shares (eWETH) to driver for unwinding
        IERC20(wethVault).approve(address(driver), type(uint256).max);
        
        emit TestLog("p1_4: Vault Shares Approved", 0);
        
        uint256 balanceBefore = IERC20(weth).balanceOf(address(this));

        // Execute Unwind
        try driver.unwindLoop(
            wethVault, 
            usdtVault, 
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
    // Initial: $2k USDT. Target: 10x Leverage.
    // With 90% LTV, theoretical max is ~10x (1 / (1-0.90)).

    function p2_1_PrepareFunds() external {
        // Reset prices for clean slate
        IMockOracle(oracle).setPrice(weth, 2000 * 1e18);
        IMockOracle(oracle).setPrice(usdt, 1 * 1e18);

        uint256 amount = 2_000 * 1e6; // $2,000 USDT
        
        IERC20(usdt).mint(address(this), amount);
        IERC20(usdt).approve(address(driver), amount);
        
        emit TestLog("p2_1: USDT Funds Minted", amount);
    }

    function p2_2_Execute10xShort() external {
        uint256 initialMargin = 2_000 * 1e6;

        try driver.executeLoop(
            usdtVault,      // Collateral (Long USDT)
            wethVault,      // Borrow (Short WETH)
            initialMargin,
            10 * 1e18,      // Target Leverage (10x)
            1.05 * 1e18,    // Min Health Factor (Aggressive)
            200             // Max Slippage
        ) {
            emit TestLog("p2_2: 10x Short Executed", 0);
        } catch Error(string memory reason) {
            emit DebugError(reason, "");
            revert(string(abi.encodePacked("p2_2 Short Failed: ", reason)));
        } catch (bytes memory lowLevelData) {
            emit DebugError("Low Level Error", lowLevelData);
            revert("p2_2 Short Failed: Low Level Error");
        }
    }

    function p2_3_VerifyRisk() external {
        uint256 colShares = IMockEVault(usdtVault).balanceOf(address(this));
        uint256 debt = IMockEVault(wethVault).debtOf(address(this));
        
        // Calculate HF: (Collateral * LT) / Debt
        // Collateral: USDT at $1, Debt: WETH at $2000
        // LT = 91% (9100/10000)
        uint256 colVal = colShares * 1e18; // $1 per USDT (already 6 decimals, scale to 18)
        uint256 debtVal = debt * 2000; // $2000 per ETH
        
        uint256 hf = (colVal * 9100 / 10000) * 1e18 / debtVal;
        
        emit TestLog("p2_3: Health Factor", hf);
        emit TestLog("p2_3: Collateral (USDT)", colShares);
        emit TestLog("p2_3: Debt (WETH)", debt);
        
        // At 10x leverage with 90% LTV, HF should be very close to liquidation threshold
        require(hf < 1.25 * 1e18, "HF too safe, leverage failed?");
        require(hf > 0.99 * 1e18, "Already liquidated?");
    }
}