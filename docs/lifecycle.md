# Market Lifecycle

## Phase 1: Admin Setup

Before market creation:

- owner binds `MarketValidation` with `setValidation`
- owner sets `defaultOracle`
- owner sets `defaultSurplusRecipient`
- owner opens a year with `openYear(year)`
- owner seeds the built-in 50-state region set with `seedDefaultRegions()`
- owner optionally sets Merkle roots with `setNamesMerkleRoot`

## Phase 2: Market Creation

Anyone can create a market for a valid `(name, gender, year, region)` tuple:

```solidity
predictionMarket.createNameMarket("olivia", 2025, PredictionMarket.Gender.GIRL, proof, [20e6, 0]);
predictionMarket.createRegionalNameMarket("olivia", 2025, PredictionMarket.Gender.GIRL, "CA", proof, [10e6, 10e6]);
```

Requirements:

- name is lowercased ASCII letters only
- year is open
- region is empty or a valid US state code / approved override
- market key is unique
- `initialBuyAmounts.length == 2`
- gross budget is non-zero

## Phase 3: Fee Split and Bootstrap

On creation:

- each side pays the creation fee in basis points, default `5%`
- the total fee seeds symmetric phantom shares
- any odd 1-unit fee dust is explicitly collected and credited to `surplus`
- the remaining net YES/NO budgets are spent into the fresh LMSR market

The creator receives the resulting YES/NO outcome tokens directly.

## Phase 4: Trading

Once created, anyone can trade:

```solidity
predictionMarket.trade(Trade({
    marketId: marketId,
    deltaShares: [int256(10e6), int256(0)],
    maxCost: 15e6,
    minPayout: 0,
    deadline: block.timestamp + 300
}));
```

Trading behavior:

- buys pay gross cost including the trading fee
- sells receive net payout after the trading fee
- tiny buy-side trades are rounded up so positive mints can never be free
- markets can be paused globally or per-market

## Phase 5: Resolution

The oracle resolves the market with payout percentages summing to `1e6`:

```solidity
predictionMarket.resolveMarketWithPayoutSplit(marketId, [1e6, 0]);
```

Resolution computes:

- token-holder payouts owed on outstanding shares
- remaining pool surplus owed to `surplusRecipient`

## Phase 6: Redemption

Token holders redeem resolved YES/NO tokens:

```solidity
predictionMarket.redeem(tokenAddress, amount);
```

This burns outcome tokens and transfers USDC according to the resolved payout percentage.

## Phase 7: Surplus Withdrawal

Recipients can withdraw:

- trading fees
- collected odd creation-fee dust
- post-resolution market surplus

```solidity
predictionMarket.withdrawSurplus();
```
