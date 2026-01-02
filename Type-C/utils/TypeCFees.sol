// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.0.5
// - 0.0.5: Ensured fee acc and fee claims use opposite tokens. Fixed denormalization on fee claims. 
// - 0.0.4: Fixed incorrect canonical pair function by fetching from Uniswap. 
// - v0.0.3: Refactored claimFees into _getClaimContext, _calculateFeeShare, _executeClaim.
// - 0.0.2: Added direct feeClaiming, streamlined dFeesAcc update logic. 
// Fee template for managing liquidity pair fees independently from liquidity template

import "../imports/ReentrancyGuard.sol"; //Imports and inherits ownable 

interface IERC20 {
    function decimals() external view returns (uint8);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ILiquidityTemplate {
    struct Slot {
        address token;
        address pairedToken;
        address depositor;
        address recipient;
        uint256 allocation;
        uint256 timestamp;
    }
    
    function getSlotView(address token, uint256 index) external view returns (Slot memory slot);
    function getPairLiquidity(address token, address pairedToken) external view returns (uint256);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract TypeCFees is ReentrancyGuard  {
	mapping(address router => bool isRouter) public routers;
    address[] private routerAddresses;
    address uniswapV2Factory;
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
event FeeClaimed(address indexed token0, address indexed token1, address indexed depositor, uint256 slotIndex, uint256 amount);
event UniswapFactorySet(address indexed factory);
    
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
    
    function setUniswapV2Factory(address _factory) external onlyOwner {
        require(_factory != address(0), "Invalid factory address");
        uniswapV2Factory = _factory;
        emit UniswapFactorySet(_factory);
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
 * @notice Initialize dFeesAcc for a new depositor slot. Restricted to routers.
 * @dev Called when a new liquidity slot is created
 *      Fees are tracked for the OPPOSITE token (pairedToken, not the deposited token)
 * @param tokenA First token in the pair (deposited token)
 * @param tokenB Second token in the pair (paired token - this is what fees are paid in)
 * @param depositor Depositor address
 * @param slotIndex Slot index in liquidity template
 */
function initializeDepositorFeesAcc(
    address tokenA, 
    address tokenB, 
    address depositor, 
    uint256 slotIndex
) external {
    require(routers[msg.sender], "Router only");
    require(depositor != address(0), "Invalid depositor");
    
    // Get canonical ordering - but we want fees from the OPPOSITE token (tokenB)
    (address token0, address token1) = getCanonicalPair(tokenA, tokenB);
    
    // Set dFeesAcc to current feesAcc for this pair
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
    function getCanonicalPair(address tokenA, address tokenB) internal view returns (address token0, address token1) {
    require(tokenA != tokenB, "Identical tokens");
    require(uniswapV2Factory != address(0), "Factory not set");
    
    // Get the actual Uniswap pair
    address pair = IUniswapV2Factory(uniswapV2Factory).getPair(tokenA, tokenB);
    require(pair != address(0), "Pair does not exist");
    
    // Get the canonical ordering from the pair itself
    token0 = IUniswapV2Pair(pair).token0();
    token1 = IUniswapV2Pair(pair).token1();
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

// --- Updated Internal Helpers for claimFees ---

function _getClaimContext(
    address liquidityAddress,
    address token,
    uint256 index
) internal view returns (address token0, address token1, address depositor, uint256 allocation, address feeToken) {
    ILiquidityTemplate.Slot memory slot = ILiquidityTemplate(liquidityAddress).getSlotView(token, index);
    require(slot.depositor == msg.sender, "Not slot owner");
    require(slot.allocation > 0, "No allocation");

    // Ensure we use the canonical pair ordering 
    (token0, token1) = getCanonicalPair(slot.token, slot.pairedToken);
    
    // Determine which token to pay fees in (the OPPOSITE of what was deposited)
    // If slot.token matches token0, fees should be paid in token1, and vice versa
    feeToken = (slot.token == token0) ? token1 : token0;
    
    return (token0, token1, slot.depositor, slot.allocation, feeToken);
}

function _calculateFeeShare(
    address token0,
    address token1,
    address depositor,
    uint256 slotIndex,
    uint256 allocation,
    address liquidityAddress
) internal view returns (uint256 feeShare, uint256 currentFeesAcc) {
    // We need the total liquidity for THIS specific pair bucket from the template
    uint256 poolLiquidity = ILiquidityTemplate(liquidityAddress).getPairLiquidity(token0, token1);
    require(poolLiquidity > 0, "Pool has no liquidity");

    FeeDetails storage details = pairFees[token0][token1];
    currentFeesAcc = details.feesAcc;
    uint256 lastFeesAcc = depositorFeesAcc[token0][token1][depositor][slotIndex];

    if (currentFeesAcc <= lastFeesAcc) return (0, currentFeesAcc);

    // Standard fee sharing logic: (currentAcc - lastAcc) * userAllocation / totalPool
    uint256 diff = currentFeesAcc - lastFeesAcc;
    feeShare = (diff * allocation) / poolLiquidity;

    return (feeShare, currentFeesAcc);
}

function _executeClaim(
    address token0,
    address token1,
    address depositor,
    uint256 slotIndex,
    uint256 feeShare,
    uint256 currentFeesAcc,
    address feeToken
) internal {
    if (feeShare == 0) return;

    // 1. Update the snapshot BEFORE the transfer (reentrancy/double-claim protection)
    depositorFeesAcc[token0][token1][depositor][slotIndex] = currentFeesAcc;
    
    // 2. Deduct from the pool's claimable fee balance
    require(pairFees[token0][token1].fees >= feeShare, "Insufficient fee balance");
    pairFees[token0][token1].fees -= feeShare;

    // 3. Denormalize feeShare to the actual token decimals before transfer
    uint256 actualAmount;
    if (feeToken == address(0)) {
        // ETH is already 18 decimals, no denormalization needed
        actualAmount = feeShare;
        (bool success, ) = payable(depositor).call{value: actualAmount}("");
        require(success, "ETH fee transfer failed");
    } else {
        // Get token decimals and denormalize
        uint8 decimals = IERC20(feeToken).decimals();
        actualAmount = denormalize(feeShare, decimals);
        require(IERC20(feeToken).transfer(depositor, actualAmount), "Token fee transfer failed");
    }

    emit FeeClaimed(token0, token1, depositor, slotIndex, feeShare);
}

// --- Main Entry Point ---

function claimFees(
    address liquidityAddress,
    address token,
    uint256 index
) external nonReentrant {
    // Part 1: Gather data (now includes feeToken)
    (address t0, address t1, address dep, uint256 alloc, address feeToken) = _getClaimContext(liquidityAddress, token, index);
    
    // Part 2: Math
    (uint256 share, uint256 acc) = _calculateFeeShare(t0, t1, dep, index, alloc, liquidityAddress);
    
    // Part 3: State & Transfer (now uses feeToken)
    _executeClaim(t0, t1, dep, index, share, acc, feeToken);
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