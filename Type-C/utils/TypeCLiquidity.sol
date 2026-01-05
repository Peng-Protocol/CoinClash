// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.0.6
// Changes:
// - v0.0.6: Ensured slot data uses per pair mapping, updated deposit, withdrawal, depositor change and view function usage. 
// - v0.0.5: Added dFeesAcc initialization. Added direct liquidity ownership transfer. 
// - v0.0.4: Implemented ccDeposit/ccWithdraw; secured payouts with pair isolation.
// - v0.0.3: Pair-isolated liquidity tracking.

import "../imports/ReentrancyGuard.sol";

interface IERC20 {
    function decimals() external view returns (uint8);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ITokenRegistry {
    function initializeBalances(address token, address[] memory users) external;
}

interface ICCGlobalizer {
    function globalizeLiquidity(address depositor, address token) external;
}

interface ICCFeeTemplate {
    function initializeDepositorFeesAcc(
        address tokenA, 
        address tokenB, 
        address depositor, 
        uint256 slotIndex
    ) external;
}

contract TypeCLiquidity is ReentrancyGuard {
    // --- Access Control ---
    mapping(address router => bool isRouter) public routers;
    address[] private routerAddresses;
    
    // --- Configuration ---
    address public uniswapV2Factory;
    address public registryAddress;
    address public globalizerAddress;
    address public feeTemplateAddress;

    // --- Liquidity Storage ---
    
    // Per-pair liquidity tracking: token => pairedToken => Amount
    // This isolates liquidity pools so JUNK/USDT cannot drain ETH/USDT
    mapping(address => mapping(address => uint256)) public pairLiquidity;

// 0.0.6

// Per-token per-pair slot storage: token => pairedToken => slotID => Slot
mapping(address => mapping(address => mapping(uint256 => Slot))) private liquiditySlots;

// Per-token per-pair active slots: token => pairedToken => slotIDs[]
mapping(address => mapping(address => uint256[])) private activeSlots;

// Per-token per-pair user indices: token => pairedToken => user => slotIDs[]
mapping(address => mapping(address => mapping(address => uint256[]))) private userSlotIndices;

    struct Slot {
        address token;
        address pairedToken; // Tracks the isolation bucket
        address depositor;
        address recipient;
        uint256 allocation;
        uint256 timestamp;
    }

    // --- Payout Storage ---
    struct Payout {
        uint256 id;
        address recipient;
        address token;
        address pairedToken; // (New 0.0.4) Required to deduct from correct bucket
        uint256 amountOwed;
        uint256 timestamp;
    }

    uint256 public payoutIdCounter;
    mapping(uint256 => Payout) public payouts;
    mapping(address => uint256[]) private userPayoutIds;

    // --- Events ---
    event LiquidityDeposited(address indexed token, address indexed pairedToken, address indexed depositor, uint256 amount, uint256 slotIndex);
    event LiquidityWithdrawn(address indexed token, address indexed pairedToken, address indexed depositor, uint256 amount, uint256 slotIndex);
    
    event GlobalizeUpdateFailed(address indexed depositor, address indexed token, uint256 amount, bytes reason);
    event UpdateRegistryFailed(address indexed depositor, address indexed token, bytes reason);
    event RouterAdded(address indexed router);
    event RouterRemoved(address indexed router);
    event RegistryAddressSet(address indexed registry);
    event GlobalizerAddressSet(address indexed globalizer);
    event UniswapFactorySet(address indexed factory);
    event FeeTemplateAddressSet(address indexed feeTemplate);
    
    event PayoutCreated(uint256 indexed id, address indexed recipient, address indexed token, uint256 amount);
    event PayoutClaimed(uint256 indexed id, address indexed recipient, uint256 amountPaid, uint256 amountRemaining);
    event SlotDepositorChanged(address indexed token, uint256 indexed slotIndex, address indexed oldDepositor, address newDepositor);

    // --- Admin Functions ---

    function setUniswapV2Factory(address _factory) external onlyOwner {
        require(_factory != address(0), "Invalid factory address");
        uniswapV2Factory = _factory;
        emit UniswapFactorySet(_factory);
    }

    function setRegistry(address _registryAddress) external onlyOwner {
        require(_registryAddress != address(0), "Invalid registry address");
        registryAddress = _registryAddress;
        emit RegistryAddressSet(_registryAddress);
    }

    function setGlobalizerAddress(address _globalizerAddress) external onlyOwner {
        require(_globalizerAddress != address(0), "Invalid globalizer address");
        globalizerAddress = _globalizerAddress;
        emit GlobalizerAddressSet(_globalizerAddress);
    }
    
    function setFeeTemplateAddress(address _feeTemplateAddress) external onlyOwner {
        require(_feeTemplateAddress != address(0), "Invalid fee template address");
        feeTemplateAddress = _feeTemplateAddress;
        emit FeeTemplateAddressSet(_feeTemplateAddress);
    }

    function addRouter(address router) external onlyOwner {
        require(router != address(0), "Invalid router address");
        require(!routers[router], "Router already exists");
        routers[router] = true;
        routerAddresses.push(router);
        emit RouterAdded(router);
    }

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
    
    // --- Core: Deposit (Renamed from deposit -> ccDeposit) ---
    
    /**
     * @notice Deposits tokens into a specific pair bucket.
     * @dev Pulls tokens from caller (Router or User), updates pairLiquidity, and creates a new Slot.
     */
// 0.0.6
function ccDeposit(
    address token, 
    address pairedToken, 
    address depositor, 
    uint256 amount
) external payable nonReentrant {
    require(amount > 0, "Zero amount");
    require(token != pairedToken, "Identical tokens");
    require(depositor != address(0), "Invalid depositor");

    // 1. Execute Transfer / Pull Funds
    uint256 received;
    
    if (token == address(0)) {
        require(msg.value == amount, "ETH amount mismatch");
        received = amount;
    } else {
        require(msg.value == 0, "ETH not expected");
        uint256 preBalance = IERC20(token).balanceOf(address(this));
        
        // Transfer from caller
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        uint256 postBalance = IERC20(token).balanceOf(address(this));
        received = postBalance - preBalance;
    }
    
    require(received > 0, "No tokens received");

    // 2. Update Isolated Liquidity
    pairLiquidity[token][pairedToken] += received;

    // 3. Create Slot (NOW PAIR-ISOLATED)
    uint256 slotIndex = activeSlots[token][pairedToken].length; 
    activeSlots[token][pairedToken].push(slotIndex);

    Slot storage slot = liquiditySlots[token][pairedToken][slotIndex];
    slot.token = token;
    slot.pairedToken = pairedToken;
    slot.depositor = depositor;
    slot.recipient = depositor;
    slot.allocation = received;
    slot.timestamp = block.timestamp;
    
    userSlotIndices[token][pairedToken][depositor].push(slotIndex);

    // 4. External Updates (Graceful Degradation)
    if (globalizerAddress != address(0)) {
        try ICCGlobalizer(globalizerAddress).globalizeLiquidity(depositor, token) {
            // Success
        } catch (bytes memory reason) {
            emit GlobalizeUpdateFailed(depositor, token, received, reason);
        }
    }
    
    if (registryAddress != address(0)) {
        address[] memory users = new address[](1);
        users[0] = depositor;
        try ITokenRegistry(registryAddress).initializeBalances(token, users) {
            // Success
        } catch (bytes memory reason) {
            emit UpdateRegistryFailed(depositor, token, reason);
        }
    }
    
    // Initialize dFeesAcc in fee template for new slot
    if (feeTemplateAddress != address(0)) {
        try ICCFeeTemplate(feeTemplateAddress).initializeDepositorFeesAcc(
            token,
            pairedToken,
            depositor,
            slotIndex
        ) {
            // Success
        } catch (bytes memory reason) {
            emit GlobalizeUpdateFailed(depositor, token, received, reason);
        }
    }

    emit LiquidityDeposited(token, pairedToken, depositor, received, slotIndex); 
}

    // --- Core: Withdraw (New ccWithdraw) ---

    /**
     * @notice Withdraws tokens from a specific slot.
     * @dev Decreases slot allocation and the specific pairLiquidity bucket.
     * @param token The token to withdraw.
     * @param index The slot index to withdraw from.
     * @param amount The amount to withdraw.
     */
    // 0.0.6

function ccWithdraw(
    address token,
    address pairedToken,
    uint256 index,
    uint256 amount
) external nonReentrant {
    require(amount > 0, "Zero amount");
    
    Slot storage slot = liquiditySlots[token][pairedToken][index];
    require(slot.depositor == msg.sender, "Not slot owner");
    require(slot.allocation >= amount, "Insufficient allocation");
    
    require(pairLiquidity[token][pairedToken] >= amount, "Insufficient pair liquidity");

    // 1. Update State
    slot.allocation -= amount;
    pairLiquidity[token][pairedToken] -= amount;

    // 2. Transfer
    if (token == address(0)) {
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    } else {
        require(IERC20(token).transfer(msg.sender, amount), "Token transfer failed");
    }

    emit LiquidityWithdrawn(token, pairedToken, msg.sender, amount, index);
}
    
    /**
     * @notice Donates tokens to a specific pair bucket without creating a liquidity slot.
     * @dev Increases pairLiquidity directly; tokens are non-refundable to the caller.
     * @param token The token being donated.
     * @param pairedToken The token it is paired with (the isolation bucket).
     * @param amount The amount to donate.
     */
    function ccDonate(
        address token, 
        address pairedToken, 
        uint256 amount
    ) external payable nonReentrant {
        require(amount > 0, "Zero amount");
        require(token != pairedToken, "Identical tokens");

        uint256 received;
        
        if (token == address(0)) {
            require(msg.value == amount, "ETH amount mismatch");
            received = amount;
        } else {
            require(msg.value == 0, "ETH not expected");
            uint256 preBalance = IERC20(token).balanceOf(address(this));
            
            // Pull tokens from the caller (e.g., driver, router, or liquidator)
            require(IERC20(token).transferFrom(msg.sender, address(this), amount), "Transfer failed");
            
            uint256 postBalance = IERC20(token).balanceOf(address(this));
            received = postBalance - preBalance;
        }
        
        require(received > 0, "No tokens received");

        // Increase the isolated bucket balance
        pairLiquidity[token][pairedToken] += received;

        // Note: No Slot created, no Globalizer/Registry calls needed as there is no depositor.
        emit LiquidityDeposited(token, pairedToken, address(0), received, type(uint256).max);
    }

/**
 * @notice Changes the depositor of a liquidity slot.
 * @dev Only the current depositor can change to a new depositor.
 * @param token The token of the slot.
 * @param slotIndex The slot index to modify.
 * @param newDepositor The new depositor address.
 */
// 0.0.6

function changeDepositor(
    address token,
    address pairedToken,
    uint256 slotIndex,
    address newDepositor
) external nonReentrant {
    require(newDepositor != address(0), "Invalid new depositor");
    
    Slot storage slot = liquiditySlots[token][pairedToken][slotIndex];
    require(slot.depositor == msg.sender, "Not slot owner");
    require(slot.allocation > 0, "Invalid slot");
    
    address oldDepositor = slot.depositor;
    
    // Update slot depositor and recipient
    slot.depositor = newDepositor;
    slot.recipient = newDepositor;
    
    // Update user indices - remove from old depositor
    uint256[] storage oldIndices = userSlotIndices[token][pairedToken][oldDepositor];
    for (uint256 i = 0; i < oldIndices.length; i++) {
        if (oldIndices[i] == slotIndex) {
            oldIndices[i] = oldIndices[oldIndices.length - 1];
            oldIndices.pop();
            break;
        }
    }
    
    // Add to new depositor
    userSlotIndices[token][pairedToken][newDepositor].push(slotIndex);
    
    emit SlotDepositorChanged(token, slotIndex, oldDepositor, newDepositor);
}

    // --- Core: Settlement (Payouts) ---

    struct SettlementUpdate {
        address recipient;
        address token;
        address pairedToken; // (New 0.0.4)
        uint256 amount;
    }

    function ssUpdate(SettlementUpdate[] calldata updates) external {
        require(routers[msg.sender], "Router only");
        for (uint256 i = 0; i < updates.length; i++) {
            payoutIdCounter++;
            uint256 id = payoutIdCounter;

            Payout storage p = payouts[id];
            p.id = id;
            p.recipient = updates[i].recipient;
            p.token = updates[i].token;
            p.pairedToken = updates[i].pairedToken; // Set the bucket
            p.amountOwed = updates[i].amount;
            p.timestamp = block.timestamp;

            userPayoutIds[updates[i].recipient].push(id);

            emit PayoutCreated(id, updates[i].recipient, updates[i].token, updates[i].amount);
        }
    }
    
    function processPayout(uint256 payoutId, uint256 amount) external nonReentrant {
        Payout storage p = payouts[payoutId];
        require(p.amountOwed > 0, "Payout fully claimed or invalid");
        require(amount > 0, "Zero amount");
        require(amount <= p.amountOwed, "Amount exceeds debt");

        // (New 0.0.4) Check Pair Liquidity Bucket instead of global balance
        require(pairLiquidity[p.token][p.pairedToken] >= amount, "Insufficient pair liquidity");

        // Update State
        p.amountOwed -= amount;
        pairLiquidity[p.token][p.pairedToken] -= amount;

        // Transfer
        if (p.token == address(0)) {
            (bool success, ) = p.recipient.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            require(IERC20(p.token).transfer(p.recipient, amount), "Token transfer failed");
        }

        emit PayoutClaimed(payoutId, p.recipient, amount, p.amountOwed);
    }

    // --- Utility: Helpers ---

    function normalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * 10 ** (18 - decimals);
        return amount / 10 ** (decimals - 18);
    }

    // --- Views ---

    function routerAddressesView() external view returns (address[] memory) {
        return routerAddresses;
    }

    function liquidityAmounts(address token) external view returns (uint256 amount) {
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }
    
    function liquidityDetailsView(address token) external view returns (uint256 liquid) {
        if (token == address(0)) return address(this).balance;
        return IERC20(token).balanceOf(address(this));
    }

    function getPairLiquidity(address token, address pairedToken) external view returns (uint256) {
        return pairLiquidity[token][pairedToken];
    }

    // 0.0.6
function userSlotIndicesView(address token, address pairedToken, address user) external view returns (uint256[] memory indices) {
    return userSlotIndices[token][pairedToken][user];
}

// 0.0.6
function getActiveSlots(address token, address pairedToken) external view returns (uint256[] memory slots) {
    return activeSlots[token][pairedToken];
}

// 0.0.6
function getSlotView(address token, address pairedToken, uint256 index) external view returns (Slot memory slot) {
    return liquiditySlots[token][pairedToken][index];
}
    
    function getPayout(uint256 id) external view returns (Payout memory) {
        return payouts[id];
    }

    function getUserPayoutIds(address user) external view returns (uint256[] memory) {
        return userPayoutIds[user];
    }
    
    receive() external payable {}
}