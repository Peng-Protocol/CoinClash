// SPDX-License-Identifier: BSL 1.1
pragma solidity ^0.8.2;

import "./MockMAILToken.sol";
import "./MockWETH.sol";
import "./MockUniRouter.sol";
import "./MockEuler.sol";

interface IUEDriverSetup {
    function setEVC(address) external;
    function setUniswapRouter(address) external;
    function setUniswapFactory(address) external;
    function setOracle(address) external;
}

interface IUniswapV2Pair {
    function mint(address to) external returns (uint256 liquidity);
}

contract MockEulerDeployer {
    // Tokens
    MockMAILToken public token18; // WETH
    MockMAILToken public token6;  // USDT
    MockWETH public weth;         // Generic WETH for Router
    
    // Uniswap
    MockUniFactory public uniFactory;
    MockUniRouter public uniRouter;
    address payable public pairAddress;
    
    // Euler
    MockEVC public evc;
    MockEulerOracle public oracle;
    MockEVault public wethVault;
    MockEVault public usdtVault;

    IUEDriverSetup public driver;

    function createMocks() external returns (address, address) {
        token18 = new MockMAILToken();
        token18.setDetails("Wrapper Ether", "WETH", 18);
        
        token6 = new MockMAILToken();
        token6.setDetails("Tether USD", "USDT", 6);
        
        return (address(token18), address(token6));
    }
    
    function createUniMocks() external returns (address, address, address) {
        require(address(token18) != address(0), "Tokens missing");
        
        weth = new MockWETH();
        uniFactory = new MockUniFactory(address(weth));
        uniRouter = new MockUniRouter(address(uniFactory), address(weth));
        
        pairAddress = payable(uniFactory.createPair(address(token18), address(token6)));
        
        // Add Liquidity: $2000 ETH
        token18.mint(pairAddress, 1_000_000 * 1e18);
        token6.mint(pairAddress, 2_000_000_000 * 1e6);
        IUniswapV2Pair(pairAddress).mint(address(this));
        
        return (address(uniRouter), address(uniFactory), pairAddress);
    }
    
    function createEulerMocks() external returns (address, address, address, address) {
        require(address(token18) != address(0), "Tokens missing");
        
        evc = new MockEVC();
        oracle = new MockEulerOracle();
        
        // Deploy Vaults
        // WETH Vault: 90% LTV (Aggressive), 91% LT
        wethVault = new MockEVault(address(token18), "Euler WETH", "eWETH", 18, address(oracle));
        wethVault.setConfig(9000, 9100);
        
        // USDT Vault: 90% LTV, 91% LT
        usdtVault = new MockEVault(address(token6), "Euler USDT", "eUSDT", 6, address(oracle));
        usdtVault.setConfig(9000, 9100);
        
        // Fund Vaults (Liquidity for borrowing)
        token18.mint(address(wethVault), 10_000_000 * 1e18);
        token6.mint(address(usdtVault), 10_000_000 * 1e6);
        
        return (address(evc), address(oracle), address(wethVault), address(usdtVault));
    }
    
    function setupUEDriver(address _driver) external {
        driver = IUEDriverSetup(_driver);
        driver.setEVC(address(evc));
        driver.setOracle(address(oracle));
        driver.setUniswapRouter(address(uniRouter));
        driver.setUniswapFactory(address(uniFactory));
    }
}