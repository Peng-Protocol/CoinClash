// SPDX-License-Identifier: BSL 1.1
pragma solidity ^0.8.20;

// File Version: 0.0.1 (Euler Mock)

interface xERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// 1. MOCK EVC (Ethereum Vault Connector)
// In prod, this handles permissions. In mocks, we keep it simple.
contract MockEVC {
    // Checks if operator is authorized for account
    function isOperator(address owner, address operator) external pure returns (bool) {
        // For testing, we assume true or handle in logic
        return true; 
    }
    
    // Stubs
    function enableController(address, address) external {}
    function enableCollateral(address, address) external {}
}

// 2. MOCK ORACLE
contract MockEulerOracle {
    mapping(address => uint256) public prices;
    
    // Euler oracle interface usually returns price in 18 decimals relative to base
    function getPrice(address asset) external view returns (uint256) {
        return prices[asset];
    }
    
    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }
}

// 3. MOCK EULER VAULT (ERC4626-like but Euler specific)
contract MockEVault {
    address public asset;
    string public name;
    string public symbol;
    uint8 public decimals;
    
    // Configuration
    uint16 public ltv;
    uint16 public liquidationThreshold;
    
    // State
    mapping(address => uint256) public sharesBalance;
    mapping(address => uint256) public debtBalance; // In Assets
    uint256 public totalShares;
    
    // Dependencies
    MockEulerOracle public oracle;

    constructor(
        address _asset, 
        string memory _name, 
        string memory _symbol, 
        uint8 _decimals,
        address _oracle
    ) {
        asset = _asset;
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        oracle = MockEulerOracle(_oracle);
    }

    function setConfig(uint16 _ltv, uint16 _lt) external {
        ltv = _ltv;
        liquidationThreshold = _lt;
    }

    // ============ VIEWS ============

    function balanceOf(address account) external view returns (uint256) {
        return sharesBalance[account];
    }

    function debtOf(address account) external view returns (uint256) {
        return debtBalance[account];
    }

    // Simplified: 1 Share = 1 Asset for Mocking
    // (Real Euler has complex exchange rates based on interest)
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares; 
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return assets;
    }

    // ============ ACTIONS ============

    // Deposit Assets -> Get Shares
    function deposit(uint256 amount, address receiver) external returns (uint256) {
        xERC20(asset).transferFrom(msg.sender, address(this), amount);
        sharesBalance[receiver] += amount;
        totalShares += amount;
        return amount;
    }

    // Withdraw Shares -> Get Assets
    function withdraw(uint256 amount, address receiver, address owner) external returns (uint256) {
        require(sharesBalance[owner] >= amount, "Insufficient shares");
        sharesBalance[owner] -= amount;
        totalShares -= amount;
        xERC20(asset).transfer(receiver, amount);
        return amount;
    }

    // Borrow Assets -> Get Debt
    // NOTE: In Euler, the CALLER takes the debt.
    function borrow(uint256 amount, address receiver) external returns (uint256) {
        xERC20(asset).transfer(receiver, amount);
        debtBalance[msg.sender] += amount;
        return amount;
    }

    // Repay Assets -> Reduce Debt
    function repay(uint256 amount, address receiver) external returns (uint256) {
        xERC20(asset).transferFrom(msg.sender, address(this), amount);
        
        uint256 currentDebt = debtBalance[receiver];
        uint256 paid = amount > currentDebt ? currentDebt : amount;
        
        debtBalance[receiver] -= paid;
        return paid;
    }
}