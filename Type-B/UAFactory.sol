// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title UADriverFactory - Factory for deploying UADriver instances
 * @notice Deploy and manage UADriver contracts for different asset pairs
 * @dev Drivers are stateless tools - users manage positions directly through Aave
 */
 
 // File Version: 0.0.1 (07/12/2025)
 // - 0.0.1 (07/12): Initial Implementation.

import "./UADriver.sol";
import "./imports/ReentrancyGuard.sol";

contract UADriverFactory is Ownable {
    
    // STATE VARIABLES
    
    // Core protocol addresses (shared across all drivers)
    address public immutable aavePool;
    address public immutable uniswapRouter;
    address public immutable uniswapFactory;
    address public immutable aaveOracle;
    address public immutable dataProvider;
    
    // Driver tracking
    address[] public allDrivers;
    
    // Mapping: collateralAsset => borrowAsset => driver address
    mapping(address => mapping(address => address)) public getDriver;
    
    // Mapping: driver address => exists
    mapping(address => bool) public isDriver;
    
    // Configuration
    bool public deploymentPaused;
    uint256 public deploymentFee;
    
    // EVENTS
    
    event DriverDeployed(
        address indexed driver,
        address indexed collateralAsset,
        address indexed borrowAsset,
        uint256 driverCount
    );
    
    event DeploymentFeeUpdated(uint256 oldFee, uint256 newFee);
    
    event DeploymentPauseToggled(bool paused);
    
    event FeeCollected(address indexed collector, uint256 amount);
    
    // ERRORS
    
    error DeploymentPaused();
    error DriverAlreadyExists();
    error InvalidAddress();
    error IdenticalAssets();
    error InsufficientFee();
    error TransferFailed();
    
    // CONSTRUCTOR
    
    constructor(
        address _aavePool,
        address _uniswapRouter,
        address _uniswapFactory,
        address _aaveOracle,
        address _dataProvider
    ) Ownable() { // FIX: Removed (msg.sender)
        require(_aavePool != address(0), "Invalid pool");
        require(_uniswapRouter != address(0), "Invalid router");
        require(_uniswapFactory != address(0), "Invalid factory");
        require(_aaveOracle != address(0), "Invalid oracle");
        require(_dataProvider != address(0), "Invalid data provider");
        
        aavePool = _aavePool;
        uniswapRouter = _uniswapRouter;
        uniswapFactory = _uniswapFactory;
        aaveOracle = _aaveOracle;
        dataProvider = _dataProvider;
    }
    
    // MAIN FUNCTIONS
    
    /**
     * @notice Deploy a new UADriver for a specific asset pair
     * @param collateralAsset The collateral asset address
     * @param borrowAsset The borrow asset address
     * @return driver The address of the newly deployed driver
     */
    function createDriver(
        address collateralAsset,
        address borrowAsset
    ) external payable returns (address driver) {
        if (deploymentPaused) revert DeploymentPaused();
        if (msg.value < deploymentFee) revert InsufficientFee();
        if (collateralAsset == address(0) || borrowAsset == address(0)) revert InvalidAddress();
        if (collateralAsset == borrowAsset) revert IdenticalAssets();
        
        // Check if driver already exists
        if (getDriver[collateralAsset][borrowAsset] != address(0)) {
            revert DriverAlreadyExists();
        }
        
        // Deploy new UADriver
        UADriver newDriver = new UADriver(
            aavePool,
            uniswapRouter,
            uniswapFactory,
            aaveOracle,
            dataProvider,
            collateralAsset,
            borrowAsset
        );
        
        driver = address(newDriver);
        
        // Store driver information
        getDriver[collateralAsset][borrowAsset] = driver;
        isDriver[driver] = true;
        allDrivers.push(driver);
        
        emit DriverDeployed(
            driver,
            collateralAsset,
            borrowAsset,
            allDrivers.length
        );
        
        return driver;
    }
    
    // VIEW FUNCTIONS
    
    /**
     * @notice Get the total number of deployed drivers
     */
    function driverCount() external view returns (uint256) {
        return allDrivers.length;
    }
    
    /**
     * @notice Get all deployed drivers
     */
    function getAllDrivers() external view returns (address[] memory) {
        return allDrivers;
    }
    
    /**
     * @notice Get driver for a specific asset pair (returns zero address if none exists)
     */
    function getDriverForPair(
        address collateralAsset,
        address borrowAsset
    ) external view returns (address) {
        return getDriver[collateralAsset][borrowAsset];
    }
    
    /**
     * @notice Check if a driver exists for a specific pair
     */
    function driverExists(
        address collateralAsset,
        address borrowAsset
    ) external view returns (bool) {
        return getDriver[collateralAsset][borrowAsset] != address(0);
    }
    
    /**
     * @notice Get driver info
     */
    function getDriverInfo(address driver) external view returns (
        bool exists,
        address collateral,
        address borrow,
        bool isPaused,
        uint256 maxSlippageBps
    ) {
        if (!isDriver[driver]) {
            return (false, address(0), address(0), false, 0);
        }
        
        UADriver driverContract = UADriver(payable(driver));
        
        return (
            true,
            driverContract.collateralAsset(),
            driverContract.borrowAsset(),
            driverContract.paused(),
            driverContract.maxSlippageBps()
        );
    }
    
    /**
     * @notice Batch query multiple drivers
     */
    function getDriversInfo(address[] calldata drivers) external view returns (
        bool[] memory exists,
        address[] memory collaterals,
        address[] memory borrows,
        bool[] memory isPaused
    ) {
        uint256 length = drivers.length;
        exists = new bool[](length);
        collaterals = new address[](length);
        borrows = new address[](length);
        isPaused = new bool[](length);
        
        for (uint256 i = 0; i < length; i++) {
            if (isDriver[drivers[i]]) {
                UADriver driverContract = UADriver(payable(drivers[i]));
                exists[i] = true;
                collaterals[i] = driverContract.collateralAsset();
                borrows[i] = driverContract.borrowAsset();
                isPaused[i] = driverContract.paused();
            }
        }
        
        return (exists, collaterals, borrows, isPaused);
    }
    
    /**
     * @notice Get paginated list of drivers
     */
    function getDriversPaginated(
        uint256 offset,
        uint256 limit
    ) external view returns (
        address[] memory drivers,
        uint256 total
    ) {
        total = allDrivers.length;
        
        if (offset >= total) {
            return (new address[](0), total);
        }
        
        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }
        
        uint256 resultLength = end - offset;
        drivers = new address[](resultLength);
        
        for (uint256 i = 0; i < resultLength; i++) {
            drivers[i] = allDrivers[offset + i];
        }
        
        return (drivers, total);
    }
    
    /**
     * @notice Find drivers for specific collateral asset
     */
    function findDriversByCollateral(
        address collateralAsset
    ) external view returns (address[] memory drivers) {
        uint256 count = 0;
        
        // First pass: count matches
        for (uint256 i = 0; i < allDrivers.length; i++) {
            UADriver driver = UADriver(payable(allDrivers[i]));
            if (driver.collateralAsset() == collateralAsset) {
                count++;
            }
        }
        
        // Second pass: collect matches
        drivers = new address[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allDrivers.length; i++) {
            UADriver driver = UADriver(payable(allDrivers[i]));
            if (driver.collateralAsset() == collateralAsset) {
                drivers[index] = allDrivers[i];
                index++;
            }
        }
        
        return drivers;
    }
    
    /**
     * @notice Find drivers for specific borrow asset
     */
    function findDriversByBorrow(
        address borrowAsset
    ) external view returns (address[] memory drivers) {
        uint256 count = 0;
        
        // First pass: count matches
        for (uint256 i = 0; i < allDrivers.length; i++) {
            UADriver driver = UADriver(payable(allDrivers[i]));
            if (driver.borrowAsset() == borrowAsset) {
                count++;
            }
        }
        
        // Second pass: collect matches
        drivers = new address[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < allDrivers.length; i++) {
            UADriver driver = UADriver(payable(allDrivers[i]));
            if (driver.borrowAsset() == borrowAsset) {
                drivers[index] = allDrivers[i];
                index++;
            }
        }
        
        return drivers;
    }
    
    // ADMIN FUNCTIONS
    
    /**
     * @notice Set deployment fee
     */
    function setDeploymentFee(uint256 newFee) external onlyOwner {
        uint256 oldFee = deploymentFee;
        deploymentFee = newFee;
        emit DeploymentFeeUpdated(oldFee, newFee);
    }
    
    /**
     * @notice Toggle deployment pause
     */
    function toggleDeploymentPause() external onlyOwner {
        deploymentPaused = !deploymentPaused;
        emit DeploymentPauseToggled(deploymentPaused);
    }
    
    /**
     * @notice Collect accumulated fees
     */
    function collectFees() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) return;
        
        (bool success, ) = owner().call{value: balance}("");
        if (!success) revert TransferFailed();
        
        emit FeeCollected(owner(), balance);
    }
    
    /**
     * @notice Emergency withdraw of any ERC20 tokens sent to factory
     */
    function emergencyWithdrawToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }
    
    /**
     * @notice Receive ETH
     */
    receive() external payable {}
}