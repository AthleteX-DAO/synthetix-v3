import { SettlementStrategySet } from './generated/PerpsMarketProxy/PerpsMarketProxy';
import { SettlementStrategy } from './generated/schema';

export function handleSettlementStrategySet(event: SettlementStrategySet): void {
  const id = event.params.strategyId.toString() + '-' + event.params.marketId.toString();
  const strategy = SettlementStrategy.load(id);
  if (strategy) {
    strategy.strategyId = event.params.strategyId;
    strategy.marketId = event.params.marketId;

    strategy.strategyType = event.params.strategy.strategyType;
    strategy.settlementDelay = event.params.strategy.settlementDelay;
    strategy.settlementWindowDuration = event.params.strategy.settlementWindowDuration;
    strategy.priceVerificationContract =
      event.params.strategy.priceVerificationContract.toHexString();
    strategy.feedId = event.params.strategy.feedId;
    strategy.settlementReward = event.params.strategy.settlementReward;
    strategy.disabled = event.params.strategy.disabled;
    strategy.commitmentPriceDelay = event.params.strategy.commitmentPriceDelay;

    strategy.save();
  }
}
