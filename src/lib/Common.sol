/*
    SPDX-License-Identifier: Apache-2.0
*/

pragma solidity ^0.8.4;

library Common {
    function _validateAddress(address _addr) internal pure {
        require(_addr != address(0), "Address cannot be zero");
    }

    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}
