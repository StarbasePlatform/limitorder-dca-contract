// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStarBaseDCABot {
    function fillStarBaseDCA(bytes memory callExternalData, address outputToken, uint256 minOutputTokenAmount) external;
}
