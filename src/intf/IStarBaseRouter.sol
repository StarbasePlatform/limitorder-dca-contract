/*

    Copyright 2020 StarBase.
    SPDX-License-Identifier: Apache-2.0

*/

pragma solidity ^0.8.4;

interface IStarBaseRouter {
    function defiSwap(
        uint amountIn,
        uint amountOutMin,
        address tokenIn,
        address tokenOut,
        address receiver,
        address callSwapAddr,
        bytes calldata datas
    ) external;
}
