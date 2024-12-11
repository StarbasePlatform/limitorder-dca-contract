/*
    Copyright 2024 StarBase  .
    SPDX-License-Identifier: Apache-2.0
*/

pragma solidity ^0.8.4;
import { IERC20 } from "./intf/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { SafeERC20 } from "./lib/SafeERC20.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IStarBaseApproveProxy } from "./intf/IStarBaseApproveProxy.sol";
import { IERC1271Wallet } from "./intf/IERC1271Wallet.sol";
import { InitializableOwnable } from "./lib/InitializableOwnable.sol";
import "./lib/ArgumentsDecoder.sol";
import { IStarBaseLimitOrder } from "./intf/IStarBaseLimitOrder.sol";
import { Common } from "./lib/Common.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import { IStarBaseLimitOrderBot } from "./intf/IStarBaseLimitOrderBot.sol";

contract StarBaseLimitOrder is
    IStarBaseLimitOrder,
    ERC165,
    EIP712("StarBase Limit Order Protocol", "1"),
    InitializableOwnable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using ArgumentsDecoder for bytes;

    bytes32 public constant ORDER_TYPEHASH =
        keccak256(
            "Order(address makerToken,address takerToken,uint160 makerAmount,uint160 takerAmount,address maker,uint256 expiration,uint256 salt)"
        );

    // ============ Storage ============
    mapping(bytes32 => uint160) public _FILLED_TAKER_AMOUNT_;
    mapping(address => bool) public isWhiteListed;
    address public _StarBase_APPROVE_PROXY_;
    address public _FEE_RECEIVER_;
    uint160 public _FEE_RATE_; // fee = amount * feeRate / 10000
    uint160 public _VLIMIT = 200000;

    // ============ Events ============
    event AddWhiteList(address addr);
    event RemoveWhiteList(address addr);
    event ChangeFeeReceiver(address newFeeReceiver);
    event OrderCancelled(bytes32 orderHash);
    event ChangeFeeRate(uint160 feeRate);
    event ChangeVerifyERC127GasLimit(uint160 gasLimit);

    constructor(
        address owner,
        address StarBaseApproveProxy,
        address feeReceiver,
        uint160 feeRate,
        address StarBaseLimitOrderBot
    ) {
        Common._validateAddress(owner);
        Common._validateAddress(feeReceiver);
        Common._validateAddress(StarBaseLimitOrderBot);
        require(feeRate <= 1000 && feeRate > 0, "SLO: FEE_RATE_TOO_HIGH");

        require(
            _checkIfContractSupportsInterface(StarBaseApproveProxy, type(IStarBaseApproveProxy).interfaceId),
            "SLO: ADDRESS_DOES_NOT_IMPLEMENT_REQUIRED_METHODS"
        );
        _StarBase_APPROVE_PROXY_ = StarBaseApproveProxy;

        isWhiteListed[StarBaseLimitOrderBot] = true;

        initOwner(owner);

        _FEE_RECEIVER_ = feeReceiver;
        emit ChangeFeeReceiver(feeReceiver);

        _FEE_RATE_ = feeRate;
        emit ChangeFeeRate(feeRate);
    }

    // ============ Main Fill Limit Order Function ============
    /// @notice Fulfills a limit order by verifying the signature, calculating the fee,
    ///         transferring tokens, and executing router swaps.
    /// @dev The function ensures that the order is valid, the fee is calculated and transferred,
    ///      and it handles any required interactions with other contracts (e.g., routers).
    /// @param order The order details, including the maker and taker's token, amounts, expiration time, etc.
    /// @param signature The signature used to verify the order's authenticity.
    /// @param takerFillAmount The amount of the order the taker intends to fill.
    /// @param thresholdTakerAmount The minimum amount the taker must fill for the order to be processed.
    /// @param takerInteraction Additional data passed by the taker, typically used for interacting with external protocols (e.g., router swap).
    /// @return curTakerFillAmount The actual amount filled by the taker.
    /// @return curMakerFillAmount The actual amount filled for the maker based on the taker's fill.
    function fillLimitOrder(
        Order calldata order,
        bytes memory signature,
        uint160 takerFillAmount,
        uint160 thresholdTakerAmount,
        bytes memory takerInteraction
    ) external nonReentrant returns (uint160 curTakerFillAmount, uint160 curMakerFillAmount) {
        bytes32 orderHash = _orderHash(order);
        uint160 filledTakerAmount = _FILLED_TAKER_AMOUNT_[orderHash];

        require(filledTakerAmount < order.takerAmount, "SLO: ALREADY_FILLED");

        if (Common._isContract(order.maker)) {
            _verifyERC1271WalletSignature(order.maker, orderHash, signature);
        } else {
            require(ECDSA.recover(orderHash, signature) == order.maker, "SLO: INVALID_SIGNATURE");
        }

        require(order.expiration > block.timestamp, "SLO: EXPIRED_ORDER");

        uint160 leftTakerAmount = order.takerAmount - filledTakerAmount;
        curTakerFillAmount = takerFillAmount < leftTakerAmount ? takerFillAmount : leftTakerAmount;
        curMakerFillAmount = (curTakerFillAmount * order.makerAmount) / order.takerAmount;

        uint160 fee = (curTakerFillAmount * _FEE_RATE_) / 10000;

        require(curTakerFillAmount > 0 && curMakerFillAmount > 0, "SLO: ZERO_FILL_INVALID");
        require(fee > 0, "SLO: FEE_MUST_BE_GREATER_THAN_ZERO");
        require(curTakerFillAmount >= thresholdTakerAmount, "SLO: FILL_AMOUNT_NOT_ENOUGH");

        // Update the filled taker amount
        _FILLED_TAKER_AMOUNT_[orderHash] = filledTakerAmount + curTakerFillAmount;

        // Maker => Taker
        IStarBaseApproveProxy(_StarBase_APPROVE_PROXY_).claimTokens(
            order.makerToken,
            order.maker,
            msg.sender,
            curMakerFillAmount
        );

        // Execute any additional interactions (e.g., router swap) if provided
        if (takerInteraction.length > 0) {
            takerInteraction.patchUint256(0, curTakerFillAmount);
            takerInteraction.patchUint256(1, curMakerFillAmount);
            require(isWhiteListed[msg.sender], "SLO: NOT_WHITELIST_CONTRACT");

            (bool success, bytes memory data) = msg.sender.call(takerInteraction);
            if (!success) {
                assembly {
                    revert(add(data, 32), mload(data))
                }
            }
        }

        // Ensure the taker has enough balance to fulfill the order
        require(IERC20(order.takerToken).balanceOf(msg.sender) >= curTakerFillAmount, "SLO: INSUFFICIENT_BALANCE");

        // Transfer the tokens to the maker and send the fee
        sendMaker(order, msg.sender, curTakerFillAmount - fee);
        sendFee(order, msg.sender, _FEE_RECEIVER_, fee);

        emit LimitOrderFilled(order.maker, msg.sender, orderHash, curTakerFillAmount, curMakerFillAmount);
    }

    /**
     * @dev Cancels an existing limit order.
     * @param order The limit order to be canceled, containing all necessary details.
     * @param signature The signature to verify the authenticity of the cancellation request.
     */
    function cancelOrder(Order memory order, bytes memory signature) external {
        bytes32 orderHash = _orderHash(order);

        require(order.maker == msg.sender, "SLO: PRIVATE_ORDER");

        if (Common._isContract(order.maker)) {
            _verifyERC1271WalletSignature(order.maker, orderHash, signature);
        } else {
            require(ECDSA.recover(orderHash, signature) == order.maker, "SLO: INVALID_SIGNATURE");
        }

        require(order.expiration > block.timestamp, "SLO: EXPIRE_ORDER");

        _FILLED_TAKER_AMOUNT_[orderHash] = order.takerAmount;
        emit OrderCancelled(orderHash);
    }

    /**
     * @dev Transfers the specified `curTakerFillAmount` of the taker token to the maker.
     * @param order The order details, including the maker and taker token information.
     * @param from The address where tokens will be transferred from.
     * @param curTakerFillAmount The amount of taker tokens to transfer to the maker.
     */
    function sendMaker(Order calldata order, address from, uint160 curTakerFillAmount) internal {
        Common._validateAddress(from);
        IERC20(order.takerToken).safeTransferFrom(from, order.maker, curTakerFillAmount);
    }

    /**
     * @dev Sends the fee to the designated fee recipient.
     * @param order The order containing the trade.
     * @param from The address from which the fee is transferred.
     * @param to The address receiving the fee.
     * @param fee The fee amount to be transferred.
     */
    function sendFee(Order calldata order, address from, address to, uint160 fee) internal {
        Common._validateAddress(from);
        Common._validateAddress(to);
        IERC20(order.takerToken).safeTransferFrom(from, to, fee);
    }

    /**
     * @dev Checks if a given contract supports a specific interface ID using ERC165.
     * @param _contract The address of the contract to check.
     * @param interfaceId The ID of the interface to verify support for.
     * @return Returns `true` if the contract supports the given interface ID, otherwise `false`.
     */
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
        return interfaceId == type(IStarBaseLimitOrder).interfaceId;
    }

    // ============ Ownable Functions ============
    function setStarBaseApproveProxy(address StarBaseApproveProxy) external onlyOwner {
        require(
            _checkIfContractSupportsInterface(StarBaseApproveProxy, type(IStarBaseApproveProxy).interfaceId),
            "SLO: ADDRESS_DOES_NOT_IMPLEMENT_REQUIRED_METHODS"
        );
        _StarBase_APPROVE_PROXY_ = StarBaseApproveProxy;
    }

    function addWhiteList(address contractAddr) external onlyOwner {
        Common._validateAddress(contractAddr);
        isWhiteListed[contractAddr] = true;
        emit AddWhiteList(contractAddr);
    }

    function removeWhiteList(address contractAddr) external onlyOwner {
        // Ensure the address is in the whitelist before removing
        require(isWhiteListed[contractAddr], "SLO: ADDRESS NOT IN WHITELIST");

        isWhiteListed[contractAddr] = false;
        emit RemoveWhiteList(contractAddr);
    }

    function changeFeeReceiver(address newFeeReceiver) external onlyOwner {
        Common._validateAddress(newFeeReceiver);
        _FEE_RECEIVER_ = newFeeReceiver;
        emit ChangeFeeReceiver(newFeeReceiver);
    }

    function changeFeeRate(uint160 feeRate) external onlyOwner {
        require(feeRate <= 1000, "SLO: FEE_RATE_TOO_HIGH");
        _FEE_RATE_ = feeRate;
        emit ChangeFeeRate(feeRate);
    }

    function changeVerifyERC127GasLimit(uint160 gasLimit) external onlyOwner {
        require(gasLimit > 20000, "SLO: FEE_RATE_TOO_HIGH");
        _VLIMIT = gasLimit;
        emit ChangeVerifyERC127GasLimit(gasLimit);
    }

    // ============ Internal Functions ============
    function _orderHash(Order memory order) public view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        ORDER_TYPEHASH,
                        order.makerToken,
                        order.takerToken,
                        order.makerAmount,
                        order.takerAmount,
                        order.maker,
                        order.expiration,
                        order.salt
                    )
                )
            );
    }

    /**
     * @dev Verifies the ERC1271 signature for the provided address and order hash.
     * @param _addr The address to verify the signature from.
     * @param _hash The hash of the order to verify.
     * @param _signature The signature to verify.
     */
    function _verifyERC1271WalletSignature(address _addr, bytes32 _hash, bytes memory _signature) internal view {
        // Use a higher gas limit for ERC1271 signature verification
        (bool success, bytes memory result) = _addr.staticcall{ gas: _VLIMIT }(
            abi.encodeWithSelector(IERC1271Wallet.isValidSignature.selector, _hash, _signature)
        );
        require(success, "SLO: ERC1271_SIGNATURE_FAILED");
        bytes4 sigResult = abi.decode(result, (bytes4));
        require(sigResult == 0x1626ba7e, "SLO: INVALID_SIGNATURE");
    }
}
