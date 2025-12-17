// SPDX-License-Identifier: BSL 1.1
pragma solidity ^0.8.20;

// File Version: 0.0.3 (17/12/2025)
// - 0.0.3 (17/12/2025): Added and integrated mock aToken for collateral ownership. 
// - 0.0.2 (16/12/2025): Adjusted borrow. 

interface xERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

// 1. LIGHTWEIGHT MOCK A-TOKEN
contract MockAToken {
    MockAavePool pool;
    address public underlyingAsset;
    mapping(address => mapping(address => uint256)) public allowances;

    constructor(address _pool, address _asset) {
        pool = MockAavePool(_pool);
        underlyingAsset = _asset;
    }

    // Forward balance checks to the pool's internal mapping
    function balanceOf(address user) external view returns (uint256) {
        return pool.userCollateral(user, underlyingAsset);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowances[from][msg.sender] >= amount, "AToken: Low allowance");
        allowances[from][msg.sender] -= amount;
        // The Pool handles the actual accounting
        pool.moveCollateral(underlyingAsset, from, to, amount);
        return true;
    }
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
    
    // Mapping: User -> Asset -> Amount
    mapping(address => mapping(address => uint256)) public userCollateral;
    mapping(address => mapping(address => uint256)) public userDebt;
    
    // Mapping: Asset -> aToken Address
    mapping(address => address) public aTokens;

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
        if (configs[asset].ltv == 0) {
            assets.push(asset);
            // Auto-deploy a MockAToken for this asset
            MockAToken aToken = new MockAToken(address(this), asset);
            aTokens[asset] = address(aToken);
        }
        configs[asset] = ReserveConfig(ltv, lt, decimals);
    }

    // Called by MockAToken to move collateral (simulating transfer)
    function moveCollateral(address asset, address from, address to, uint256 amount) external {
        require(msg.sender == aTokens[asset], "Only aToken can move collateral");
        require(userCollateral[from][asset] >= amount, "Not enough collateral");
        userCollateral[from][asset] -= amount;
        userCollateral[to][asset] += amount;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        xERC20(asset).transferFrom(msg.sender, address(this), amount);
        userCollateral[onBehalfOf][asset] += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        // STANDARD LOGIC: msg.sender must hold the collateral (aTokens)
        require(userCollateral[msg.sender][asset] >= amount, "Not enough collateral");
        
        userCollateral[msg.sender][asset] -= amount;
        xERC20(asset).transfer(to, amount);
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address onBehalfOf) external {
        // FIXED: Transfer to msg.sender (the Driver), record debt on onBehalfOf
        xERC20(asset).transfer(msg.sender, amount);
        userDebt[onBehalfOf][asset] += amount;
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        xERC20(asset).transferFrom(msg.sender, address(this), amount);
        uint256 currentDebt = userDebt[onBehalfOf][asset];
        uint256 repayAmt = amount > currentDebt ? currentDebt : amount;
        userDebt[onBehalfOf][asset] -= repayAmt;
        return repayAmt;
    }
    
    function setUserUseReserveAsCollateral(address, bool) external {}

    function getUserAccountData(address user) external view returns (
        uint256 totalCollateralBase, uint256 totalDebtBase, uint256 availableBorrowsBase, 
        uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor
    ) {
        (uint256 totalCollateralETH, uint256 weightedLT, uint256 weightedLTV) = _calculateCollateral(user);
        uint256 totalDebtETH = _calculateDebt(user);

        if (totalCollateralETH > 0) {
            currentLiquidationThreshold = weightedLT / totalCollateralETH;
            ltv = weightedLTV / totalCollateralETH;
        }

        healthFactor = (totalDebtETH > 0) 
            ? (totalCollateralETH * currentLiquidationThreshold * 1e14) / totalDebtETH 
            : type(uint256).max;

        return (totalCollateralETH, totalDebtETH, 0, currentLiquidationThreshold, ltv, healthFactor);
    }

    function _calculateCollateral(address user) private view returns (uint256 totalCollateralETH, uint256 weightedLT, uint256 weightedLTV) {
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
                totalDebtETH += (debt * oracle.getAssetPrice(asset)) / 1e18;
            }
        }
    }
}

contract MockAaveDataProvider {
    MockAavePool public pool;
    constructor(address _pool) { pool = MockAavePool(_pool); }

    function getReserveConfigurationData(address asset) external view returns (
        uint256 decimals, uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus, 
        uint256 reserveFactor, bool usageAsCollateralEnabled, bool borrowingEnabled, 
        bool stableBorrowRateEnabled, bool isActive, bool isFrozen
    ) {
        (uint256 _ltv, uint256 _lt, uint256 _dec) = pool.configs(asset);
        return (_dec, _ltv, _lt, 0, 0, true, true, true, true, false);
    }

    // NEW: Return the MockAToken address
    function getReserveTokensAddresses(address asset) external view returns (
        address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress
    ) {
        return (pool.aTokens(asset), address(0), address(0));
    }

    function getUserReserveData(address asset, address user) external view returns (
        uint256 currentATokenBalance, uint256 currentStableDebt, uint256 currentVariableDebt, 
        uint256 principalStableDebt, uint256 scaledVariableDebt, uint256 stableBorrowRate, 
        uint256 liquidityRate, uint40 stableRateLastUpdated, bool usageAsCollateralEnabled
    ) {
        return (pool.userCollateral(user, asset), 0, pool.userDebt(user, asset), 0, 0, 0, 0, 0, true);
    }
    
    function getReserveData(address) external pure returns (uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint40) {
        return (type(uint256).max, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    }
}