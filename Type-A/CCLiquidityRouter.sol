// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// Version: 0.2.1
// Changes:
// - v0.2.1: Added compensationToken parameter to withdraw function. Router now verifies pair exists
//           between withdrawal token and compensation token, and calculates conversion using prices.
// - v0.2.0: Refactored for monolithic template structure. Added token parameters to all functions.
//           Removed agent/listing dependencies. Functions now operate on specific tokens.
//           Merged CCMainPartial logic into CCLiquidityPartial.

import "./utils/CCLiquidityPartial.sol";

contract CCLiquidityRouter is CCLiquidityPartial {
    event DepositTokenFailed(address indexed depositor, address token, uint256 amount, string reason);
    event DepositNativeFailed(address indexed depositor, uint256 amount, string reason);

    function depositNativeToken(address liquidityAddress, address depositor, uint256 amount) external payable nonReentrant {
        // Deposits ETH to liquidity pool for specified depositor, supports zero-balance initialization
        _depositNative(liquidityAddress, depositor, amount);
    }

    function depositToken(address liquidityAddress, address token, address depositor, uint256 amount) external nonReentrant {
        // Deposits ERC20 tokens to liquidity pool for specified depositor, supports zero-balance initialization
        _depositToken(liquidityAddress, token, depositor, amount);
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
        _executeWithdrawal(liquidityAddress, token, compensationToken, msg.sender, index, withdrawal);
    }

    function claimFees(address liquidityAddress, address token, uint256 liquidityIndex) external nonReentrant {
        // Claims fees from liquidity pool for msg.sender
        _processFeeShare(liquidityAddress, token, msg.sender, liquidityIndex);
    }

    function changeDepositor(address liquidityAddress, address token, uint256 slotIndex, address newDepositor) external nonReentrant {
        // Changes depositor for a liquidity slot for msg.sender
        _changeDepositor(liquidityAddress, token, msg.sender, slotIndex, newDepositor);
    }
}