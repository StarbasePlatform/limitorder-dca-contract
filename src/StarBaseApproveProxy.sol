/*
    Copyright 2024 StarBase.
    SPDX-License-Identifier: Apache-2.0
*/

pragma solidity ^0.8.4;

import { IStarBaseApprove } from "./intf/IStarBaseApprove.sol";
import { InitializableOwnable } from "./lib/InitializableOwnable.sol";
import { IStarBaseApproveProxy } from "./intf/IStarBaseApproveProxy.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { Common } from "./lib/Common.sol";

/**
 * @title StarBaseApproveProxy
 * @dev A proxy contract that allows approved addresses to claim tokens from the StarBaseApprove contract.
 * @notice This contract supports adding/removing proxy addresses with a timelock and enforcing access control on token claims.
 * @author StarBase
 */
contract StarBaseApproveProxy is InitializableOwnable, IStarBaseApproveProxy, ERC165 {
    // ============ Constants ============
    uint256 private constant _TIMELOCK_DURATION_ = 3 days; // Timelock duration for adding a new proxy

    // ============ Storage ============
    mapping(address => bool) public _IS_ALLOWED_PROXY_; // Mapping of allowed proxies
    uint256 public _TIMELOCK_; // Timestamp for the timelock
    address public _PENDING_ADD_StarBase_PROXY_; // Pending proxy to be added
    address public _StarBase_APPROVE_; // Address of the StarBaseApprove contract
    address public _Setup_Tool_;
    bool private _isStarBaseApproveSet_ = false;
    bool private _isSetWhiteList_ = false;

    // ============ Events ============
    event RemoveStarBaseProxy(address oldStarBaseProxy); // Emitted when a proxy is removed
    event ClaimTokens(address indexed token, address indexed who, address indexed dest, uint160 amount); // Emitted on successful token claim
    event UnlockAddProxy(address indexed newStarBaseProxy);
    event LockAddProxy();
    event AddStarBaseProxy(address indexed newStarBaseProxy);
    event SetStarBaseApprove(address indexed StarBaseApprove);
    event SetWhiteList(address[] indexed proxies);

    // ============ Modifiers ============
    /**
     * @dev Modifier to ensure that the contract is not in timelock state.
     */
    modifier notLocked() {
        require(_TIMELOCK_ <= block.timestamp, "SAP: SetProxy is timelocked");
        _;
    }

    /**
     * @dev Contract constructor to initialize the contract with the owner, the StarBaseApprove contract, and allowed proxies.
     * @param owner The owner of the contract.
     */
    constructor(address owner) {
        Common._validateAddress(owner);
        initOwner(owner);
    }

    /**
     * @dev Unlocks the ability to add a new proxy after the timelock.
     * @param newStarBaseProxy The new proxy address to be added.
     */
    function unlockAddProxy(address newStarBaseProxy) external onlyOwner {
        Common._validateAddress(newStarBaseProxy);
        _TIMELOCK_ = block.timestamp + _TIMELOCK_DURATION_;
        _PENDING_ADD_StarBase_PROXY_ = newStarBaseProxy;
        emit UnlockAddProxy(newStarBaseProxy);
    }

    /**
     * @dev Locks the process of adding a new proxy and clears the pending proxy address.
     */
    function lockAddProxy() public onlyOwner {
        _PENDING_ADD_StarBase_PROXY_ = address(0);
        _TIMELOCK_ = 0;
        emit LockAddProxy();
    }

    /**
     * @dev Adds the pending proxy address to the list of allowed proxies.
     * Can only be called after the timelock has expired.
     */
    function addStarBaseProxy() external onlyOwner notLocked {
        _IS_ALLOWED_PROXY_[_PENDING_ADD_StarBase_PROXY_] = true;
        lockAddProxy();
        emit AddStarBaseProxy(_PENDING_ADD_StarBase_PROXY_);
    }

    function setStarBaseApprove(address StarBaseApprove) external onlyOwner {
        require(_isStarBaseApproveSet_ == false, "SAP: It's already initialized");

        require(
            _checkIfContractSupportsInterface(StarBaseApprove, type(IStarBaseApprove).interfaceId),
            "SAP: Address does not implement required methods"
        );

        _StarBase_APPROVE_ = StarBaseApprove;
        _isStarBaseApproveSet_ = true;
        emit SetStarBaseApprove(StarBaseApprove);
    }

    function setWhiteList(address[] memory proxies) external onlyOwner {
        // Add each proxy to the allowed list
        require(_isSetWhiteList_ == false, "SAP: It's already initialized");
        for (uint256 i = 0; i < proxies.length; i++) {
            Common._validateAddress(proxies[i]);
            _IS_ALLOWED_PROXY_[proxies[i]] = true;
        }
        _isSetWhiteList_ = true;
        emit SetWhiteList(proxies);
    }

    /**
     * @dev Removes an existing proxy from the allowed list.
     * @param oldStarBaseProxy The proxy address to be removed.
     */
    function removeStarBaseProxy(address oldStarBaseProxy) external onlyOwner {
        Common._validateAddress(oldStarBaseProxy);
        require(_IS_ALLOWED_PROXY_[oldStarBaseProxy], "SAP: Address is not an allowed proxy");
        _IS_ALLOWED_PROXY_[oldStarBaseProxy] = false;
        emit RemoveStarBaseProxy(oldStarBaseProxy);
    }

    /**
     * @dev Claims tokens from the StarBaseApprove contract.
     * @param token The token to claim.
     * @param who The address from which to claim tokens.
     * @param dest The destination address to receive the tokens.
     * @param amount The amount of tokens to claim.
     */
    function claimTokens(address token, address who, address dest, uint160 amount) external {
        Common._validateAddress(token);
        Common._validateAddress(who);
        Common._validateAddress(dest);

        require(_IS_ALLOWED_PROXY_[msg.sender], "SAP: Access restricted to allowed proxies");
        IStarBaseApprove(_StarBase_APPROVE_).claimTokens(token, who, dest, amount);
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

    function supportsInterface(bytes4 interfaceId) public pure override(ERC165) returns (bool) {
        return interfaceId == type(IStarBaseApproveProxy).interfaceId;
    }
}
