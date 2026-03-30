# Fee Model

the protocol earns revenue from two sources: commitment fees and trading fees. Both are cleanly separated from the core LMSR math.

## Commitment Fee (5%)

Collected by the Launchpad on every commitment. Separated at commit time, not at launch.

```
User commits $20
├── $1.00 fee (5%) → held by Launchpad
└── $19.00 net → tracked for share distribution
```

### At Launch

The collected fees fund the market's initial liquidity (phantom shares):

```
Total fees collected: $1.00
Creation fee cap: $10.00
Creation fee used: min($1.00, $10.00) = $1.00
  → $0.50 per outcome → s = 14.3 phantom shares
Excess fees: $0.00 → the protocol treasury
```

For larger commitments where fees exceed the cap:

```
$400 committed → $20 fees collected
Creation fee used: min($20, $10) = $10
  → $5 per outcome → s = 142.9 phantom shares
Excess fees: $10 → the protocol treasury (direct revenue)
```

### On Expiry

If the market never launches, users get 100% back:

```
User committed $20 gross
Market expired without launching
User withdraws $20 (full gross, fee is not charged)
```

### Admin Controls

| Parameter | Default | Description |
|-----------|---------|-------------|
| `commitmentFeeBps` | 500 (5%) | Fee rate on commitments |
| `maxCreationFee` | $10 | Cap on fees used for phantom shares |

## Trading Fee (3%)

Collected by PredictionMarket on every trade. Skimmed before the LMSR calculation sees the funds.

### On Buys

```
User wants to buy shares, willing to pay $10 gross
├── Fee: $10 × 3% ÷ (100% - 3%) = $0.31 → surplus[treasury]
└── LMSR cost: $9.69 → market liquidity pool
```

The fee formula ensures the net amount exactly covers the LMSR cost:
`fee = lmsrCost × feeBps ÷ (10000 - feeBps)`

### On Sells

```
LMSR pays out $10
├── Fee: $10 × 3% = $0.30 → surplus[treasury]
└── User receives: $9.70
```

### Fee-Exempt Trades

The Launchpad's aggregate bootstrap trade uses `tradeRaw()` which bypasses the trading fee entirely. The commitment fee already covers this trade — double-charging would be unfair.

### Per-Market Overrides

Admin can set a custom trading fee for specific markets:

```solidity
predictionMarket.setMarketTradingFee(marketId, 100); // 1% for this market
predictionMarket.setMarketTradingFee(marketId, 0);   // revert to global default
```

### Admin Controls

| Parameter | Default | Max | Description |
|-----------|---------|-----|-------------|
| `tradingFeeBps` | 300 (3%) | 1000 (10%) | Global trading fee |
| `marketTradingFeeBps[id]` | 0 (use global) | 1000 (10%) | Per-market override |

## Revenue Summary

| Source | Rate | When | Goes To |
|--------|------|------|---------|
| Commitment fee | 5% | At commit | Phantom shares (up to $10) + the protocol excess |
| Trading fee (buys) | 3% | Each buy | `surplus[surplusRecipient]` |
| Trading fee (sells) | 3% | Each sell | `surplus[surplusRecipient]` |
| Vig surplus | ~7% of balanced volume | At resolution | `surplus[surplusRecipient]` |

The vig surplus is unreliable on one-sided markets (if YES wins and all bets were YES, surplus is minimal). The commitment and trading fees provide guaranteed revenue regardless of resolution outcome.

Surplus is withdrawn by the recipient via `predictionMarket.withdrawSurplus()`.
