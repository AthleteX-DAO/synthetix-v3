//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@synthetixio/core-contracts/contracts/ownership/OwnableStorage.sol";
import "@synthetixio/core-contracts/contracts/errors/AccessError.sol";

import "../../interfaces/IMarketManagerModule.sol";
import "../../interfaces/IUSDTokenModule.sol";

import "../../storage/Market.sol";
import "../../storage/Account.sol";

import "@synthetixio/core-modules/contracts/storage/AssociatedSystem.sol";
import "@synthetixio/core-modules/contracts/storage/FeatureFlag.sol";

contract MarketManagerModule is IMarketManagerModule {
    using Market for Market.Data;

    using AssociatedSystem for AssociatedSystem.Data;

    bytes32 private constant _USD_TOKEN = "USDToken";
    bytes32 private constant _MARKET_FEATURE_FLAG = "registerMarket";

    error NotEnoughLiquidity(uint128 marketId, uint amount);
    error MarketDepositNotApproved(address market, address from, uint requestedAmount, uint approvedAmount);

    function registerMarket(address market) external override returns (uint128 marketId) {
        FeatureFlag.ensureEnabled(_MARKET_FEATURE_FLAG);
        // Can we verify that `market` conforms to the IMarket interface here? (i.e. has a `balance()` function?)

        marketId = Market.create(market).id;

        emit MarketRegistered(market, marketId);

        return marketId;
    }

    function getWithdrawableUsd(uint128 marketId) public view override returns (uint) {
        return Market.load(marketId).capacity + Market.load(marketId).getDepositedCollateralValue();
    }

    function getMarketIssuance(uint128 marketId) external view override returns (int128) {
        return Market.load(marketId).issuance;
    }

    function getMarketReportedDebt(uint128 marketId) external view override returns (uint) {
        return Market.load(marketId).getReportedDebt();
    }

    function getMarketCollateral(uint128 marketId) external view override returns (uint) {
        return Market.load(marketId).debtDist.totalShares;
    }

    function getMarketTotalBalance(uint128 marketId) external view override returns (int) {
        return Market.load(marketId).totalBalance();
    }

    function getMarketDebtPerShare(uint128 marketId) external override returns (int) {
        Market.Data storage market = Market.load(marketId);

        market.distributeDebt(999999999);

        return market.debtDist.valuePerShare / 1e9;
    }

    function depositUsd(
        uint128 marketId,
        address target,
        uint amount
    ) external override {
        Market.Data storage market = Market.load(marketId);

        if (msg.sender != market.marketAddress) revert AccessError.Unauthorized(msg.sender);

        // verify if the market is authorized to burn the USD for the target
        ITokenModule usdToken = AssociatedSystem.load(_USD_TOKEN).asToken();

        // Adjust accounting
        market.capacity += uint128(amount);
        market.issuance -= int128(int(amount));

        // burn USD
        IUSDTokenModule(address(usdToken)).burnWithAllowance(target, msg.sender, amount);

        emit UsdDeposited(marketId, target, amount, msg.sender);
    }

    function withdrawUsd(
        uint128 marketId,
        address target,
        uint amount
    ) external override {
        Market.Data storage marketData = Market.load(marketId);

        if (msg.sender != marketData.marketAddress) revert AccessError.Unauthorized(msg.sender);

        if (amount > getWithdrawableUsd(marketId)) revert NotEnoughLiquidity(marketId, amount);

        // Adjust accounting
        marketData.capacity -= uint128(amount);
        marketData.issuance += int128(int(amount));

        // mint some USD
        AssociatedSystem.load(_USD_TOKEN).asToken().mint(target, amount);

        emit UsdWithdrawn(marketId, target, amount, msg.sender);
    }
}
