// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.0.1 (29/12/2025)
// Changes:
// - v0.0.1 (29/12): Added support for new fee template.

import "../imports/IERC20.sol";
import "../imports/ReentrancyGuard.sol";

interface ICCLiquidity {
    struct UpdateType {
        uint8 updateType; // 0: liquid, 1: fees (add), 2: slot alloc, 3: slot depositor, 4: slot dFeesAcc, 5: fees (subtract)
        address token;
        uint256 index;
        uint256 value;
        address addr;
        address recipient;
    }

struct Slot {
    address token;
    address depositor;
    address recipient;
    uint256 allocation;
    uint256 timestamp;
}

    struct PreparedWithdrawal {
        uint256 primaryAmount;
        uint256 compensationAmount;
    }

    function ccUpdate(address depositor, UpdateType[] memory updates) external;
    function transactToken(address depositor, address token, uint256 amount, address recipient) external;
    function transactNative(address depositor, uint256 amount, address recipient) external;
    function liquidityAmounts(address token) external view returns (uint256 amount);
    
function liquidityDetailsView(address token) external view returns (uint256 liquid);  // updated to match new template structure. 

    function userSlotIndicesView(address token, address user) external view returns (uint256[] memory);
    function getSlotView(address token, uint256 index) external view returns (Slot memory);
    function getActiveSlots(address token) external view returns (uint256[] memory slots);
}

// new fee template 
// Replace ICCFeeTemplate interface (around line 52)
interface ICCFeeTemplate {
    function getPairFees(address tokenA, address tokenB) external view returns (uint256 fees, uint256 feesAcc);
    function withdrawFees(address tokenA, address tokenB, uint256 amount, address recipient) external;
    function getDepositorFeesAcc(address tokenA, address tokenB, address depositor, uint256 slotIndex) external view returns (uint256 dFeesAcc);
    function initializeDepositorFeesAcc(address tokenA, address tokenB, address depositor, uint256 slotIndex) external;
    function updateDepositorFeesAcc(address tokenA, address tokenB, address depositor, uint256 slotIndex) external;
}

interface ICCListing {
    function prices(address tokenA, address tokenB) external view returns (uint256);
    function uniswapV2Factory() external view returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract CCLiquidityPartial is ReentrancyGuard {
    event TransferFailed(address indexed sender, address indexed token, uint256 amount, bytes reason);
    event DepositFailed(address indexed depositor, address token, uint256 amount, string reason);
    event FeesClaimed(address indexed liquidityAddress, address indexed token, uint256 liquidityIndex, uint256 fees);
    event SlotDepositorChanged(address indexed token, uint256 indexed slotIndex, address indexed oldDepositor, address newDepositor);
    event DepositReceived(address indexed depositor, address token, uint256 amount, uint256 normalizedAmount);
    error InsufficientAllowance(address sender, address token, uint256 required, uint256 available);
    event WithdrawalFailed(address indexed depositor, address indexed liquidityAddress, address indexed token, uint256 slotIndex, uint256 amount, string reason);
    event CompensationCalculated(address indexed depositor, address indexed liquidityAddress, address indexed primaryToken, address compensationToken, uint256 primaryAmount, uint256 compensationAmount);
    event NoFeesToClaim(address indexed depositor, address indexed liquidityAddress, address indexed token, uint256 liquidityIndex);
    event FeeValidationFailed(address indexed depositor, address indexed liquidityAddress, address indexed token, uint256 liquidityIndex, string reason);
    event ValidationFailed(address indexed depositor, address indexed liquidityAddress, address indexed token, uint256 index, string reason);
    event TransferSuccessful(address indexed depositor, address indexed liquidityAddress, address indexed token, uint256 index, uint256 amount);

    struct WithdrawalContext {
    address liquidityAddress;
    address listingAddress; // Added
    address token;
    address compensationToken;
    address depositor;
    uint256 index;
    uint256 primaryAmount;
    uint256 compensationAmount;
    uint256 currentAllocation;
    uint256 totalAllocationDeduct;
    uint256 price;
}

struct DepositContext {
    address liquidityAddress;
    address depositor;
    address token;
    address pairedToken;     // Added for fee template initialization
    uint256 inputAmount;
    uint256 receivedAmount;
    uint256 normalizedAmount;
    uint256 index;
}

    // uses new fee template
struct FeeClaimCore {
    address liquidityAddress;
    address feeTemplateAddress;
    address token;
    address pairedToken;
    address depositor;
    uint256 liquidityIndex;
    uint256 feeShare;
}

struct FeeClaimDetails {
    uint256 liquid;
    uint256 fees;
    uint256 feesAcc;
    uint256 allocation;
    uint256 dFeesAcc;      // Now fetched from fee template
}
    
    struct WithdrawalPrepCore {
        address liquidityAddress;
        address listingAddress;
        address token;
        address compensationToken;
        address depositor;
        uint256 outputAmount;
        uint256 compensationAmount;
        uint256 index;
    }

    struct WithdrawalPrepState {
        ICCLiquidity.Slot slot;
        uint256 totalAllocationNeeded;
        address factory;
        uint256 price;
        bool hasCompensation;
    }
    
    function normalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        else if (decimals < 18) return amount * 10 ** (uint256(18) - uint256(decimals));
        else return amount / 10 ** (uint256(decimals) - uint256(18));
    }

