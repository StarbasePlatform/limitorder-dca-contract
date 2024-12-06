// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStarBaseLimitOrderBot {
    struct SwapData {
        address callSwapAddr;
        bytes datas;
    }
    function fillStarBaseLimitOrder(
        bytes memory callExternalData, // call StarBaseLimitOrder
        address takerToken,
        uint256 minTakerTokenAmount
    ) external;
    function doLimitOrderSwap(
        uint256 curTakerFillAmount,
        uint256 curMakerFillAmount,
        address makerToken, // fromToken
        address takerToken, // toToken
        address StarBaseRouteProxy,
        SwapData calldata datas
    ) external;
}
