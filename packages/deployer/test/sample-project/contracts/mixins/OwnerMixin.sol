//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../storage/OwnerNamespace.sol";

contract OwnerMixin is OwnerNamespace {
    /* MODIFIERS */

    modifier onlyOwner() {
        require(msg.sender == _ownerStorage().owner, "Only owner allowed");
        _;
    }
}
