// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.2.0
// Changes:
// - v0.2.0: Refactored to monolithic template. Removed agent/listing dependencies, made token-specific.
//           Added token address to Slot struct, reorganized storage by token address.
//           Made all liquidity and slot operations token-aware.

import "../imports/Ownable.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface ITokenRegistry {
    function initializeBalances(address token, address[] memory users) external;
}

interface ICCGlobalizer {
    function globalizeLiquidity(address depositor, address token) external;
}

contract CCLiquidityTemplate is Ownable {
    mapping(address router => bool isRouter) public routers;
    address[] private routerAddresses;
    
    address public uniswapV2Factory;
    address public registryAddress;
    address public globalizerAddress;
    
    // Per-token liquidity details: token => LiquidityDetails
    mapping(address => LiquidityDetails) private liquidityDetail;
    
    // Per-token slot storage: token => slotID => Slot
    mapping(address => mapping(uint256 => Slot)) private liquiditySlots;
    
    // Per-token active slots: token => slotIDs[]
    mapping(address => uint256[]) private activeSlots;
    
    // Per-token user indices: token => user => slotIDs[]
    mapping(address => mapping(address => uint256[])) private userSlotIndices;

    struct LiquidityDetails {
        uint256 liquid;      // Available liquidity
        uint256 fees;        // Accumulated fees
        uint256 feesAcc;     // Cumulative fees accumulator
    }

    struct Slot {
        address token;       // Token for this slot
        address depositor;   // Slot owner
        address recipient;   // Withdrawal recipient
        uint256 allocation;  // Allocated amount
        uint256 dFeesAcc;    // Depositor's fee accumulator snapshot
        uint256 timestamp;   // Creation timestamp
    }

    struct UpdateType {
        uint8 updateType;    // 0: liquid, 1: fees (add), 2: slot alloc, 3: slot depositor, 4: slot dFeesAcc, 5: fees (subtract)
        address token;       // Token address
        uint256 index;       // Slot index or 0 for liquid/fees
        uint256 value;       // Value to set/add/subtract
        address addr;        // Address for depositor changes
        address recipient;   // Recipient for slot
    }

    event LiquidityUpdated(address indexed token, uint256 liquid);
    event FeesUpdated(address indexed token, uint256 fees);
    event SlotDepositorChanged(address indexed token, uint256 indexed slotIndex, address indexed oldDepositor, address newDepositor);
    event GlobalizeUpdateFailed(address indexed depositor, address indexed token, uint256 amount, bytes reason);
    event UpdateRegistryFailed(address indexed depositor, address indexed token, bytes reason);
    event TransactFailed(address indexed depositor, address token, uint256 amount, string reason);
    event RouterAdded(address indexed router);
    event RouterRemoved(address indexed router);
    event RegistryAddressSet(address indexed registry);
    event GlobalizerAddressSet(address indexed globalizer);
    event UniswapFactorySet(address indexed factory);
    event TokensWithdrawn(address indexed token, address indexed recipient, uint256 amount);

    function normalize(uint256 amount, uint8 decimals) internal pure returns (uint256 normalizedAmount) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * 10 ** (18 - decimals);
        return amount / 10 ** (decimals - 18);
    }

    function denormalize(uint256 amount, uint8 decimals) internal pure returns (uint256 denormalizedAmount) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount / 10 ** (18 - decimals);
        return amount * 10 ** (decimals - 18);
    }

    function removePendingOrder(uint256[] storage orders, uint256 orderId) internal {
        for (uint256 i = 0; i < orders.length; i++) {
            if (orders[i] == orderId) {
                orders[i] = orders[orders.length - 1];
                orders.pop();
                break;
            }
        }
    }

    function globalizeUpdate(address depositor, address token, uint256 amount) internal {
        if (globalizerAddress != address(0)) {
            try ICCGlobalizer(globalizerAddress).globalizeLiquidity(depositor, token) {
            } catch (bytes memory reason) {
                emit GlobalizeUpdateFailed(depositor, token, amount, reason);
            }
        }
        
        if (registryAddress != address(0)) {
            address[] memory users = new address[](1);
            users[0] = depositor;
            try ITokenRegistry(registryAddress).initializeBalances(token, users) {
            } catch (bytes memory reason) {
                emit UpdateRegistryFailed(depositor, token, reason);
            }
        }
    }

    // Sets Uniswap V2 Factory address, restricted to owner
    function setUniswapV2Factory(address _factory) external onlyOwner {
        require(_factory != address(0), "Invalid factory address");
        uniswapV2Factory = _factory;
        emit UniswapFactorySet(_factory);
    }

    // Sets registry address, restricted to owner
    function setRegistry(address _registryAddress) external onlyOwner {
        require(_registryAddress != address(0), "Invalid registry address");
        registryAddress = _registryAddress;
        emit RegistryAddressSet(_registryAddress);
    }

    // Sets globalizer address, restricted to owner
    function setGlobalizerAddress(address _globalizerAddress) external onlyOwner {
        require(_globalizerAddress != address(0), "Invalid globalizer address");
        globalizerAddress = _globalizerAddress;
        emit GlobalizerAddressSet(_globalizerAddress);
    }

    // Adds a router address, restricted to owner
    function addRouter(address router) external onlyOwner {
        require(router != address(0), "Invalid router address");
        require(!routers[router], "Router already exists");
        routers[router] = true;
        routerAddresses.push(router);
        emit RouterAdded(router);
    }

    // Removes a router address, restricted to owner
    function removeRouter(address router) external onlyOwner {
        require(router != address(0), "Invalid router address");
        require(routers[router], "Router does not exist");
        routers[router] = false;
        for (uint256 i = 0; i < routerAddresses.length; i++) {
            if (routerAddresses[i] == router) {
                routerAddresses[i] = routerAddresses[routerAddresses.length - 1];
                routerAddresses.pop();
                break;
            }
        }
        emit RouterRemoved(router);
    }

    // Allows routers to withdraw any token held by this contract
    function withdrawToken(address token, uint256 amount, address recipient) external {
        require(routers[msg.sender], "Caller not router");
        require(recipient != address(0), "Invalid recipient");
        require(amount > 0, "Invalid amount");
        
        if (token == address(0)) {
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool success, ) = recipient.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            require(IERC20(token).balanceOf(address(this)) >= amount, "Insufficient token balance");
            require(IERC20(token).transfer(recipient, amount), "Token transfer failed");
        }
        
        emit TokensWithdrawn(token, recipient, amount);
    }

    function transactToken(address depositor, address token, uint256 amount, address recipient) external {
        require(routers[msg.sender], "Router only");
        require(token != address(0), "Use transactNative for ETH");
        require(amount > 0, "Zero amount");
        require(recipient != address(0), "Invalid recipient");
        
        uint8 decimals = IERC20(token).decimals();
        require(decimals > 0, "Invalid token decimals");
        
        uint256 normalizedAmount = normalize(amount, decimals);
        require(liquidityDetail[token].liquid >= normalizedAmount, "Insufficient liquidity");
        
        try IERC20(token).transfer(recipient, amount) returns (bool) {
        } catch (bytes memory reason) {
            emit TransactFailed(depositor, token, amount, "Token transfer failed");
            revert("Token transfer failed");
        }
    }

    function transactNative(address depositor, uint256 amount, address recipient) external {
        require(routers[msg.sender], "Router only");
        require(amount > 0, "Zero amount");
        require(recipient != address(0), "Invalid recipient");
        
        uint256 normalizedAmount = normalize(amount, 18);
        require(liquidityDetail[address(0)].liquid >= normalizedAmount, "Insufficient liquidity");
        
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) {
            emit TransactFailed(depositor, address(0), amount, "ETH transfer failed");
            revert("ETH transfer failed");
        }
    }

    function ccUpdate(address depositor, UpdateType[] memory updates) external {
        require(routers[msg.sender], "Router only");
        
        for (uint256 i = 0; i < updates.length; i++) {
            UpdateType memory u = updates[i];
            LiquidityDetails storage details = liquidityDetail[u.token];
            
            if (u.updateType == 0) {
                // Updates liquid directly
                details.liquid = u.value;
                emit LiquidityUpdated(u.token, details.liquid);
            } else if (u.updateType == 1) {
                // Adds to fees
                details.fees += u.value;
                details.feesAcc += u.value;
                emit FeesUpdated(u.token, details.fees);
            } else if (u.updateType == 2) {
                // Updates slot allocation
                Slot storage slot = liquiditySlots[u.token][u.index];
                
                if (slot.depositor == address(0) && u.addr != address(0)) {
                    // Initialize new slot
                    slot.token = u.token;
                    slot.depositor = u.addr;
                    slot.recipient = u.recipient != address(0) ? u.recipient : u.addr;
                    slot.timestamp = block.timestamp;
                    slot.dFeesAcc = details.feesAcc;
                    activeSlots[u.token].push(u.index);
                    userSlotIndices[u.token][u.addr].push(u.index);
                } else if (u.addr == address(0)) {
                    // Remove slot
                    address oldDepositor = slot.depositor;
                    slot.depositor = address(0);
                    slot.allocation = 0;
                    slot.dFeesAcc = 0;
                    
                    uint256[] storage userIndices = userSlotIndices[u.token][oldDepositor];
                    for (uint256 j = 0; j < userIndices.length; j++) {
                        if (userIndices[j] == u.index) {
                            userIndices[j] = userIndices[userIndices.length - 1];
                            userIndices.pop();
                            break;
                        }
                    }
                }
                
                uint256 oldAllocation = slot.allocation;
                slot.allocation = u.value;
                
                if (oldAllocation > u.value) {
                    details.liquid -= (oldAllocation - u.value);
                } else {
                    details.liquid += (u.value - oldAllocation);
                }
                
                emit LiquidityUpdated(u.token, details.liquid);
                globalizeUpdate(depositor, u.token, u.value);
            } else if (u.updateType == 3) {
                // Updates slot depositor without modifying allocation
                Slot storage slot = liquiditySlots[u.token][u.index];
                require(slot.depositor == depositor, "Depositor not slot owner");
                require(u.addr != address(0), "Invalid new depositor");
                require(slot.allocation > 0, "Invalid slot allocation");
                
                address oldDepositor = slot.depositor;
                slot.depositor = u.addr;
                
                uint256[] storage oldUserIndices = userSlotIndices[u.token][oldDepositor];
                for (uint256 j = 0; j < oldUserIndices.length; j++) {
                    if (oldUserIndices[j] == u.index) {
                        oldUserIndices[j] = oldUserIndices[oldUserIndices.length - 1];
                        oldUserIndices.pop();
                        break;
                    }
                }
                
                userSlotIndices[u.token][u.addr].push(u.index);
                emit SlotDepositorChanged(u.token, u.index, oldDepositor, u.addr);
            } else if (u.updateType == 4) {
                // Updates slot dFeesAcc for fee claims
                Slot storage slot = liquiditySlots[u.token][u.index];
                require(slot.depositor == depositor, "Depositor not slot owner");
                slot.dFeesAcc = u.value;
            } else if (u.updateType == 5) {
                // Subtracts from fees
                require(details.fees >= u.value, "Insufficient fees");
                details.fees -= u.value;
                emit FeesUpdated(u.token, details.fees);
            } else {
                revert("Invalid update type");
            }
        }
    }

    // View functions
    function routerAddressesView() external view returns (address[] memory) {
        return routerAddresses;
    }

    function liquidityAmounts(address token) external view returns (uint256 amount) {
        return liquidityDetail[token].liquid;
    }

    function liquidityDetailsView(address token) external view returns (uint256 liquid, uint256 fees, uint256 feesAcc) {
        LiquidityDetails memory details = liquidityDetail[token];
        return (details.liquid, details.fees, details.feesAcc);
    }

    function userSlotIndicesView(address token, address user) external view returns (uint256[] memory indices) {
        return userSlotIndices[token][user];
    }

    function getActiveSlots(address token) external view returns (uint256[] memory slots) {
        return activeSlots[token];
    }

    function getSlotView(address token, uint256 index) external view returns (Slot memory slot) {
        return liquiditySlots[token][index];
    }
    
    // Allows contract to receive ETH
    receive() external payable {}
}