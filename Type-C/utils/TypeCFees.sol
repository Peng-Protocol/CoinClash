// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.0.1
// Fee template for managing liquidity pair fees independently from liquidity template

import "../imports/Ownable.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract TypeCFees is Ownable {
	mapping(address router => bool isRouter) public routers;
    address[] private routerAddresses;
    // Per-token pair fee tracking: tokenA => tokenB => FeeDetails
    // Canonical ordering: address(tokenA) < address(tokenB)
    mapping(address => mapping(address => FeeDetails)) private pairFees;
    
    // Per-token feesAcc for backwards compatibility with slots: token => feesAcc
    mapping(address => uint256) private tokenFeesAcc;
    
// Per-pair, per-depositor fee accumulator snapshots: tokenA => tokenB => depositor => slotIndex => dFeesAcc
mapping(address => mapping(address => mapping(address => mapping(uint256 => uint256)))) private depositorFeesAcc;
    
    struct FeeDetails {
        uint256 fees;        // Accumulated fees for this pair
        uint256 feesAcc;     // Cumulative fees accumulator for this pair
    }
    
    event FeesAdded(address indexed tokenA, address indexed tokenB, address indexed caller, uint256 amount);
    event FeesWithdrawn(address indexed tokenA, address indexed tokenB, address indexed recipient, uint256 amount);
    event TokenFeesAccUpdated(address indexed token, uint256 feesAcc);
    event RouterAdded(address indexed router);
    event RouterRemoved(address indexed router);
event DepositorFeesAccUpdated(address indexed tokenA, address indexed tokenB, address indexed depositor, uint256 slotIndex, uint256 dFeesAcc);
    
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
    
    function routerAddressesView() external view returns (address[] memory) {
        return routerAddresses;
    }
    
    
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
    
/**
 * @notice Initialize dFeesAcc for a new depositor slot. Restricted to owner (router).
 * @dev Called when a new liquidity slot is created
 * @param tokenA First token in the pair
 * @param tokenB Second token in the pair
 * @param depositor Depositor address
 * @param slotIndex Slot index in liquidity template
 */
function initializeDepositorFeesAcc(
    address tokenA, 
    address tokenB, 
    address depositor, 
    uint256 slotIndex
) external onlyOwner {
    require(depositor != address(0), "Invalid depositor");
    
    (address token0, address token1) = getCanonicalPair(tokenA, tokenB);
    
    // Set dFeesAcc to current feesAcc for this pair
    uint256 currentFeesAcc = pairFees[token0][token1].feesAcc;
    depositorFeesAcc[token0][token1][depositor][slotIndex] = currentFeesAcc;
    
    emit DepositorFeesAccUpdated(token0, token1, depositor, slotIndex, currentFeesAcc);
}

/**
 * @notice Update dFeesAcc for a depositor after claiming fees. Restricted to owner (router).
 * @dev Called after successful fee claim to update the snapshot
 * @param tokenA First token in the pair
 * @param tokenB Second token in the pair
 * @param depositor Depositor address
 * @param slotIndex Slot index in liquidity template
 */
function updateDepositorFeesAcc(
    address tokenA, 
    address tokenB, 
    address depositor, 
    uint256 slotIndex
) external onlyOwner {
    require(depositor != address(0), "Invalid depositor");
    
    (address token0, address token1) = getCanonicalPair(tokenA, tokenB);
    
    // Update to current feesAcc for this pair
    uint256 currentFeesAcc = pairFees[token0][token1].feesAcc;
    depositorFeesAcc[token0][token1][depositor][slotIndex] = currentFeesAcc;
    
    emit DepositorFeesAccUpdated(token0, token1, depositor, slotIndex, currentFeesAcc);
}

/**
 * @notice Get depositor's fee accumulator snapshot for a pair and slot
 * @param tokenA First token in the pair
 * @param tokenB Second token in the pair
 * @param depositor Depositor address
 * @param slotIndex Slot index
 * @return dFeesAcc Depositor's fee accumulator snapshot
 */
