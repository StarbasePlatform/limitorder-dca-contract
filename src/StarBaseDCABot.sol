/*
    Copyright 2024 StarBase  .
    SPDX-License-Identifier: Apache-2.0
*/
pragma solidity ^0.8.4;

import { InitializableOwnable } from "./lib/InitializableOwnable.sol";
import { IERC20 } from "./intf/IERC20.sol";
import { SafeERC20 } from "./lib/SafeERC20.sol";
import { IStarBaseRouter } from "./intf/IStarBaseRouter.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { Common } from "./lib/Common.sol";
import { IStarBaseDCA } from "./intf/IStarBaseDCA.sol";
import { IStarBaseDCABot } from "./intf/IStarBaseDCABot.sol";

/**
 * @title StarBaseDCABot
 * @dev This contract is a DCA (Dollar Cost Averaging) bot for StarBase, enabling users to automate trades and interact with StarBase's DCA mechanism.
 * @notice The bot allows admin users to initiate DCA trades and perform token swaps through a connected router.
 * @author StarBase
 */
contract StarBaseDCABot is InitializableOwnable, ERC165 {
    using SafeERC20 for IERC20;

    // ================ Storage ================
    address public _StarBase_DCA_;
    address public _TOKEN_RECEIVER_;
    mapping(address => bool) public isAdminListed;
    address public _Setup_Tool_;

    // ================ Events ================
    event AddAdmin(address indexed admin);
    event RemoveAdmin(address indexed admin);
    event ChangeReceiver(address indexed newReceiver);
    event Fill(bytes, address, uint256);

    struct SwapData {
        address callSwapAddr;
        bytes datas;
    }

    /**
     * @dev Initializes the contract with the given parameters.
     * @param owner The address of the owner.
     * @param tokenReceiver The address of the token receiver for the filled DCA trades.
     * @param userAddr List of admin addresses that are allowed to execute certain functions.
     */
    constructor(address owner, address tokenReceiver, address[] memory userAddr) {
        Common._validateAddress(owner);
        Common._validateAddress(tokenReceiver);

        initOwner(owner);
        _TOKEN_RECEIVER_ = tokenReceiver;
        emit ChangeReceiver(_TOKEN_RECEIVER_);

        for (uint i = 0; i < userAddr.length; i++) {
            isAdminListed[userAddr[i]] = true;
            emit AddAdmin(userAddr[i]);
        }
    }

    /**
     * @dev Executes the DCA trade by interacting with the StarBase DCA contract and transferring the resulting tokens.
     * @param callExternalData Data to call the external DCA contract with.
     * @param outputToken The address of the token that is received after the DCA trade.
     * @param minOutputTokenAmount The minimum amount of the output token that should be received.
     */
    function fillStarBaseDCA(
        bytes memory callExternalData,
        address outputToken,
        uint256 minOutputTokenAmount
    ) external {
        require(isAdminListed[msg.sender], "SDCAB: ACCESS_DENIED");

        Common._validateAddress(outputToken);
        uint256 originTakerBalance = IERC20(outputToken).balanceOf(address(this));

        (bool success, bytes memory data) = _StarBase_DCA_.call(callExternalData);
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }

        uint256 leftTakerAmount = IERC20(outputToken).balanceOf(address(this)) - originTakerBalance;
        require(leftTakerAmount >= minOutputTokenAmount, "SDCAB: TAKER_AMOUNT_NOT_ENOUGH");
        IERC20(outputToken).safeTransfer(_TOKEN_RECEIVER_, leftTakerAmount);

        emit Fill(callExternalData, outputToken, minOutputTokenAmount);
    }

    /**
     * @dev Executes a swap on the DCA contract using the provided parameters.
     * @param inAmount The amount of the input token to swap.
     * @param minOutAmount The minimum amount of output token to receive.
     * @param maxOutAmount The maximum amount of output token to allow.
     * @param inputToken The address of the input token.
     * @param outputToken The address of the output token.
     * @param StarBaseRouteProxy The address of the StarBase route proxy for swapping.
     * @param datas Data for the swap call.
     * @return returnTakerAmount The amount of output token received from the swap.
     */
    function doDCASwap(
        uint256 inAmount,
        uint256 minOutAmount,
        uint256 maxOutAmount,
        address inputToken,
        address outputToken,
        address StarBaseRouteProxy,
        SwapData calldata datas
    ) external returns (uint256 returnTakerAmount) {
        Common._validateAddress(inputToken);
        Common._validateAddress(outputToken);
        Common._validateAddress(StarBaseRouteProxy);

        require(msg.sender == _StarBase_DCA_, "SDCAB: ACCESS_DENIED");
        uint256 originTakerBalance = IERC20(outputToken).balanceOf(address(this));
        _approve(IERC20(inputToken), StarBaseRouteProxy, inAmount);

        IStarBaseRouter(StarBaseRouteProxy).defiSwap(
            inAmount,
            minOutAmount,
            inputToken,
            outputToken,
            address(this),
            datas.callSwapAddr,
            datas.datas
        );

        returnTakerAmount = IERC20(outputToken).balanceOf(address(this)) - originTakerBalance;

        require(returnTakerAmount >= minOutAmount, "SDCAB: SWAP_TAKER_AMOUNT_NOT_ENOUGH");

        if (returnTakerAmount > maxOutAmount) {
            returnTakerAmount = maxOutAmount;
        }

        _approve(IERC20(outputToken), _StarBase_DCA_, returnTakerAmount);
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

    function supportsInterface(bytes4 interfaceId) public pure override(ERC165) returns (bool) {
        return interfaceId == type(IStarBaseDCABot).interfaceId;
    }

    // ============= Ownable Functions =============
    function setDcaContract(address StarBaseDCA) external onlyOwner {
        require(
            _checkIfContractSupportsInterface(StarBaseDCA, type(IStarBaseDCA).interfaceId),
            "SLOP: ADDRESS_DOES_NOT_IMPLEMENT_REQUIRED_METHODS"
        );

        _StarBase_DCA_ = StarBaseDCA;
    }
    /**
     * @dev Adds an address to the list of admin addresses.
     * @param userAddr The address of the user to add as an admin.
     */
    function addAdminList(address userAddr) external onlyOwner {
        Common._validateAddress(userAddr);
        isAdminListed[userAddr] = true;
        emit AddAdmin(userAddr);
    }

    /**
     * @dev Removes an address from the list of admin addresses.
     * @param userAddr The address of the user to remove from the admin list.
     */
    function removeAdminList(address userAddr) external onlyOwner {
        Common._validateAddress(userAddr);
        isAdminListed[userAddr] = false;
        emit RemoveAdmin(userAddr);
    }

    /**
     * @dev Changes the address where the tokens are sent after a DCA fill.
     * @param newTokenReceiver The address of the new token receiver.
     */
    function changeTokenReceiver(address newTokenReceiver) external onlyOwner {
        Common._validateAddress(newTokenReceiver);
        _TOKEN_RECEIVER_ = newTokenReceiver;
        emit ChangeReceiver(newTokenReceiver);
    }

    // ============= Internal Functions =============

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

    // ============= View Functions =============

    /**
     * @dev Returns the current version of the contract.
     * @return The current version number.
     */
    function version() external pure returns (uint256) {
        return 101;
    }
}
