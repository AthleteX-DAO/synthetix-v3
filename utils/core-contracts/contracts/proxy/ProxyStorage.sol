//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract ProxyStorage {
    bytes32 private constant _slotProxyStorage =
        keccak256(abi.encode("io.synthetix.core-contracts.Proxy"));

    struct ProxyStore {
        address implementation;
        bool simulatingUpgrade;
    }

    function _proxyStore() internal pure returns (ProxyStore storage store) {
        bytes32 s = _slotProxyStorage;
        assembly {
            store.slot := s
        }
    }
}
