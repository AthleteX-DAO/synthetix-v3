//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import {OwnableStorage} from "@synthetixio/core-contracts/contracts/ownership/OwnableStorage.sol";
import {PerpMarketConfiguration} from "../storage/PerpMarketConfiguration.sol";
import {PerpMarket} from "../storage/PerpMarket.sol";
import "../interfaces/IPerpConfigurationModule.sol";

contract PerpConfigurationModule is IPerpConfigurationModule {
    /**
     * @inheritdoc IPerpConfigurationModule
     */
    function setMarketConfiguration(IPerpConfigurationModule.ConfigureParameters memory data) external {
        OwnableStorage.onlyOwner();

        PerpMarketConfiguration.GlobalData storage config = PerpMarketConfiguration.load();

        config.minMarginUsd = data.minMarginUsd;
        config.priceDivergencePercent = data.priceDivergencePercent;
        config.pythPublishTimeMin = data.pythPublishTimeMin;
        config.pythPublishTimeMax = data.pythPublishTimeMax;
        config.minOrderAge = data.minOrderAge;
        config.maxOrderAge = data.maxOrderAge;
        config.minKeeperFeeUsd = data.minKeeperFeeUsd;
        config.maxKeeperFeeUsd = data.maxKeeperFeeUsd;
        config.keeperProfitMarginPercent = data.keeperProfitMarginPercent;
        config.keeperSettlementGasUnits = data.keeperSettlementGasUnits;
        config.keeperLiquidationGasUnits = data.keeperLiquidationGasUnits;
        config.keeperLiquidationFeeUsd = data.keeperLiquidationFeeUsd;

        emit ConfigurationUpdated(msg.sender);
    }

    /**
     * @inheritdoc IPerpConfigurationModule
     */
    function setMarketConfigurationById(
        uint128 marketId,
        IPerpConfigurationModule.ConfigureByMarketParameters memory data
    ) external {
        OwnableStorage.onlyOwner();

        PerpMarketConfiguration.Data storage config = PerpMarketConfiguration.load(marketId);

        // Only allow an existing per market to be configurable. Ensure it's first created then configure.
        PerpMarket.exists(marketId);

        config.oracleNodeId = data.oracleNodeId;
        config.pythPriceFeedId = data.pythPriceFeedId;
        config.skewScale = data.skewScale;
        config.makerFee = data.makerFee;
        config.takerFee = data.takerFee;
        config.maxLeverage = data.maxLeverage;
        config.maxMarketSize = data.maxMarketSize;
        config.maxFundingVelocity = data.maxFundingVelocity;
        config.liquidationBufferPercent = data.liquidationBufferPercent;
        config.liquidationFeePercent = data.liquidationFeePercent;
        config.liquidationPremiumMultiplier = data.liquidationPremiumMultiplier;

        emit MarketConfigurationUpdated(marketId, msg.sender);
    }

    // --- Views --- //

    /**
     * @inheritdoc IPerpConfigurationModule
     */
    function getMarketParameters() external pure returns (PerpMarketConfiguration.GlobalData memory) {
        return PerpMarketConfiguration.load();
    }

    /**
     * @inheritdoc IPerpConfigurationModule
     */
    function getMarketParametersById(uint128 marketId) external pure returns (PerpMarketConfiguration.Data memory) {
        return PerpMarketConfiguration.load(marketId);
    }
}
