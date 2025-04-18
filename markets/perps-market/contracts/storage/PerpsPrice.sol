//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {INodeModule} from "@synthetixio/oracle-manager/contracts/interfaces/INodeModule.sol";
import {NodeOutput} from "@synthetixio/oracle-manager/contracts/storage/NodeOutput.sol";
import {SafeCastI256, SafeCastU256} from "@synthetixio/core-contracts/contracts/utils/SafeCast.sol";
import {ParameterError} from "@synthetixio/core-contracts/contracts/errors/ParameterError.sol";
import {PerpsMarketFactory} from "./PerpsMarketFactory.sol";

/**
 * @title Price storage for a specific synth market.
 */
library PerpsPrice {
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;

    enum Tolerance {
        DEFAULT,
        STRICT,
        ONE_MONTH
    }

    uint256 private constant ONE_MONTH = 2592000;

    struct Data {
        /**
         * @dev the price feed id for the market.  this node is processed using the oracle manager which returns the price.
         * @dev the staleness tolerance is provided as a runtime argument to this feed for processing.
         */
        bytes32 feedId;
        /**
         * @dev strict tolerance in seconds, mainly utilized for liquidations.
         */
        uint256 strictStalenessTolerance;
    }

    function load(uint128 marketId) internal pure returns (Data storage price) {
        bytes32 s = keccak256(abi.encode("io.synthetix.perps-market.Price", marketId));
        assembly {
            price.slot := s
        }
    }

    function getCurrentPrices(
        uint256[] memory marketIds,
        Tolerance priceTolerance
    ) internal view returns (uint256[] memory prices) {
        // map all the market ids to feed ids
        INodeModule oracleManager = INodeModule(PerpsMarketFactory.load().oracle);
        bytes32[] memory feedIds = new bytes32[](marketIds.length);
        for (uint256 i = 0; i < marketIds.length; i++) {
            feedIds[i] = load(marketIds[i].to128()).feedId;
        }

        NodeOutput.Data[] memory outputs;
        if (priceTolerance != Tolerance.DEFAULT) {
            bytes32[] memory sharedRuntimeKeys = new bytes32[](1);
            sharedRuntimeKeys[0] = bytes32("stalenessTolerance");

            bytes32[][] memory runtimeKeys = new bytes32[][](marketIds.length);
            bytes32[][] memory runtimeValues = new bytes32[][](marketIds.length);

            for (uint256 i = 0; i < marketIds.length; i++) {
                bytes32[] memory newRuntimeValues = new bytes32[](1);
                newRuntimeValues[0] = toleranceBytes(load(marketIds[i].to128()), priceTolerance);
                runtimeKeys[i] = sharedRuntimeKeys;
                runtimeValues[i] = newRuntimeValues;
            }

            outputs = oracleManager.processManyWithManyRuntime(feedIds, runtimeKeys, runtimeValues);
        } else {
            bytes32[] memory runtimeKeys = new bytes32[](0);
            // do the process call
            outputs = oracleManager.processManyWithRuntime(feedIds, runtimeKeys, runtimeKeys);
        }

        // extract the prices
        prices = new uint256[](marketIds.length);
        for (uint256 i = 0; i < marketIds.length; i++) {
            prices[i] = outputs[i].price.toUint();
        }
    }

    function getCurrentPrice(
        uint128 marketId,
        Tolerance priceTolerance
    ) internal view returns (uint256 price) {
        Data storage self = load(marketId);
        PerpsMarketFactory.Data storage factory = PerpsMarketFactory.load();
        NodeOutput.Data memory output;
        if (priceTolerance == Tolerance.DEFAULT) {
            output = INodeModule(factory.oracle).process(self.feedId);
        } else {
            bytes32[] memory runtimeKeys = new bytes32[](1);
            bytes32[] memory runtimeValues = new bytes32[](1);
            runtimeKeys[0] = bytes32("stalenessTolerance");
            runtimeValues[0] = toleranceBytes(self, priceTolerance);
            output = INodeModule(factory.oracle).processWithRuntime(
                self.feedId,
                runtimeKeys,
                runtimeValues
            );
        }

        return output.price.toUint();
    }

    function update(Data storage self, bytes32 feedId, uint256 strictStalenessTolerance) internal {
        self.feedId = feedId;
        self.strictStalenessTolerance = strictStalenessTolerance;
    }

    function toleranceBytes(
        Data storage self,
        Tolerance tolerance
    ) internal view returns (bytes32) {
        if (tolerance == Tolerance.STRICT) {
            return bytes32(self.strictStalenessTolerance);
        } else if (tolerance == Tolerance.ONE_MONTH) {
            return bytes32(ONE_MONTH);
        } else {
            return bytes32(0);
        }
    }
}