    function denormalize(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        else if (decimals < 18) return amount / 10 ** (uint256(18) - uint256(decimals));
        else return amount * 10 ** (uint256(decimals) - uint256(18));
    }
    
    // For fetching canonical pair

function _getTokenPair(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
    require(tokenA != tokenB, "Identical tokens");
    (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
}

// (0.0.1) 
function _validateDeposit(
    address liquidityAddress, 
    address token, 
    address pairedToken,
    address depositor, 
    uint256 inputAmount
) internal view returns (DepositContext memory) {
    ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress);
    uint256[] memory activeSlots = liquidityContract.getActiveSlots(token);
    return DepositContext({
        liquidityAddress: liquidityAddress,
        depositor: depositor,
        token: token,
        pairedToken: pairedToken,
        inputAmount: inputAmount,
        receivedAmount: 0,
        normalizedAmount: 0,
        index: activeSlots.length
    });
}

    function _executeTokenTransfer(DepositContext memory context) internal returns (DepositContext memory) {
        require(context.token != address(0), "Use depositNative for ETH");
        address depositInitiator = msg.sender;
        uint256 allowance = IERC20(context.token).allowance(depositInitiator, address(this));
        if (allowance < context.inputAmount) revert InsufficientAllowance(depositInitiator, context.token, context.inputAmount, allowance);
        
        uint256 preBalanceRouter = IERC20(context.token).balanceOf(address(this));
        try IERC20(context.token).transferFrom(depositInitiator, address(this), context.inputAmount) {
        } catch (bytes memory reason) {
            emit TransferFailed(depositInitiator, context.token, context.inputAmount, reason);
            revert("TransferFrom failed");
        }
        uint256 postBalanceRouter = IERC20(context.token).balanceOf(address(this));
        context.receivedAmount = postBalanceRouter - preBalanceRouter;
        require(context.receivedAmount > 0, "No tokens received");
        
        uint256 preBalanceTemplate = IERC20(context.token).balanceOf(context.liquidityAddress);
        try IERC20(context.token).transfer(context.liquidityAddress, context.receivedAmount) {
        } catch (bytes memory reason) {
            emit TransferFailed(address(this), context.token, context.receivedAmount, reason);
            revert("Transfer to liquidity template failed");
        }
        uint256 postBalanceTemplate = IERC20(context.token).balanceOf(context.liquidityAddress);
        context.receivedAmount = postBalanceTemplate - preBalanceTemplate;
        require(context.receivedAmount > 0, "No tokens received by liquidity template");
        
        uint8 decimals = IERC20(context.token).decimals();
        context.normalizedAmount = normalize(context.receivedAmount, decimals);
        return context;
    }

    function _executeNativeTransfer(DepositContext memory context) internal returns (DepositContext memory) {
        require(context.token == address(0), "Use depositToken for ERC20");
        address depositInitiator = msg.sender;
        require(context.inputAmount == msg.value, "Incorrect ETH amount");
        
        uint256 preBalanceTemplate = context.liquidityAddress.balance;
        (bool success, bytes memory reason) = context.liquidityAddress.call{value: context.inputAmount}("");
        if (!success) {
            emit TransferFailed(depositInitiator, address(0), context.inputAmount, reason);
            revert("ETH transfer to liquidity template failed");
        }
        uint256 postBalanceTemplate = context.liquidityAddress.balance;
        context.receivedAmount = postBalanceTemplate - preBalanceTemplate;
        require(context.receivedAmount > 0, "No ETH received by liquidity template");
        context.normalizedAmount = normalize(context.receivedAmount, 18);
        return context;
    }

