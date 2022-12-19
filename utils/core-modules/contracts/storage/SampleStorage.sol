//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library SampleStorage {
    bytes32 private constant _slotSampleStorage =
        keccak256(abi.encode("io.synthetix.core-modules.Sample"));

    struct Data {
        uint someValue;
        uint protectedValue;
    }

    function load() internal pure returns (Data storage store) {
        bytes32 s = _slotSampleStorage;
        assembly {
            store.slot := s
        }
    }
}
