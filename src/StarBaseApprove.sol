/*
    Copyright 2024 StarBase.
    SPDX-License-Identifier: Apache-2.0
*/

pragma solidity ^0.8.4;

import { IERC20 } from "./intf/IERC20.sol";
import { SafeERC20 } from "./lib/SafeERC20.sol";
import { InitializableOwnable } from "./lib/InitializableOwnable.sol";
import { Common } from "./lib/Common.sol";
import { IStarBaseApproveProxy } from "./intf/IStarBaseApproveProxy.sol";
import { IStarBaseApprove } from "./intf/IStarBaseApprove.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/**
 * @title StarBaseApprove
 * @dev Manages authorization and token claiming within the StarBase platform.
 * @notice The contract allows the owner to set a proxy and allows the proxy to claim tokens on behalf of the user.
 */

contract StarBaseApprove is InitializableOwnable {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    uint256 private constant _TIMELOCK_DURATION_ = 3 days; // Standard timelock duration for proxy changes
    uint256 private constant _TIMELOCK_EMERGENCY_DURATION_ = 24 hours; // Emergency timelock duration for proxy changes

    // ============ Storage ============
    uint256 public _TIMELOCK_; // Current timelock timestamp
    address public _PENDING_StarBase_PROXY_; // Pending proxy address
    address public _StarBase_PROXY_; // Current approved proxy

    // ============ Events ============
    event ClaimTokens(address indexed token, address indexed who, address indexed dest, uint160 amount); // Emitted when tokens are claimed
    event LockSetProxy();
    event AddStarBaseProxy(address indexed newStarBaseProxy);
    event UnlockSetProxy(address newStarBaseProxy);
    // ============ Modifiers ============
    /**
     * @dev Modifier that ensures a proxy change is not locked by the timelock.
     */
    modifier notLocked() {
        require(_TIMELOCK_ <= block.timestamp, "SA: PROXY SET IS TIMELOCKED");
        _;
    }

    /**
     * @dev Constructor to initialize the contract with the owner and proxy address.
     * @param owner The address that will own the contract.
     * @param _StarBase_PROXY The initial StarBase proxy address.
     */
    constructor(address owner, address _StarBase_PROXY) {
        Common._validateAddress(owner);
        initOwner(owner);

        require(
            _checkIfContractSupportsInterface(_StarBase_PROXY, type(IStarBaseApproveProxy).interfaceId),
            "SA: ADDRESS_DOES_NOT_IMPLEMENT_REQUIRED_METHODS"
        );

        _StarBase_PROXY_ = _StarBase_PROXY;
    }

    /**
     * @dev Unlocks the process of setting a new proxy address after the timelock duration.
     * @param newStarBaseProxy The new proxy address to be set.
     */
    function unlockSetProxy(address newStarBaseProxy) external onlyOwner {
        Common._validateAddress(newStarBaseProxy);
        require(
            _checkIfContractSupportsInterface(newStarBaseProxy, type(IStarBaseApproveProxy).interfaceId),
            "SA: ADDRESS_DOES_NOT_IMPLEMENT_REQUIRED_METHODS"
        );
        // Set timelock duration based on whether there is already a proxy address
        _TIMELOCK_ = (_StarBase_PROXY_ == address(0))
            ? block.timestamp + _TIMELOCK_EMERGENCY_DURATION_
            : block.timestamp + _TIMELOCK_DURATION_;
        _PENDING_StarBase_PROXY_ = newStarBaseProxy;
        emit UnlockSetProxy(newStarBaseProxy);
    }

    /**
     * @dev Locks the proxy setting process and resets the pending proxy address.
     */
    function lockSetProxy() public onlyOwner {
        _PENDING_StarBase_PROXY_ = address(0);
        _TIMELOCK_ = 0;
        emit LockSetProxy();
    }

    /**
     * @dev Adds the pending proxy address to the list of allowed proxies.
     * Can only be called after the timelock has expired.
     */
    function addStarBaseProxy() external onlyOwner notLocked {
        _StarBase_PROXY_ = _PENDING_StarBase_PROXY_;
        lockSetProxy();
        emit AddStarBaseProxy(_PENDING_StarBase_PROXY_);
    }

    /**
     * @dev Allows the approved proxy to claim tokens on behalf of the user.
     * @param token The address of the token to be claimed.
     * @param who The address of the token holder.
     * @param dest The address where the tokens will be sent.
     * @param amount The amount of tokens to claim.
     */
    function claimTokens(address token, address who, address dest, uint160 amount) external {
        Common._validateAddress(token);
        Common._validateAddress(who);
        Common._validateAddress(dest);

        require(msg.sender == _StarBase_PROXY_, "SA: ACCESS RESTRICTED TO APPROVED PROXY");

        if (amount > 0) {
            IERC20(token).safeTransferFrom(who, dest, amount);
        }

        emit ClaimTokens(token, who, dest, amount);
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
        return interfaceId == type(IStarBaseApprove).interfaceId;
    }
}