    // 0.0.1
function _updateDeposit(DepositContext memory context, address feeTemplateAddress) internal {
    ICCLiquidity liquidityContract = ICCLiquidity(context.liquidityAddress);
    ICCLiquidity.UpdateType[] memory updates = new ICCLiquidity.UpdateType[](1);
    updates[0] = ICCLiquidity.UpdateType(2, context.token, context.index, context.normalizedAmount, context.depositor, address(0));
    try liquidityContract.ccUpdate(context.depositor, updates) {
    } catch (bytes memory reason) {
        emit DepositFailed(context.depositor, context.token, context.receivedAmount, string(reason));
        revert(string(abi.encodePacked("Deposit update failed: ", reason)));
    }
    
    // Initialize dFeesAcc in fee template for new slot
    if (feeTemplateAddress != address(0) && context.pairedToken != address(0)) {
        try ICCFeeTemplate(feeTemplateAddress).initializeDepositorFeesAcc(
            context.token, 
            context.pairedToken, 
            context.depositor, 
            context.index
        ) {
        } catch (bytes memory reason) {
            emit DepositFailed(context.depositor, context.token, context.receivedAmount, string(abi.encodePacked("Fee template init failed: ", reason)));
            revert(string(abi.encodePacked("Fee template initialization failed: ", reason)));
        }
    }
    
    emit DepositReceived(context.depositor, context.token, context.receivedAmount, context.normalizedAmount);
}

    // 0.0.1
function _depositToken(
    address liquidityAddress, 
    address token, 
    address pairedToken,
    address depositor, 
    uint256 inputAmount,
    address feeTemplateAddress
) internal returns (uint256) {
    DepositContext memory context = _validateDeposit(liquidityAddress, token, pairedToken, depositor, inputAmount);
    context = _executeTokenTransfer(context);
    _updateDeposit(context, feeTemplateAddress);
    return context.receivedAmount;
}

// 0.0.1
function _depositNative(
    address liquidityAddress, 
    address pairedToken,
    address depositor, 
    uint256 inputAmount,
    address feeTemplateAddress
) internal {
    DepositContext memory context = _validateDeposit(liquidityAddress, address(0), pairedToken, depositor, inputAmount);
    context = _executeNativeTransfer(context);
    _updateDeposit(context, feeTemplateAddress);
}

        // Helper: basic ownership & allocation validation
    function _validateWithdrawalSlot(WithdrawalPrepCore memory core) internal returns (ICCLiquidity.Slot memory slot) {
        ICCLiquidity liquidityContract = ICCLiquidity(core.liquidityAddress);
        slot = liquidityContract.getSlotView(core.token, core.index);

        if (slot.depositor != core.depositor) {
            emit ValidationFailed(core.depositor, core.liquidityAddress, core.token, core.index, "Not slot owner");
            return slot; // zeroed slot signals failure downstream
        }
        if (slot.allocation == 0) {
            emit ValidationFailed(core.depositor, core.liquidityAddress, core.token, core.index, "No allocation");
        }
    }

