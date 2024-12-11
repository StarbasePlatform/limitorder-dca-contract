// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStarBaseDCA {
    // Order 结构体
    struct Order {
        uint160 cycleSecondsApart; // executed per second
        uint160 numberOfTrade; // executed 5 times
        address inputToken; // sell
        address outputToken; // buy
        address maker;
        uint160 inAmount; // One of the total (numberOfTrade)
        uint256 minOutAmountPerCycle; // min out amount
        uint256 maxOutAmountPerCycle; // max out amount
        uint256 expiration;
        uint256 salt;
    }
    // ============ DCA ===============
    function fillDCA(
        Order memory order,
        bytes memory signature,
        bytes memory takerInteraction
    ) external returns (uint256 curTakerFillAmount);

    function cancelOrder(Order memory order, bytes memory signature) external;
}