function getDepositorFeesAcc(
    address tokenA, 
    address tokenB, 
    address depositor, 
    uint256 slotIndex
) external view returns (uint256 dFeesAcc) {
    (address token0, address token1) = getCanonicalPair(tokenA, tokenB);
    return depositorFeesAcc[token0][token1][depositor][slotIndex];
}

    // Returns canonical ordering of token pair
    function getCanonicalPair(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "Identical tokens");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /**
     * @notice Adds fees to a token pair. Anyone can call this function.
     * @dev Withdraws tokens from caller and adds to fee accumulator for the pair.
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair (can be address(0) for ETH pairs)
     * @param amount Amount of fees to add (in token decimals)
     */
    function addFees(address tokenA, address tokenB, uint256 amount) external payable {
        require(amount > 0, "Zero amount");
        
        // Get canonical pair ordering
        (address token0, address token1) = getCanonicalPair(tokenA, tokenB);
        
        // Handle ETH pairs specially
        if (token0 == address(0)) {
            require(msg.value == amount, "ETH amount mismatch");
            uint256 normalizedAmount = normalize(amount, 18);
            
            FeeDetails storage details = pairFees[token0][token1];
            details.fees += normalizedAmount;
            details.feesAcc += normalizedAmount;
            
            // Update token-level feesAcc for both tokens in pair
            tokenFeesAcc[token0] += normalizedAmount;
            tokenFeesAcc[token1] += normalizedAmount;
            
            emit FeesAdded(token0, token1, msg.sender, normalizedAmount);
            emit TokenFeesAccUpdated(token0, tokenFeesAcc[token0]);
            emit TokenFeesAccUpdated(token1, tokenFeesAcc[token1]);
        } else {
            require(msg.value == 0, "ETH not expected");
            
            // Transfer tokens from caller
            uint8 decimals = IERC20(token0).decimals();
            require(decimals > 0, "Invalid token decimals");
            
            require(IERC20(token0).transferFrom(msg.sender, address(this), amount), "Transfer failed");
            
            uint256 normalizedAmount = normalize(amount, decimals);
            
            FeeDetails storage details = pairFees[token0][token1];
            details.fees += normalizedAmount;
            details.feesAcc += normalizedAmount;
            
            // Update token-level feesAcc for both tokens in pair
            tokenFeesAcc[token0] += normalizedAmount;
            tokenFeesAcc[token1] += normalizedAmount;
            
            emit FeesAdded(token0, token1, msg.sender, normalizedAmount);
            emit TokenFeesAccUpdated(token0, tokenFeesAcc[token0]);
            emit TokenFeesAccUpdated(token1, tokenFeesAcc[token1]);
        }
    }

    /**
     * @notice Withdraws fees from a token pair. Restricted to routers.
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @param amount Amount to withdraw (in normalized 18 decimal format)
     * @param recipient Address to receive the fees
     */
    function withdrawFees(address tokenA, address tokenB, uint256 amount, address recipient) external {
     require(routers[msg.sender], "Router only");
     require(amount > 0, "Zero amount");
        require(recipient != address(0), "Invalid recipient");
        
        // Get canonical pair ordering
        (address token0, address token1) = getCanonicalPair(tokenA, tokenB);
        
        FeeDetails storage details = pairFees[token0][token1];
        require(details.fees >= amount, "Insufficient fees");
        
        details.fees -= amount;
        
        // Handle ETH withdrawal
        if (token0 == address(0)) {
            uint256 ethAmount = denormalize(amount, 18);
            (bool success, ) = recipient.call{value: ethAmount}("");
            require(success, "ETH transfer failed");
        } else {
            // Handle ERC20 withdrawal
            uint8 decimals = IERC20(token0).decimals();
            uint256 tokenAmount = denormalize(amount, decimals);
            require(IERC20(token0).transfer(recipient, tokenAmount), "Token transfer failed");
        }
        
        emit FeesWithdrawn(token0, token1, recipient, amount);
    }

    /**
     * @notice Manually update token-level feesAcc. Restricted to owner.
     * @dev Used by liquidity template to sync feesAcc when needed
     * @param token Token address to update
     * @param feesAcc New feesAcc value
     */
    function updateTokenFeesAcc(address token, uint256 feesAcc) external onlyOwner {
        tokenFeesAcc[token] = feesAcc;
        emit TokenFeesAccUpdated(token, feesAcc);
    }

    // View functions
    
    /**
     * @notice Get fee details for a token pair
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @return fees Current accumulated fees
     * @return feesAcc Cumulative fee accumulator
     */
    function getPairFees(address tokenA, address tokenB) external view returns (uint256 fees, uint256 feesAcc) {
        (address token0, address token1) = getCanonicalPair(tokenA, tokenB);
        FeeDetails memory details = pairFees[token0][token1];
        return (details.fees, details.feesAcc);
    }

    /**
     * @notice Get token-level feesAcc for backwards compatibility
     * @param token Token address
     * @return feesAcc Cumulative fee accumulator for this token
     */
    function getFeesAcc(address token) external view returns (uint256) {
        return tokenFeesAcc[token];
    }

    /**
     * @notice Get only the accumulated fees for a pair
     * @param tokenA First token in the pair
     * @param tokenB Second token in the pair
     * @return fees Current accumulated fees
     */
    function getPairFeesAmount(address tokenA, address tokenB) external view returns (uint256 fees) {
        (address token0, address token1) = getCanonicalPair(tokenA, tokenB);
        return pairFees[token0][token1].fees;
    }
    
    // Allows contract to receive ETH
    receive() external payable {}
}