    // Helper: pair existence check
    function _checkCompensationPair(WithdrawalPrepCore memory core, WithdrawalPrepState memory state) internal returns (bool) {
        if (!state.hasCompensation) return true;

        ICCListing listingContract = ICCListing(core.listingAddress);
        try listingContract.uniswapV2Factory() returns (address _factory) {
            state.factory = _factory;
        } catch (bytes memory reason) {
            emit ValidationFailed(core.depositor, core.liquidityAddress, core.token, core.index,
                string(abi.encodePacked("Factory fetch failed: ", reason)));
            return false;
        }

        address pair = IUniswapV2Factory(state.factory).getPair(core.token, core.compensationToken);
        if (pair == address(0)) {
            emit ValidationFailed(core.depositor, core.liquidityAddress, core.token, core.index, "No pair exists between tokens");
            return false;
        }
        return true;
    }

// Canonical price calculation
// Helper: price fetch - always fetch prices(A,B) where A < B canonically
function _fetchCompensationPrice(WithdrawalPrepCore memory core, WithdrawalPrepState memory state) internal returns (bool) {
    if (!state.hasCompensation) return true;

    // Get canonical ordering: token0 < token1
    (address token0, address token1) = _getTokenPair(core.token, core.compensationToken);
    
    ICCListing listingContract = ICCListing(core.listingAddress);
    // Always fetch prices(token0, token1) = token1/token0
    try listingContract.prices(token0, token1) returns (uint256 _price) {
        state.price = _price;
    } catch (bytes memory reason) {
        emit ValidationFailed(core.depositor, core.liquidityAddress, core.token, core.index,
            string(abi.encodePacked("Price fetch failed: ", reason)));
        return false;
    }

    if (state.price == 0) {
        emit ValidationFailed(core.depositor, core.liquidityAddress, core.token, core.index, "Price is zero");
        return false;
    }
    return true;
}

// 
// Helper: allocation calculation with compensation conversion
// price from prices(A,B) = B/A
// Convert B to A: A_output = B_amount / price
// Convert A to B: B_output = A_amount * price
function _calculateAllocationNeeded(WithdrawalPrepCore memory core, WithdrawalPrepState memory state, ICCLiquidity.Slot memory slot) internal pure returns (uint256) {
    uint256 needed = core.outputAmount;

    if (state.hasCompensation) {
        (address token0, address token1) = _getTokenPair(core.token, core.compensationToken);
        // price = token1/token0
        
        if (core.compensationToken == token1) {
            // Converting token1 (B) to token0 (A): A = B / price
            uint256 converted = (core.compensationAmount * 1e18) / state.price;
            needed += converted;
        } else {
            // Converting token0 (A) to token1 (B): B = A * price
            uint256 converted = (core.compensationAmount * state.price) / 1e18;
            needed += converted;
        }
    }

    if (needed > slot.allocation) {
        return type(uint256).max;
    }
    return needed;
}

    //

// FIXED empty return statement and setup. 

function _prepWithdrawal(
    address liquidityAddress, 
    address listingAddress,
    address token,
    address compensationToken,
    address depositor, 
    uint256 outputAmount, 
    uint256 compensationAmount, 
    uint256 index
) internal returns (ICCLiquidity.PreparedWithdrawal memory) {
    
    // --- PATCH START: Normalize compensation input ---
    uint256 normalizedCompensation = compensationAmount;
    if (compensationAmount > 0) {
        uint8 decimals = compensationToken == address(0) ? 18 : IERC20(compensationToken).decimals();
        normalizedCompensation = normalize(compensationAmount, decimals);
    }
    // --- PATCH END ---

    WithdrawalPrepCore memory core = WithdrawalPrepCore({
        liquidityAddress: liquidityAddress,
        listingAddress: listingAddress,
        token: token,
        compensationToken: compensationToken,
        depositor: depositor,
        outputAmount: outputAmount,
        compensationAmount: normalizedCompensation,
        index: index
    });

    // Validate slot ownership and allocation
    ICCLiquidity.Slot memory slot = _validateWithdrawalSlot(core);
    if (slot.depositor == address(0) || slot.allocation == 0) {
        return ICCLiquidity.PreparedWithdrawal(0, 0);
    }

    // Initialize state
    WithdrawalPrepState memory state;
    state.slot = slot;
    state.hasCompensation = (compensationToken != address(0) && normalizedCompensation > 0);

    // Check pair if compensation is involved
    if (!_checkCompensationPair(core, state)) {
        return ICCLiquidity.PreparedWithdrawal(0, 0);
    }

    // Fetch price if compensation is involved
    if (!_fetchCompensationPrice(core, state)) {
        return ICCLiquidity.PreparedWithdrawal(0, 0);
    }

    // Calculate total allocation needed
    state.totalAllocationNeeded = _calculateAllocationNeeded(core, state, slot);
    if (state.totalAllocationNeeded == type(uint256).max) {
        emit ValidationFailed(core.depositor, core.liquidityAddress, core.token, core.index, "Insufficient allocation");
        return ICCLiquidity.PreparedWithdrawal(0, 0);
    }

    // RETURN THE PREPARED WITHDRAWAL
    return ICCLiquidity.PreparedWithdrawal({
        primaryAmount: core.outputAmount,
        compensationAmount: normalizedCompensation
    });
}

