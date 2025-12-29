// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.0.1 (29/12/2025)
// Changes:
// - v0.0.1: Fee template integration.

import "./utils/TypeCLiquidityPartial.sol";

contract CCLiquidityRouter is CCLiquidityPartial {
    event DepositTokenFailed(address indexed depositor, address token, uint256 amount, string reason);
    event DepositNativeFailed(address indexed depositor, uint256 amount, string reason);
    
    // New fee template variable and event. 
address public feeTemplateAddress;

event FeeTemplateAddressSet(address indexed feeTemplate);

// New fee template setter. 
function setFeeTemplateAddress(address _feeTemplateAddress) external {
    require(msg.sender == owner(), "Owner only");
    require(_feeTemplateAddress != address(0), "Invalid fee template address");
    feeTemplateAddress = _feeTemplateAddress;
    emit FeeTemplateAddressSet(_feeTemplateAddress);
}

    // 0.0.1
function depositNativeToken(
    address liquidityAddress, 
    address pairedToken,
    address depositor, 
    uint256 amount
) external payable nonReentrant {
    require(feeTemplateAddress != address(0), "Fee template not set");
    // Deposits ETH to liquidity pool for specified depositor, supports zero-balance initialization
    _depositNative(liquidityAddress, pairedToken, depositor, amount, feeTemplateAddress);
}

    // 0.0.1 uses pairedToken to initialize fee template dFeesAcc
function depositToken(
    address liquidityAddress, 
    address token, 
    address pairedToken,
    address depositor, 
    uint256 amount
) external nonReentrant {
    require(feeTemplateAddress != address(0), "Fee template not set");
    // Deposits ERC20 tokens to liquidity pool for specified depositor, supports zero-balance initialization
    _depositToken(liquidityAddress, token, pairedToken, depositor, amount, feeTemplateAddress);
}

    function withdraw(
        address liquidityAddress, 
        address listingAddress,
        address token, 
        address compensationToken,
        uint256 outputAmount, 
        uint256 compensationAmount, 
        uint256 index
    ) external nonReentrant {
        // Withdraws tokens from liquidity pool for msg.sender, with optional compensation in paired token
        ICCLiquidity.PreparedWithdrawal memory withdrawal = _prepWithdrawal(
            liquidityAddress, 
            listingAddress,
            token,
            compensationToken,
            msg.sender, 
            outputAmount, 
            compensationAmount, 
            index
        );
        // FIXED: Now passing listingAddress to _executeWithdrawal
        _executeWithdrawal(liquidityAddress, listingAddress, token, compensationToken, msg.sender, index, withdrawal);
    }

// uses new fee template 
function claimFees(
    address liquidityAddress, 
    address token, 
    address pairedToken,
    uint256 liquidityIndex
) external nonReentrant {
    require(feeTemplateAddress != address(0), "Fee template not set");
    // Claims fees from liquidity pool for msg.sender
    _processFeeShare(liquidityAddress, feeTemplateAddress, token, pairedToken, msg.sender, liquidityIndex);
}

    function changeDepositor(address liquidityAddress, address token, uint256 slotIndex, address newDepositor) external nonReentrant {
        // Changes depositor for a liquidity slot for msg.sender
        _changeDepositor(liquidityAddress, token, msg.sender, slotIndex, newDepositor);
    }
}