// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.0.1 (03/12/2025)
// MockDeployer handles mock creation and returns addresses to LiquidTests
// LiquidTests calls create functions which deploy and return addresses

import "./MockMAILToken.sol";
import "./MockMailTester.sol";
import "./MockWETH.sol";
import "./MockUniRouter.sol";

interface IUniswapV2Pair {
    function mint(address to) external returns (uint256 liquidity);
}

contract MockDeployer {
    MockMAILToken public token18;
    MockMAILToken public token6;
    MockWETH public weth;
    MockUniFactory public uniFactory;
    MockUniRouter public uniRouter;
    MockMailTester public tester;
    
    address payable public pairToken18Token6;
    
    uint256 public constant LIQUIDITY_TOKEN18 = 10000 * 1e18;
    uint256 public constant LIQUIDITY_TOKEN6 = 10000 * 1e6;
    
    address public liquidTestsAddress;
    
    event MocksCreated(address token18, address token6);
    event UniMocksCreated(address weth, address factory, address router, address pair);
    event TesterCreated(address tester);
    
    constructor() {}
    
    receive() external payable {}
    
    modifier onlyLiquidTests() {
        require(msg.sender == liquidTestsAddress, "Only LiquidTests");
        _;
    }
    
    function setLiquidTests(address _liquidTests) external {
        require(liquidTestsAddress == address(0), "Already set");
        require(_liquidTests != address(0), "Invalid address");
        liquidTestsAddress = _liquidTests;
    }
    
    function createMocks() external onlyLiquidTests returns (address, address) {
        require(address(token18) == address(0), "Already created");
        
        token18 = new MockMAILToken();
        token18.setDetails("Token 18", "TK18", 18);
        
        token6 = new MockMAILToken();
        token6.setDetails("Token 6", "TK6", 6);
        
        emit MocksCreated(address(token18), address(token6));
        return (address(token18), address(token6));
    }
    
    function createUniMocks() external onlyLiquidTests returns (address, address, address, address) {
        require(address(weth) == address(0), "Already created");
        require(address(token18) != address(0), "Create mocks first");
        
        weth = new MockWETH();
        uniFactory = new MockUniFactory(address(weth));
        uniRouter = new MockUniRouter(address(uniFactory), address(weth));
        
        // Create pair with liquidity
        pairToken18Token6 = payable(uniFactory.createPair(address(token18), address(token6)));
        token18.transfer(pairToken18Token6, LIQUIDITY_TOKEN18);
        token6.transfer(pairToken18Token6, LIQUIDITY_TOKEN6);
        IUniswapV2Pair(pairToken18Token6).mint(address(this));
        
        emit UniMocksCreated(address(weth), address(uniFactory), address(uniRouter), pairToken18Token6);
        return (address(weth), address(uniFactory), address(uniRouter), pairToken18Token6);
    }
    
    function createTester() external payable onlyLiquidTests returns (address) {
        require(address(tester) == address(0), "Already created");
        require(msg.value >= 2 ether, "Send 2 ETH");
        require(address(token18) != address(0), "Create mocks first");
        
        tester = new MockMailTester(liquidTestsAddress);
        
        (bool success,) = address(tester).call{value: 2 ether}("");
        require(success, "ETH transfer failed");
        
        token18.mint(address(tester), 1000 * 1e18);
        token6.mint(address(tester), 1000 * 1e6);
        
        emit TesterCreated(address(tester));
        return address(tester);
    }
    
    // Mint functions for test contract
    function mintToken18(address to, uint256 amount) external onlyLiquidTests {
        token18.mint(to, amount);
    }
    
    function mintToken6(address to, uint256 amount) external onlyLiquidTests {
        token6.mint(to, amount);
    }
    
    // Transfer functions if needed
    function transferToken18(address to, uint256 amount) external onlyLiquidTests {
        token18.transfer(to, amount);
    }
    
    function transferToken6(address to, uint256 amount) external onlyLiquidTests {
        token6.transfer(to, amount);
    }
}