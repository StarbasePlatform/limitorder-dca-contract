/*

    Copyright 2020 StarBase.
    SPDX-License-Identifier: Apache-2.0

*/

pragma solidity ^0.8.4;

interface IStarBaseApprove {
    function claimTokens(address token, address who, address dest, uint160 amount) external;
    function getStarBaseProxy() external view returns (address);
}
