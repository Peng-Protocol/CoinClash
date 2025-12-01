// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.2.3 (01/12)
// Changes:
// - v0.2.3: Adjusted compensation calculation to fetch listingAddress and use correct conversions. 
// - v0.2.2: Refactored _prepWithdrawal to resolve stack-too-deep error via call-tree decomposition.
//           Split validation, pair check, price fetch, and conversion into isolated internal helpers.
//           All state passed explicitly via structs; no function exceeds 16 stack slots.
// - v0.2.1: Added compensation token logic. Validates pair exists between withdrawal token and compensation token.
//           Calculates conversion using prices from listing template. Updates allocation accounting for converted compensation.
//           Added ICCListing interface for price queries.
// - v0.2.0: Refactored for monolithic template structure. All functions now token-specific.
//           Merged CCMainPartial functionality. Removed agent/listing dependencies.
//           Updated all contexts and validation to work with token addresses directly.

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
        uint256 dFeesAcc;
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
    function liquidityDetailsView(address token) external view returns (uint256 liquid, uint256 fees, uint256 feesAcc);
    function userSlotIndicesView(address token, address user) external view returns (uint256[] memory);
    function getSlotView(address token, uint256 index) external view returns (Slot memory);
    function getActiveSlots(address token) external view returns (uint256[] memory slots);
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
        uint256 inputAmount;
        uint256 receivedAmount;
        uint256 normalizedAmount;
        uint256 index;
    }

    struct FeeClaimCore {
        address liquidityAddress;
        address token;
        address depositor;
        uint256 liquidityIndex;
        uint256 feeShare;
    }

    struct FeeClaimDetails {
        uint256 liquid;
        uint256 fees;
        uint256 feesAcc;
        uint256 allocation;
        uint256 dFeesAcc;
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

    function _validateDeposit(address liquidityAddress, address token, address depositor, uint256 inputAmount) internal view returns (DepositContext memory) {
        ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress);
        uint256[] memory activeSlots = liquidityContract.getActiveSlots(token);
        return DepositContext({
            liquidityAddress: liquidityAddress,
            depositor: depositor,
            token: token,
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

    function _updateDeposit(DepositContext memory context) internal {
        ICCLiquidity liquidityContract = ICCLiquidity(context.liquidityAddress);
        ICCLiquidity.UpdateType[] memory updates = new ICCLiquidity.UpdateType[](1);
        updates[0] = ICCLiquidity.UpdateType(2, context.token, context.index, context.normalizedAmount, context.depositor, address(0));
        try liquidityContract.ccUpdate(context.depositor, updates) {
        } catch (bytes memory reason) {
            emit DepositFailed(context.depositor, context.token, context.receivedAmount, string(reason));
            revert(string(abi.encodePacked("Deposit update failed: ", reason)));
        }
        emit DepositReceived(context.depositor, context.token, context.receivedAmount, context.normalizedAmount);
    }

    function _depositToken(address liquidityAddress, address token, address depositor, uint256 inputAmount) internal returns (uint256) {
        DepositContext memory context = _validateDeposit(liquidityAddress, token, depositor, inputAmount);
        context = _executeTokenTransfer(context);
        _updateDeposit(context);
        return context.receivedAmount;
    }

    function _depositNative(address liquidityAddress, address depositor, uint256 inputAmount) internal {
        DepositContext memory context = _validateDeposit(liquidityAddress, address(0), depositor, inputAmount);
        context = _executeNativeTransfer(context);
        _updateDeposit(context);
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

    // Helper: price fetch
    function _fetchCompensationPrice(WithdrawalPrepCore memory core, WithdrawalPrepState memory state) internal returns (bool) {
        if (!state.hasCompensation) return true;

        ICCListing listingContract = ICCListing(core.listingAddress);
        try listingContract.prices(core.token, core.compensationToken) returns (uint256 _price) {
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

    // Helper: allocation calculation with compensation conversion
    function _calculateAllocationNeeded(WithdrawalPrepCore memory core, WithdrawalPrepState memory state, ICCLiquidity.Slot memory slot) internal pure returns (uint256) {
        uint256 needed = core.outputAmount;

        if (state.hasCompensation) {
            // price = compensationToken / token  =>  token_equiv = compensationAmount / price
            uint256 converted = (core.compensationAmount * 1e18) / state.price;
            needed += converted;
        }

        if (needed > slot.allocation) {
            // Emit will be handled by caller; here we just return oversized value
            return type(uint256).max;
        }
        return needed;
    }

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
        WithdrawalPrepCore memory core = WithdrawalPrepCore({
            liquidityAddress: liquidityAddress,
            listingAddress: listingAddress,
            token: token,
            compensationToken: compensationToken,
            depositor: depositor,
            outputAmount: outputAmount,
            compensationAmount: compensationAmount,
            index: index
        });

        ICCLiquidity.Slot memory slot = _validateWithdrawalSlot(core);
        if (slot.depositor == address(0) || slot.allocation == 0) {
            return ICCLiquidity.PreparedWithdrawal(0, 0);
        }

        WithdrawalPrepState memory state;
        state.hasCompensation = compensationAmount > 0;

        if (state.hasCompensation) {
            require(compensationToken != address(0) || token != address(0), "Cannot compensate between two native tokens");
            require(compensationToken != token, "Compensation token must differ from withdrawal token");

            if (!_checkCompensationPair(core, state)) {
                return ICCLiquidity.PreparedWithdrawal(0, 0);
            }
            if (!_fetchCompensationPrice(core, state)) {
                return ICCLiquidity.PreparedWithdrawal(0, 0);
            }
        }

        uint256 totalNeeded = _calculateAllocationNeeded(core, state, slot);
        if (totalNeeded == type(uint256).max || totalNeeded > slot.allocation) {
            emit ValidationFailed(depositor, liquidityAddress, token, index, "Insufficient allocation for output and compensation");
            return ICCLiquidity.PreparedWithdrawal(0, 0);
        }

        return ICCLiquidity.PreparedWithdrawal({
            primaryAmount: outputAmount,
            compensationAmount: compensationAmount
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
    if (!_updateWithdrawalAllocation(context)) return;
}

    function _fetchWithdrawalData(WithdrawalContext memory context) internal view returns (bool) {
        ICCLiquidity liquidityContract = ICCLiquidity(context.liquidityAddress);
        
        ICCLiquidity.Slot memory slot = liquidityContract.getSlotView(context.token, context.index);
        context.currentAllocation = slot.allocation;
        
        return true;
    }

   function _updateWithdrawalAllocation(WithdrawalContext memory context) internal returns (bool) {
    // Calculate deduction in terms of Primary Token
    uint256 totalDeduct = context.primaryAmount;

    if (context.compensationAmount > 0) {
        // Fetch price again to ensure accurate allocation update
        ICCListing listing = ICCListing(context.listingAddress);
        try listing.prices(context.token, context.compensationToken) returns (uint256 _price) {
            context.price = _price;
        } catch {
            emit WithdrawalFailed(context.depositor, context.liquidityAddress, context.token, context.index, context.primaryAmount, "Price fetch failed during update");
            return false;
        }

        if (context.price == 0) {
             emit WithdrawalFailed(context.depositor, context.liquidityAddress, context.token, context.index, context.primaryAmount, "Zero price during update");
             return false;
        }

        // Convert Compensation (Token B) -> Equivalent Primary (Token A)
        // Price = Token B / Token A  =>  Token A = Token B / Price
        // Both sides normalized to 1e18 by helper, so standard formula applies
        uint256 compensationInPrimary = (context.compensationAmount * 1e18) / context.price;
        
        totalDeduct += compensationInPrimary;
        
        emit CompensationCalculated(context.depositor, context.liquidityAddress, context.token, context.compensationToken, context.primaryAmount, context.compensationAmount);
    }

    // Safety check to prevent underflow if price fluctuated wildly between prep and execute
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

    function _fetchLiquidityDetails(address liquidityAddress, address token) private view returns (FeeClaimDetails memory) {
        ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress);
        (uint256 liquid, uint256 fees, uint256 feesAcc) = liquidityContract.liquidityDetailsView(token);
        return FeeClaimDetails({
            liquid: liquid,
            fees: fees,
            feesAcc: feesAcc,
            allocation: 0,
            dFeesAcc: 0
        });
    }

    function _fetchSlotDetails(address liquidityAddress, address token, uint256 liquidityIndex, address depositor) private view returns (FeeClaimDetails memory details) {
        ICCLiquidity liquidityContract = ICCLiquidity(liquidityAddress);
        ICCLiquidity.Slot memory slot = liquidityContract.getSlotView(token, liquidityIndex);
        require(slot.depositor == depositor, "Depositor not slot owner");
        details.allocation = slot.allocation;
        details.dFeesAcc = slot.dFeesAcc;
    }

    function _validateFeeClaim(address liquidityAddress, address token, address depositor, uint256 liquidityIndex) internal returns (FeeClaimCore memory, FeeClaimDetails memory) {
        require(depositor != address(0), "Invalid depositor");
        FeeClaimDetails memory details = _fetchLiquidityDetails(liquidityAddress, token);
        require(details.liquid > 0, "No liquidity available");
        details = _fetchSlotDetails(liquidityAddress, token, liquidityIndex, depositor);
        require(details.allocation > 0, "No allocation for slot");
        if (details.fees == 0) {
            emit FeeValidationFailed(depositor, liquidityAddress, token, liquidityIndex, "No fees available");
            revert("No fees available");
        }
        return (
            FeeClaimCore({
                liquidityAddress: liquidityAddress,
                token: token,
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

    function _executeFeeClaim(FeeClaimCore memory core, FeeClaimDetails memory details) internal {
        if (core.feeShare == 0) {
            emit NoFeesToClaim(core.depositor, core.liquidityAddress, core.token, core.liquidityIndex);
            return;
        }
        ICCLiquidity liquidityContract = ICCLiquidity(core.liquidityAddress);
        ICCLiquidity.UpdateType[] memory updates = new ICCLiquidity.UpdateType[](2);
        updates[0] = ICCLiquidity.UpdateType(5, core.token, 0, core.feeShare, address(0), address(0));
        updates[1] = ICCLiquidity.UpdateType(4, core.token, core.liquidityIndex, details.feesAcc, core.depositor, address(0));
        try liquidityContract.ccUpdate(core.depositor, updates) {
        } catch (bytes memory reason) {
            revert(string(abi.encodePacked("Fee claim update failed: ", reason)));
        }
        uint8 decimals = core.token == address(0) ? 18 : IERC20(core.token).decimals();
        uint256 denormalizedFee = denormalize(core.feeShare, decimals);
        if (core.token == address(0)) {
            try liquidityContract.transactNative(core.depositor, denormalizedFee, core.depositor) {
            } catch (bytes memory reason) {
                revert(string(abi.encodePacked("Fee claim transfer failed: ", reason)));
            }
        } else {
            try liquidityContract.transactToken(core.depositor, core.token, denormalizedFee, core.depositor) {
            } catch (bytes memory reason) {
                revert(string(abi.encodePacked("Fee claim transfer failed: ", reason)));
            }
        }
        emit FeesClaimed(core.liquidityAddress, core.token, core.liquidityIndex, core.feeShare);
    }

    function _processFeeShare(address liquidityAddress, address token, address depositor, uint256 liquidityIndex) internal {
        (FeeClaimCore memory core, FeeClaimDetails memory details) = _validateFeeClaim(liquidityAddress, token, depositor, liquidityIndex);
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