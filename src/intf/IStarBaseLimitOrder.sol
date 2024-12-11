// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStarBaseLimitOrder {
    struct Order {
        address makerToken;
        address takerToken;
        uint160 makerAmount;
        uint160 takerAmount;
        address maker;
        uint256 expiration;
        uint256 salt;
    }

    event LimitOrderFilled(
        address indexed maker,
        address indexed taker,
        bytes32 orderHash,
        uint160 curTakerFillAmount,
        uint160 curMakerFillAmount
    );

    function fillLimitOrder(
        Order calldata order,
        bytes memory signature,
        uint160 takerFillAmount,
        uint160 thresholdTakerAmount,
        bytes memory takerInteraction
    ) external returns (uint160 curTakerFillAmount, uint160 curMakerFillAmount);

    function cancelOrder(Order memory order, bytes memory signature) external;

    function addWhiteList(address contractAddr) external;

    function removeWhiteList(address contractAddr) external;

    function changeFeeReceiver(address newFeeReceiver) external;

    function changeFeeRate(uint160 feeRate) external;
}
