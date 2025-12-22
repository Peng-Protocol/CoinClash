// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

import "./MockMAILToken.sol";
import "./MockWETH.sol";
import "./MockUniRouter.sol";
import "./MockAave.sol"; 

interface IUniswapV2Pair {
    function mint(address to) external returns (uint256 liquidity);
}

interface IUADriverSetup {
    function setAavePool(address _aavePool) external;
    function setAaveOracle(address _aaveOracle) external;
    function setDataProvider(address _dataProvider) external;
    function setUniswapRouter(address _uniswapRouter) external;
    function setUniswapFactory(address _uniswapFactory) external;
}

contract MockDeployer {
    MockMAILToken public token18; // Acts as WETH
    MockMAILToken public token6;  // Acts as USDT
    MockWETH public weth;         // Generic WETH for router
    MockUniFactory public uniFactory;
    MockUniRouter public uniRouter;
    
    // Aave Mocks
    MockAavePool public aavePool;
    MockAaveOracle public aaveOracle;
    MockAaveDataProvider public aaveDataProvider;
    
    address payable public pairToken18Token6;
    
    IUADriverSetup public driver;
    
    constructor() {}
    
    // Call this first
    function createMocks() external returns (address, address) {
        token18 = new MockMAILToken();
        token18.setDetails("Token 18", "TK18", 18);
        
        token6 = new MockMAILToken();
        token6.setDetails("Mock USDT", "USDT", 6);
        
        return (address(token18), address(token6));
    }
    
    // Call this second
    function createUniMocks() external returns (address, address, address, address) {
        require(address(token18) != address(0), "Create mocks first");
        
        weth = new MockWETH();
        uniFactory = new MockUniFactory(address(weth));
        uniRouter = new MockUniRouter(address(uniFactory), address(weth));
        
        // Create Pair
        pairToken18Token6 = payable(uniFactory.createPair(address(token18), address(token6)));
        
        // Add Liquidity
        token18.mint(pairToken18Token6, 1_000_000 * 1e18);
        token6.mint(pairToken18Token6, 2_000_000_000 * 1e6); // $2000 price implied
        IUniswapV2Pair(pairToken18Token6).mint(address(this));
        
        return (address(weth), address(uniFactory), address(uniRouter), pairToken18Token6);
    }
    
    // Call this third
    function createAaveMocks() external returns (address, address, address) {
        require(address(token18) != address(0), "Create mocks first");

        aaveOracle = new MockAaveOracle();
        aavePool = new MockAavePool(address(aaveOracle));
        aaveDataProvider = new MockAaveDataProvider(address(aavePool));
        
        // Configure WETH (token18): 80% LTV, 82.5% LT
        aavePool.setReserveConfig(address(token18), 8000, 8250, 18);
        
        // Configure USDT (token6): 75% LTV, 80% LT
        aavePool.setReserveConfig(address(token6), 7500, 8000, 6);
        
        // Fund Aave Pool
        token18.mint(address(aavePool), 10_000_000 * 1e18);
        token6.mint(address(aavePool), 10_000_000 * 1e6);
        
        return (address(aavePool), address(aaveOracle), address(aaveDataProvider));
    }
    
/**
 * @notice Configures a deployed UADriver with mock addresses
 * @dev Must be called after all mocks are created. Expects MockDeployer to be owner of UADriver.
 * @param _driverAddress The address of the deployed UADriver contract
 */
function setupUADriver(address _driverAddress) external returns (bool) {
    require(address(aavePool) != address(0), "Aave mocks not created");
    require(address(uniRouter) != address(0), "Uni mocks not created");
    require(_driverAddress != address(0), "Invalid driver address");
    
    driver = IUADriverSetup(_driverAddress);
    
    // Set all required addresses
    driver.setAavePool(address(aavePool));
    driver.setAaveOracle(address(aaveOracle));
    driver.setDataProvider(address(aaveDataProvider));
    driver.setUniswapRouter(address(uniRouter));
    driver.setUniswapFactory(address(uniFactory));
    
    return true;
}
}