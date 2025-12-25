// SPDX-License-Identifier: BSL 1.1
pragma solidity ^0.8.20;

// File Version: 0.0.2 (24/12/2025)
// - 0.0.2 (24/12): Added correct EVC implementation. 

interface xERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MockEVC {
    mapping(address => mapping(address => bool)) public operatorApproved;
    address public transientSender; // Simulates the "authenticated" user during a call

    // Checks if operator is authorized for account
    function isOperator(address owner, address operator) external view returns (bool) {
        return operatorApproved[owner][operator];
    }

    // [NEW : 0.0.2] Setup function for tests
    function enableOperator(address operator) external {
        operatorApproved[msg.sender][operator] = true;
    }
    
    // [NEW : 0.0.2] Execute call on behalf of account (Simulates EVC 100%)
    function call(
        address target, 
        uint256 value, 
        bytes calldata data, 
        address onBehalfOfAccount
    ) external payable returns (bytes memory) {
        require(operatorApproved[onBehalfOfAccount][msg.sender], "EVC: Not authorized");
        
        // 1. Set context
        transientSender = onBehalfOfAccount;
        
        // 2. Execute
        (bool success, bytes memory result) = target.call{value: value}(data);
        
        // 3. Clear context
        transientSender = address(0);
        
        require(success, "EVC: Call failed");
        return result;
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
    mapping(address => uint256) public debtBalance;
    uint256 public totalShares;
    
    // Dependencies
    MockEulerOracle public oracle;
    MockEVC public evc; // [NEW : 0.0.2] dependency

    constructor(
        address _asset, 
        string memory _name, 
        string memory _symbol, 
        uint8 _decimals,
        address _oracle,
        address _evc // [NEW : 0.0.2] argument
    ) {
        asset = _asset;
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        oracle = MockEulerOracle(_oracle);
        evc = MockEVC(_evc);
    }

    function setConfig(uint16 _ltv, uint16 _lt) external {
        ltv = _ltv;
        liquidationThreshold = _lt;
    }

    // [NEW : 0.0.2] Helper to get real sender (User vs Direct)
    function _msgSender() internal view returns (address) {
        if (msg.sender == address(evc)) {
            return evc.transientSender();
        }
        return msg.sender;
    }

    // ============ VIEWS ============

    function balanceOf(address account) external view returns (uint256) {
        return sharesBalance[account];
    }

    function debtOf(address account) external view returns (uint256) {
        return debtBalance[account];
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return shares;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return assets;
    }

    // ============ ACTIONS ============

    function deposit(uint256 amount, address receiver) external returns (uint256) {
        xERC20(asset).transferFrom(msg.sender, address(this), amount);
        sharesBalance[receiver] += amount;
        totalShares += amount;
        return amount;
    }

    function withdraw(uint256 amount, address receiver, address owner) external returns (uint256) {
        require(sharesBalance[owner] >= amount, "Insufficient shares");
        sharesBalance[owner] -= amount;
        totalShares -= amount;
        xERC20(asset).transfer(receiver, amount);
        return amount;
    }

    // [UPDATED : 0.0.2] Uses _msgSender() to assign debt to the User, not the Driver
    function borrow(uint256 amount, address receiver) external returns (uint256) {
        xERC20(asset).transfer(receiver, amount);
        debtBalance[_msgSender()] += amount; 
        return amount;
    }

    function repay(uint256 amount, address receiver) external returns (uint256) {
        xERC20(asset).transferFrom(msg.sender, address(this), amount);
        uint256 currentDebt = debtBalance[receiver];
        uint256 paid = amount > currentDebt ? currentDebt : amount;
        
        debtBalance[receiver] -= paid;
        return paid;
    }
}