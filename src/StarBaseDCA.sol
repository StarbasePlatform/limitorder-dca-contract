/*
    Copyright 2024 StarBase.
    SPDX-License-Identifier: Apache-2.0
*/

pragma solidity ^0.8.4;

import { IERC20 } from "./intf/IERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SafeERC20 } from "./lib/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IStarBaseApproveProxy } from "./intf/IStarBaseApproveProxy.sol";
import { IERC1271Wallet } from "./intf/IERC1271Wallet.sol";
import { InitializableOwnable } from "./lib/InitializableOwnable.sol";
import { ArgumentsDecoder } from "./lib/ArgumentsDecoder.sol";
import { IStarBaseDCA } from "./intf/IStarBaseDCA.sol";
import { Common } from "./lib/Common.sol";
import { IERC165 } from "./intf/IERC165.sol";

/**
 * @title StarBaseDCA
 * @dev A contract for managing Dollar Cost Averaging (DCA) operations on the StarBase platform.
 * @notice This contract facilitates executing DCA trades, fee management, and whitelist management.
 * @author StarBase
 */

contract StarBaseDCA is IStarBaseDCA, EIP712("StarBase DCA Protocol", "1"), InitializableOwnable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ArgumentsDecoder for bytes;

    struct DCAStates {
        uint256 lastUpdateTime;
        uint160 numberOfTrade;
    }

    bytes32 public constant ORDER_TYPEHASH =
        keccak256(
            "Order(uint160 cycleSecondsApart,uint160 numberOfTrade,address inputToken,address outputToken,address maker,uint160 inAmount,uint256 minOutAmountPerCycle,uint256 maxOutAmountPerCycle,uint256 expiration,uint256 salt)"
        );

    // ============ Storage ============
    mapping(bytes32 => DCAStates) public _DCA_FILLEDTIMES_;
    mapping(address => bool) public isWhiteListed;
    address public _StarBase_APPROVE_PROXY_;
    address public _FEE_RECEIVER_;
    uint160 public _FEE_RATE_; // Fee rate, fee = amount * feeRate / 10000
    uint160 public _VLIMIT = 200000;

    // ============ Events ============
    event DCAFilled(
        address indexed maker,
        address indexed taker,
        bytes32 orderHash,
        uint256 curTakerFillAmount,
        uint256 curMakerFillAmount
    );
    event AddWhiteList(address indexed addr);
    event RemoveWhiteList(address indexed addr);
    event ChangeFeeReceiver(address indexed newFeeReceiver);
    event OrderCancelled(bytes32 orderHash);
    event ChangeFeeRate(uint256 feeRate);
    event ChangeVerifyERC127GasLimit(uint160 gasLimit);
    error TakerInteractionFail(bytes data);

    /**
     * @dev Contract constructor to initialize the DCA contract.
     * @param owner Address of the contract owner.
     * @param StarBaseApproveProxy Address of the StarBaseApproveProxy contract.
     * @param feeReceiver Address where the fees are sent.
     * @param feeRate Fee rate (multiplied by 10000).
     * @param StarBaseDCABot Address of the StarBase DCA Bot contract.
     */
    constructor(
        address owner,
        address StarBaseApproveProxy,
        address feeReceiver,
        uint160 feeRate,
        address StarBaseDCABot
    ) {
        require(feeRate <= 3000, "SDCA: FEE_RATE_TOO_HIGH"); // Fee rate cannot exceed 30%
        Common._validateAddress(owner);
        Common._validateAddress(feeReceiver);
        Common._validateAddress(StarBaseDCABot);

        require(
            _checkIfContractSupportsInterface(StarBaseApproveProxy, type(IStarBaseApproveProxy).interfaceId),
            "SDCA: ADDRESS_DOES_NOT_IMPLEMENT_REQUIRED_METHODS"
        );

        initOwner(owner);
        _StarBase_APPROVE_PROXY_ = StarBaseApproveProxy;
        _FEE_RECEIVER_ = feeReceiver;
        _FEE_RATE_ = feeRate;

        emit ChangeFeeReceiver(feeReceiver);
        emit ChangeFeeRate(feeRate);

        isWhiteListed[StarBaseDCABot] = true;
        emit AddWhiteList(StarBaseDCABot);
    }

    // ============= DCA Functions ==============

    /**
     * @dev Executes the DCA trade by interacting with the maker and taker, and transferring tokens.
     * @param order The order details for the DCA.
     * @param signature The signature of the maker.
     * @param takerInteraction Data for the taker's interaction (if any).
     * @return curTakerFillAmount The amount filled for the taker in this cycle.
     */
    function fillDCA(
        Order memory order,
        bytes memory signature,
        bytes memory takerInteraction
    ) external nonReentrant returns (uint256 curTakerFillAmount) {
        require(order.maxOutAmountPerCycle >= order.minOutAmountPerCycle, "SDCA: MAX_OUT_MUST_BE_GREATER_THAN_MIN_OUT");

        bytes32 orderHash = _orderHash(order);
        DCAStates storage DCAFilledTimes = _DCA_FILLEDTIMES_[orderHash];

        require(order.expiration > block.timestamp, "SDCA: EXPIRED_ORDER");

        require(DCAFilledTimes.numberOfTrade < order.numberOfTrade, "SDCA: DCA_ALREADY_FILLED");

        require(block.timestamp - DCAFilledTimes.lastUpdateTime >= order.cycleSecondsApart, "SDCA: TIME_NOT_ENOUGH");

        if (Common._isContract(order.maker)) {
            _verifyERC1271WalletSignature(order.maker, orderHash, signature);
        } else {
            require(ECDSA.recover(orderHash, signature) == order.maker, "SDCA: INVALID_SIGNATURE");
        }

        require(IERC20(order.inputToken).balanceOf(order.maker) >= order.inAmount, "SDCA: INSUFFICIENT_BALANCE");

        DCAFilledTimes.lastUpdateTime = block.timestamp;
        DCAFilledTimes.numberOfTrade = DCAFilledTimes.numberOfTrade + 1;

        require(isWhiteListed[msg.sender], "SDCA: NOT_WHITELISTED");

        // Maker => Taker
        IStarBaseApproveProxy(_StarBase_APPROVE_PROXY_).claimTokens(
            order.inputToken,
            order.maker,
            msg.sender,
            order.inAmount
        );

        if (takerInteraction.length > 0) {
            takerInteraction.patchUint256(0, order.inAmount);
            takerInteraction.patchUint256(1, order.minOutAmountPerCycle);
            takerInteraction.patchUint256(2, order.maxOutAmountPerCycle);

            (bool success, bytes memory data) = msg.sender.call(takerInteraction);
            if (!success) {
                assembly {
                    revert(add(data, 32), mload(data))
                }
            }

            curTakerFillAmount = abi.decode(data, (uint256));
            require(
                curTakerFillAmount > 0 && curTakerFillAmount >= order.minOutAmountPerCycle,
                "SDCA: INVALID_CUR_TAKER_FILL_AMOUNT"
            );
        } else {
            revert TakerInteractionFail(takerInteraction);
        }

        require(IERC20(order.outputToken).balanceOf(msg.sender) >= curTakerFillAmount, "SDCA: INSUFFICIENT_BALANCE");

        uint256 fee = (curTakerFillAmount * _FEE_RATE_) / 10000;
        require(fee > 0, "SLO: FEE_MUST_BE_GREATER_THAN_ZERO");

        sendMaker(order, msg.sender, curTakerFillAmount - fee);
        sendFee(order, msg.sender, _FEE_RECEIVER_, fee);
        emit DCAFilled(order.maker, msg.sender, orderHash, curTakerFillAmount, order.inAmount);
    }

    function cancelOrder(Order memory order, bytes memory signature) public {
        bytes32 orderHash = _orderHash(order);

        require(order.maker == msg.sender, "SDCA: PRIVATE_ORDER");

        if (Common._isContract(order.maker)) {
            _verifyERC1271WalletSignature(order.maker, orderHash, signature);
        } else {
            require(ECDSA.recover(orderHash, signature) == order.maker, "SDCA: INVALID_SIGNATURE");
        }
        require(order.expiration > block.timestamp, "SDCA: EXPIRE_ORDER");

        _DCA_FILLEDTIMES_[orderHash] = DCAStates(block.timestamp, order.numberOfTrade);
        emit OrderCancelled(orderHash);
    }

    function sendMaker(Order memory order, address from, uint256 curTakerFillAmount) internal {
        Common._validateAddress(from);
        IERC20(order.outputToken).safeTransferFrom(from, order.maker, curTakerFillAmount);
    }

    function sendFee(Order memory order, address from, address to, uint256 fee) internal {
        Common._validateAddress(from);
        Common._validateAddress(to);
        IERC20(order.outputToken).safeTransferFrom(from, to, fee);
    }

    function _checkIfContractSupportsInterface(address _contract, bytes4 interfaceId) internal view returns (bool) {
        (bool success, bytes memory result) = _contract.staticcall(
            abi.encodeWithSelector(IERC165.supportsInterface.selector, interfaceId)
        );

        if (success && result.length == 32) {
            return abi.decode(result, (bool));
        }
        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IStarBaseDCA).interfaceId;
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
        require(success, "SDCA: ERC1271_SIGNATURE_FAILED");
        bytes4 sigResult = abi.decode(result, (bytes4));
        require(sigResult == 0x1626ba7e, "SDCA: INVALID_SIGNATURE");
    }

    // ============= Ownable Functions ==============
    /**
     * @dev Adds a contract address to the whitelist.
     * @param contractAddr The contract address to add.
     */
    function addWhiteList(address contractAddr) external onlyOwner {
        Common._validateAddress(contractAddr);
        // Ensure the address is not already whitelisted
        require(!isWhiteListed[contractAddr], "SDCA:Address already whitelisted");

        // Add the address to the whitelist
        isWhiteListed[contractAddr] = true;

        // Emit event for successful addition
        emit AddWhiteList(contractAddr);
    }

    /**
     * @dev Removes a contract address from the whitelist.
     * @param contractAddr The contract address to remove.
     */
    function removeWhiteList(address contractAddr) external onlyOwner {
        // Ensure the address is in the whitelist before removing
        require(isWhiteListed[contractAddr], "SDCA:Address not in whitelist");

        // Remove the address from the whitelist
        isWhiteListed[contractAddr] = false;

        // Emit event for successful removal
        emit RemoveWhiteList(contractAddr);
    }

    /**
     * @dev Changes the fee receiver address.
     * @param newFeeReceiver The new fee receiver address.
     */
    function changeFeeReceiver(address newFeeReceiver) external onlyOwner {
        Common._validateAddress(newFeeReceiver);
        _FEE_RECEIVER_ = newFeeReceiver;
        emit ChangeFeeReceiver(newFeeReceiver);
    }

    /**
     * @dev Changes the fee rate.
     * @param feeRate The new fee rate (multiplied by 10000).
     */
    function changeFeeRate(uint160 feeRate) external onlyOwner {
        require(feeRate <= 3000, "SDCA: FEE_RATE_TOO_HIGH");
        _FEE_RATE_ = feeRate;
        emit ChangeFeeRate(feeRate);
    }

    /**
     * @dev Changes the gas limit for ERC1271 signature verification.
     * @param gasLimit The new gas limit for verification.
     */
    function changeVerifyERC127GasLimit(uint160 gasLimit) external onlyOwner {
        require(gasLimit > 0, "SDCA: INVALID_GAS_LIMIT");
        _VLIMIT = gasLimit;
        emit ChangeVerifyERC127GasLimit(gasLimit);
    }

    // ============= Internal Functions ==============

    /**
     * @dev Generates the order hash for an order.
     * @param order The order to hash.
     * @return The hash of the order.
     */
    function _orderHash(Order memory order) private view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        ORDER_TYPEHASH,
                        order.cycleSecondsApart, // executed per minute
                        order.numberOfTrade, // executed 5 times
                        order.inputToken, // sell token
                        order.outputToken, // buy token
                        order.maker,
                        order.inAmount, // total principal
                        order.minOutAmountPerCycle, // minimum out amount per cycle
                        order.maxOutAmountPerCycle, // maximum out amount per cycle
                        order.expiration, // expiration timestamp
                        order.salt
                    )
                )
            );
    }

    // ============= View Functions ==============

    /**
     * @dev Returns the version of the contract.
     * @return The version of the contract.
     */
    function version() external pure returns (uint256) {
        return 101;
    }
}