    function _executeWithdrawal(
    address liquidityAddress, 
    address listingAddress, // Added argument
    address token,
    address compensationToken,
    address depositor, 
    uint256 index, 
    ICCLiquidity.PreparedWithdrawal memory withdrawal
) internal {
    WithdrawalContext memory context = WithdrawalContext({
        liquidityAddress: liquidityAddress,
        listingAddress: listingAddress, // Set here
        token: token,
        compensationToken: compensationToken,
        depositor: depositor,
        index: index,
        primaryAmount: withdrawal.primaryAmount,
        compensationAmount: withdrawal.compensationAmount,
        currentAllocation: 0,
        totalAllocationDeduct: 0,
        price: 0
    });
    if (!_fetchWithdrawalData(context)) return;
    _transferWithdrawalAmount(context);
    require(_updateWithdrawalAllocation(context), "Allocation update failed"); //strictly revert
}

    function _fetchWithdrawalData(WithdrawalContext memory context) internal view returns (bool) {
        ICCLiquidity liquidityContract = ICCLiquidity(context.liquidityAddress);
        
        ICCLiquidity.Slot memory slot = liquidityContract.getSlotView(context.token, context.index);
        context.currentAllocation = slot.allocation;
        
        return true;
    }

   // updated

function _updateWithdrawalAllocation(WithdrawalContext memory context) internal returns (bool) {
    uint256 totalDeduct = context.primaryAmount;

    if (context.compensationAmount > 0) {
        // Get canonical ordering and fetch price
        (address token0, address token1) = _getTokenPair(context.token, context.compensationToken);
        
        ICCListing listing = ICCListing(context.listingAddress);
        // Always fetch prices(token0, token1) = token1/token0
        try listing.prices(token0, token1) returns (uint256 _price) {
            context.price = _price;
        } catch {
            emit WithdrawalFailed(context.depositor, context.liquidityAddress, context.token, context.index, context.primaryAmount, "Price fetch failed during update");
            return false;
        }

        if (context.price == 0) {
             emit WithdrawalFailed(context.depositor, context.liquidityAddress, context.token, context.index, context.primaryAmount, "Zero price during update");
             return false;
        }

        // Convert compensation to primary token equivalent
        // price = token1/token0
        uint256 compensationInPrimary;
        
        if (context.compensationToken == token1) {
            // Converting token1 (B) to token0 (A): A = B / price
            compensationInPrimary = (context.compensationAmount * 1e18) / context.price;
        } else {
            // Converting token0 (A) to token1 (B): B = A * price
            compensationInPrimary = (context.compensationAmount * context.price) / 1e18;
        }
        
        totalDeduct += compensationInPrimary;
        
        emit CompensationCalculated(context.depositor, context.liquidityAddress, context.token, context.compensationToken, context.primaryAmount, context.compensationAmount);
    }

    if (totalDeduct > context.currentAllocation) {
         emit WithdrawalFailed(context.depositor, context.liquidityAddress, context.token, context.index, context.primaryAmount, "Allocation underflow during update");
         return false;
    }

    if (totalDeduct > 0) {
        ICCLiquidity.UpdateType[] memory updates = new ICCLiquidity.UpdateType[](1);
        updates[0] = ICCLiquidity.UpdateType(2, context.token, context.index, context.currentAllocation - totalDeduct, context.depositor, address(0));
        
        try ICCLiquidity(context.liquidityAddress).ccUpdate(context.depositor, updates) {
        } catch (bytes memory reason) {
            emit WithdrawalFailed(context.depositor, context.liquidityAddress, context.token, context.index, context.primaryAmount, string(abi.encodePacked("Slot update failed: ", reason)));
            return false;
        }
    }
    return true;
}

