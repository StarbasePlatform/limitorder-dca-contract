/*
    Copyright 2024 StarBase
    SPDX-License-Identifier: Apache-2.0
*/

pragma solidity ^0.8.4;

import { InitializableOwnable } from "./lib/InitializableOwnable.sol";
import { IERC20 } from "./intf/IERC20.sol";
import { SafeERC20 } from "./lib/SafeERC20.sol";
import { IStarBaseRouter } from "./intf/IStarBaseRouter.sol";
import { IStarBaseLimitOrderBot } from "./intf/IStarBaseLimitOrderBot.sol";
import { Common } from "./lib/Common.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IStarBaseLimitOrder } from "./intf/IStarBaseLimitOrder.sol";

/// @title StarBase Limit Order Fulfillment Contract
/// @notice This contract interacts with the StarBase Limit Order contract to fulfill limit orders by swapping tokens and transferring the appropriate amounts.
/// @dev This contract is used to fulfill StarBase limit orders by calling external contracts, validating token amounts, and performing token swaps.

contract StarBaseLimitOrderBot is InitializableOwnable, IStarBaseLimitOrderBot {
    using SafeERC20 for IERC20;

    // ============ Storage ============
    address public _StarBase_LIMIT_ORDER_;
    address public _TOKEN_RECEIVER_;
    mapping(address => bool) public isAdminListed;

    // ============ Events ============
    event AddAdmin(address admin);
    event RemoveAdmin(address admin);
    event ChangeReceiver(address newReceiver);
    event Fill(bytes, address, uint256);
    event ChangeFeeRate(uint160 feeRate);

    constructor(address owner, address tokenReceiver, address[] memory userAddr) {
        Common._validateAddress(tokenReceiver);
        Common._validateAddress(owner);
        initOwner(owner);

        _TOKEN_RECEIVER_ = tokenReceiver;
        emit ChangeReceiver(tokenReceiver);

        for (uint i = 0; i < userAddr.length; i++) {
            isAdminListed[userAddr[i]] = true;
        }
    }

    /// @notice Fulfills a StarBase limit order by interacting with an external contract and verifying the taker amount.
    /// @dev Calls the StarBase limit order contract, checks the taker token amount, ensures it meets the minimum requirement,
    ///      and transfers the appropriate tokens to the fee receiver.
    /// @param callExternalData The data required to call the external StarBaseLimitOrder contract.
    /// @param takerToken The token that the taker is providing in the trade (usually an ERC20 token).
    /// @param minTakerTokenAmount The minimum amount of the taker token required to fulfill the order.
    /// @notice Emits a `Fill` event after successfully fulfilling the order.
    function fillStarBaseLimitOrder(
        bytes memory callExternalData, // call StarBaseLimitOrder
        address takerToken,
        uint256 minTakerTokenAmount
    ) external {
        require(isAdminListed[msg.sender], "SLOB: ACCESS_DENIED");
        Common._validateAddress(takerToken);

        // Get the initial balance of the taker token in the contract.
        uint256 originTakerBalance = IERC20(takerToken).balanceOf(address(this));

        // Call the external StarBase limit order contract to process the order.
        (bool success, bytes memory data) = _StarBase_LIMIT_ORDER_.call(callExternalData);
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }

        // Calculate the amount of taker tokens received by the contract after the external call.
        uint256 leftTakerAmount = IERC20(takerToken).balanceOf(address(this)) - originTakerBalance;
        require(leftTakerAmount >= minTakerTokenAmount, "SLOB: TAKER_AMOUNT_NOT_ENOUGH");
        IERC20(takerToken).safeTransfer(_TOKEN_RECEIVER_, leftTakerAmount);

        emit Fill(callExternalData, takerToken, minTakerTokenAmount);
    }

    /// @notice Performs a token swap on behalf of the StarBase limit order contract, verifying the taker and maker amounts.
    /// @dev This function is called by the external StarBase limit order contract to execute a swap of maker and taker tokens.
    ///      It ensures that the correct amounts are swapped and verifies that the return amount is as expected.
    /// @param curTakerFillAmount The amount of taker tokens to be filled in the order.
    /// @param curMakerFillAmount The amount of maker tokens to be filled in the order.
    /// @param makerToken The token that the maker is providing (fromToken).
    /// @param takerToken The token that the taker is providing (toToken).
    /// @param StarBaseRouteProxy The address of the StarBase router contract that will handle the swap.
    /// @param datas The swap data required for the router swap, including the swap address and other necessary parameters.
    /// @notice The function ensures the swap amount is sufficient and approves the necessary token transfers.
    function doLimitOrderSwap(
        uint256 curTakerFillAmount,
        uint256 curMakerFillAmount,
        address makerToken, // fromToken
        address takerToken, // toToken
        address StarBaseRouteProxy,
        SwapData calldata datas
    ) external {
        require(msg.sender == _StarBase_LIMIT_ORDER_, "SLOB: ACCESS_DENIED");

        uint256 originTakerBalance = IERC20(takerToken).balanceOf(address(this));
        _approve(IERC20(makerToken), StarBaseRouteProxy, curMakerFillAmount);

        // Call the StarBase router contract to perform the token swap.
        IStarBaseRouter(StarBaseRouteProxy).defiSwap(
            curMakerFillAmount,
            0,
            makerToken,
            takerToken,
            address(this),
            datas.callSwapAddr,
            datas.datas
        );

        // Get the new balance of the taker token in the contract after the swap.
        uint256 takerBalance = IERC20(takerToken).balanceOf(address(this));
        uint256 returnTakerAmount = takerBalance - originTakerBalance;
        require(returnTakerAmount >= curTakerFillAmount, "SLOB: SWAP_TAKER_AMOUNT_NOT_ENOUGH");

        _approve(IERC20(takerToken), _StarBase_LIMIT_ORDER_, curTakerFillAmount);
    }

    // ============ Ownable ============
    function setLimitOrder(address StarBaseLimitOrder_) external onlyOwner {
        require(
            _checkIfContractSupportsInterface(StarBaseLimitOrder_, type(IStarBaseLimitOrder).interfaceId),
            "SLOB: ADDRESS_DOES_NOT_IMPLEMENT_REQUIRED_METHODS"
        );
        _StarBase_LIMIT_ORDER_ = StarBaseLimitOrder_;
    }

    function addAdminList(address userAddr) external onlyOwner {
        Common._validateAddress(userAddr);
        isAdminListed[userAddr] = true;
        emit AddAdmin(userAddr);
    }

    function removeAdminList(address userAddr) external onlyOwner {
        Common._validateAddress(userAddr);
        isAdminListed[userAddr] = false;
        emit RemoveAdmin(userAddr);
    }

    function changeTokenReceiver(address newTokenReceiver) external onlyOwner {
        Common._validateAddress(newTokenReceiver);
        _TOKEN_RECEIVER_ = newTokenReceiver;
        emit ChangeReceiver(newTokenReceiver);
    }

    function _checkIfContractSupportsInterface(address _contract, bytes4 interfaceId) internal view returns (bool) {
        (bool success, bytes memory result) = _contract.staticcall(
            abi.encodeWithSelector(ERC165.supportsInterface.selector, interfaceId)
        );

        if (success && result.length == 32) {
            return abi.decode(result, (bool));
        }
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IStarBaseLimitOrderBot).interfaceId;
    }

    /**
     * @dev Approves the specified amount of a token for a given spender.
     * @param token The token to approve.
     * @param to The address to approve.
     * @param amount The amount to approve.
     */
    function _approve(IERC20 token, address to, uint256 amount) internal {
        uint256 allowance = token.allowance(address(this), to);

        // Only approve if the current allowance is less than the required amount
        if (allowance < amount) {
            // Reset allowance to zero first to avoid race condition
            if (allowance > 0) {
                token.safeApprove(to, 0);
            }
            // Approve exactly the required amount
            token.safeApprove(to, amount);
        }
    }

    // ============ View Functions ============
    function version() external pure returns (uint256) {
        return 101;
    }
}
