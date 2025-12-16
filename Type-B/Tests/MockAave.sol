// SPDX-License-Identifier: BSL 1.1
pragma solidity ^0.8.20;

// File Version: 0.0.2 (16/12/2025)
// - 0.0.2 (16/12/2025): Adjusted borrow. 

interface xERC20 {
    function balanceOf(address) external view returns (uint256);
    function mint(address, uint256) external;
    function burn(address, uint256) external;
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

contract MockAaveOracle {
    mapping(address => uint256) public prices;

    function getAssetPrice(address asset) external view returns (uint256) {
        return prices[asset];
    }

    function setAssetPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }
}

contract MockAavePool {
    MockAaveOracle public oracle;
    mapping(address => mapping(address => uint256)) public userCollateral;
    mapping(address => mapping(address => uint256)) public userDebt;
    
    struct ReserveConfig {
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 decimals;
    }
    mapping(address => ReserveConfig) public configs;
    address[] public assets;

    constructor(address _oracle) {
        oracle = MockAaveOracle(_oracle);
    }

    function setReserveConfig(address asset, uint256 ltv, uint256 lt, uint256 decimals) external {
        if (configs[asset].ltv == 0 && configs[asset].liquidationThreshold == 0) {
            assets.push(asset);
        }
        configs[asset] = ReserveConfig(ltv, lt, decimals);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        xERC20(asset).transferFrom(msg.sender, address(this), amount);
        userCollateral[onBehalfOf][asset] += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(userCollateral[msg.sender][asset] >= amount, "Not enough collateral");
        userCollateral[msg.sender][asset] -= amount;
        xERC20(asset).transfer(to, amount);
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        // CHANGE: Transfer asset to msg.sender (the Driver), not onBehalfOf
        xERC20(asset).transfer(msg.sender, amount); 
        
        // Debt is still recorded against onBehalfOf
        userDebt[onBehalfOf][asset] += amount;
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        xERC20(asset).transferFrom(msg.sender, address(this), amount);
        if (userDebt[onBehalfOf][asset] >= amount) {
            userDebt[onBehalfOf][asset] -= amount;
        } else {
            userDebt[onBehalfOf][asset] = 0;
        }
        return amount;
    }

    function setUserUseReserveAsCollateral(address, bool) external {}

    // MATH ENGINE - Refactored to avoid stack too deep
    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase, 
        uint256 totalDebtBase, 
        uint256 availableBorrowsBase, 
        uint256 currentLiquidationThreshold, 
        uint256 ltv, 
        uint256 healthFactor
    ) {
        (uint256 totalCollateralETH, uint256 weightedLT, uint256 weightedLTV) = _calculateCollateral(user);
        uint256 totalDebtETH = _calculateDebt(user);

        if (totalCollateralETH > 0) {
            currentLiquidationThreshold = weightedLT / totalCollateralETH;
            ltv = weightedLTV / totalCollateralETH;
        }

        if (totalDebtETH > 0) {
            healthFactor = (totalCollateralETH * currentLiquidationThreshold * 1e14) / totalDebtETH;
        } else {
            healthFactor = type(uint256).max;
        }

        return (totalCollateralETH, totalDebtETH, 0, currentLiquidationThreshold, ltv, healthFactor);
    }

    function _calculateCollateral(address user) private view returns (
        uint256 totalCollateralETH,
        uint256 weightedLT,
        uint256 weightedLTV
    ) {
        for (uint i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 collateral = userCollateral[user][asset];
            
            if (collateral > 0) {
                uint256 price = oracle.getAssetPrice(asset);
                uint256 val = (collateral * price) / 1e18;
                totalCollateralETH += val;
                weightedLT += val * configs[asset].liquidationThreshold;
                weightedLTV += val * configs[asset].ltv;
            }
        }
    }

    function _calculateDebt(address user) private view returns (uint256 totalDebtETH) {
        for (uint i = 0; i < assets.length; i++) {
            address asset = assets[i];
            uint256 debt = userDebt[user][asset];
            
            if (debt > 0) {
                uint256 price = oracle.getAssetPrice(asset);
                totalDebtETH += (debt * price) / 1e18;
            }
        }
    }
}

contract MockAaveDataProvider {
    MockAavePool public pool;

    constructor(address _pool) {
        pool = MockAavePool(_pool);
    }

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
    ) {
        (uint256 _ltv, uint256 _lt, uint256 _dec) = pool.configs(asset);
        return (_dec, _ltv, _lt, 0, 0, true, true, true, true, false);
    }

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
    ) {
        uint256 col = pool.userCollateral(user, asset);
        uint256 debt = pool.userDebt(user, asset);
        
        return (col, 0, debt, 0, 0, 0, 0, 0, true);
    }

    function getReserveData(address) external pure returns (
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
    ) {
        return (type(uint256).max, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    }
}