    function _transferWithdrawalAmount(WithdrawalContext memory context) internal {
        ICCLiquidity liquidityTemplate = ICCLiquidity(context.liquidityAddress);
        bool primarySuccess = false;
        bool compensationSuccess = true;

        // Transfer primary amount in withdrawal token
        if (context.primaryAmount > 0) {
            uint8 decimals = context.token == address(0) ? 18 : IERC20(context.token).decimals();
            uint256 denormalizedAmount = denormalize(context.primaryAmount, decimals);
            if (context.token == address(0)) {
                try liquidityTemplate.transactNative(context.depositor, denormalizedAmount, context.depositor) {
                    emit TransferSuccessful(context.depositor, context.liquidityAddress, context.token, context.index, denormalizedAmount);
                    primarySuccess = true;
                } catch (bytes memory reason) {
                    emit WithdrawalFailed(context.depositor, context.liquidityAddress, context.token, context.index, context.primaryAmount, string(abi.encodePacked("Native transfer failed: ", reason)));
                }
            } else {
                try liquidityTemplate.transactToken(context.depositor, context.token, denormalizedAmount, context.depositor) {
                    emit TransferSuccessful(context.depositor, context.liquidityAddress, context.token, context.index, denormalizedAmount);
                    primarySuccess = true;
                } catch (bytes memory reason) {
                    emit WithdrawalFailed(context.depositor, context.liquidityAddress, context.token, context.index, context.primaryAmount, string(abi.encodePacked("Token transfer failed: ", reason)));
                }
            }
        }

        // Transfer compensation amount in compensation token
        if (context.compensationAmount > 0) {
            uint8 decimals = context.compensationToken == address(0) ? 18 : IERC20(context.compensationToken).decimals();
            uint256 denormalizedAmount = denormalize(context.compensationAmount, decimals);
            if (context.compensationToken == address(0)) {
                try liquidityTemplate.transactNative(context.depositor, denormalizedAmount, context.depositor) {
                    emit TransferSuccessful(context.depositor, context.liquidityAddress, context.compensationToken, context.index, denormalizedAmount);
                    compensationSuccess = true;
                } catch (bytes memory reason) {
                    emit WithdrawalFailed(context.depositor, context.liquidityAddress, context.compensationToken, context.index, context.compensationAmount, string(abi.encodePacked("Native compensation transfer failed: ", reason)));
                    compensationSuccess = false;
                }
            } else {
                try liquidityTemplate.transactToken(context.depositor, context.compensationToken, denormalizedAmount, context.depositor) {
                    emit TransferSuccessful(context.depositor, context.liquidityAddress, context.compensationToken, context.index, denormalizedAmount);
                    compensationSuccess = true;
                } catch (bytes memory reason) {
                    emit WithdrawalFailed(context.depositor, context.liquidityAddress, context.compensationToken, context.index, context.compensationAmount, string(abi.encodePacked("Token compensation transfer failed: ", reason)));
                    compensationSuccess = false;
                }
            }
        }

        if (context.compensationAmount > 0 && !compensationSuccess) {
            revert("Compensation transfer failed, aborting withdrawal to prevent allocation update");
        }

        if (context.primaryAmount > 0 && !primarySuccess) {
            revert("Primary transfer failed, aborting withdrawal to prevent allocation update");
        }
    }

    // uses new fee template
function _fetchLiquidityDetails(address liquidityAddress, address token) private view returns (FeeClaimDetails memory) {
    ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress);
    uint256 liquid = liquidityContract.liquidityDetailsView(token);
    return FeeClaimDetails({
        liquid: liquid,
        fees: 0,      // Fees fetched from fee template
        feesAcc: 0,   // Fees fetched from fee template
        allocation: 0,
        dFeesAcc: 0
    });
}

function _fetchSlotDetails(address liquidityAddress, address token, uint256 liquidityIndex, address depositor) private view returns (FeeClaimDetails memory details) {
    ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress);
    ICCLiquidity.Slot memory slot = liquidityContract.getSlotView(token, liquidityIndex);
    require(slot.depositor == depositor, "Depositor not slot owner");
    details.allocation = slot.allocation;
    details.dFeesAcc = 0;  // Will be fetched from fee template
}

    // Fee template support (0.0.1)
function _validateFeeClaim(
    address liquidityAddress,
    address feeTemplateAddress,
    address token,
    address pairedToken,
    address depositor,
    uint256 liquidityIndex
) internal returns (FeeClaimCore memory, FeeClaimDetails memory) {
    require(depositor != address(0), "Invalid depositor");
    require(feeTemplateAddress != address(0), "Fee template not set");
    require(pairedToken != address(0), "Invalid paired token");
    
    FeeClaimDetails memory details = _fetchLiquidityDetails(liquidityAddress, token);
    require(details.liquid > 0, "No liquidity available");
    
    details = _fetchSlotDetails(liquidityAddress, token, liquidityIndex, depositor);
    require(details.allocation > 0, "No allocation for slot");
    
    // Fetch fees, feesAcc, and dFeesAcc from fee template for this token pair
    ICCFeeTemplate feeTemplate = ICCFeeTemplate(feeTemplateAddress);
    (details.fees, details.feesAcc) = feeTemplate.getPairFees(token, pairedToken);
    details.dFeesAcc = feeTemplate.getDepositorFeesAcc(token, pairedToken, depositor, liquidityIndex);
    
    if (details.fees == 0) {
        emit FeeValidationFailed(depositor, liquidityAddress, token, liquidityIndex, "No fees available");
        revert("No fees available");
    }
    
    return (
        FeeClaimCore({
            liquidityAddress: liquidityAddress,
            feeTemplateAddress: feeTemplateAddress,
            token: token,
            pairedToken: pairedToken,
            depositor: depositor,
            liquidityIndex: liquidityIndex,
            feeShare: 0
        }),
        details
    );
}

    function _calculateFeeShare(FeeClaimCore memory core, FeeClaimDetails memory details) internal pure returns (FeeClaimCore memory) {
        uint256 contributedFees = details.feesAcc > details.dFeesAcc ? details.feesAcc - details.dFeesAcc : 0;
        uint256 liquidityContribution = details.liquid > 0 ? (details.allocation * 1e18) / details.liquid : 0;
        core.feeShare = (contributedFees * liquidityContribution) / 1e18;
        core.feeShare = core.feeShare > details.fees ? details.fees : core.feeShare;
        return core;
    }

    // (0.0.1)
function _executeFeeClaim(FeeClaimCore memory core, FeeClaimDetails memory details) internal {
    if (core.feeShare == 0) {
        emit NoFeesToClaim(core.depositor, core.liquidityAddress, core.token, core.liquidityIndex);
        return;
    }
    
    ICCFeeTemplate feeTemplate = ICCFeeTemplate(core.feeTemplateAddress);
    
    // Update dFeesAcc in fee template (no longer updating liquidity template)
    try feeTemplate.updateDepositorFeesAcc(core.token, core.pairedToken, core.depositor, core.liquidityIndex) {
    } catch (bytes memory reason) {
        revert(string(abi.encodePacked("Fee accumulator update failed: ", reason)));
    }
    
    // Withdraw fees from fee template for the token pair
    try feeTemplate.withdrawFees(core.token, core.pairedToken, core.feeShare, core.depositor) {
    } catch (bytes memory reason) {
        revert(string(abi.encodePacked("Fee withdrawal failed: ", reason)));
    }
    
    emit FeesClaimed(core.liquidityAddress, core.token, core.liquidityIndex, core.feeShare);
}

    // 0.0.1
function _processFeeShare(
    address liquidityAddress,
    address feeTemplateAddress,
    address token,
    address pairedToken,
    address depositor,
    uint256 liquidityIndex
) internal {
    (FeeClaimCore memory core, FeeClaimDetails memory details) = _validateFeeClaim(
        liquidityAddress,
        feeTemplateAddress,
        token,
        pairedToken,
        depositor,
        liquidityIndex
    );
    core = _calculateFeeShare(core, details);
    _executeFeeClaim(core, details);
}

    function _changeDepositor(address liquidityAddress, address token, address depositor, uint256 slotIndex, address newDepositor) internal {
        ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress);
        require(depositor != address(0), "Invalid depositor");
        require(newDepositor != address(0), "Invalid new depositor");
        ICCLiquidity.Slot memory slot = liquidityContract.getSlotView(token, slotIndex);
        require(slot.depositor == depositor, "Depositor not slot owner");
        require(slot.allocation > 0, "Invalid slot");
        ICCLiquidity.UpdateType[] memory updates = new ICCLiquidity.UpdateType[](1);
        updates[0] = ICCLiquidity.UpdateType(3, token, slotIndex, 0, newDepositor, address(0));
        try liquidityContract.ccUpdate(depositor, updates) {
        } catch (bytes memory reason) {
            revert(string(abi.encodePacked("Depositor change failed: ", reason)));
        }
        emit SlotDepositorChanged(token, slotIndex, depositor, newDepositor);
    }

    function uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) return "0";
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        return string(bstr);
    }
}