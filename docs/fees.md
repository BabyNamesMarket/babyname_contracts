# Fee Model

The current protocol earns revenue from two sources:

- creation fees on market creation
- trading fees on buys and sells

## Creation Fee

Collected when a user creates a market with `createNameMarket` or `createRegionalNameMarket`.

Default:

- `creationFeeBps = 500`
- `5%` of each side's initial buy budget

Example:

```
Creator supplies [100 USDC YES, 100 USDC NO]
├── 5 USDC creation fee from YES side
├── 5 USDC creation fee from NO side
└── 190 USDC total net budget enters bootstrap buys
```

The total collected creation fee seeds symmetric phantom shares:

```
initialSharesPerOutcome = totalCreationFee * 1e6 / targetVig
```

### Odd-Fee Dust

If total creation fee is odd in micro-USDC units, the 1-unit dust is:

- explicitly collected from the creator
- credited to `surplus[surplusRecipient]`

This avoids unbacked surplus accounting.

## Trading Fee

Collected by `PredictionMarket` on every trade.

Default:

- `tradingFeeBps = 300`
- `3%`

### Buys

For buys, the user pays:

```
gross cost = LMSR cost + fee
fee = LMSR cost * feeBps / (10000 - feeBps)
```

The fee is credited to `surplus[surplusRecipient]`. Only the net LMSR cost increases `totalUsdcIn`.

### Sells

For sells, the market computes the LMSR payout first, then skims the trading fee:

```
fee = LMSR payout * feeBps / 10000
user receives = LMSR payout - fee
```

## Resolution Surplus

At resolution, any remaining market pool after paying all outstanding winning claims is also credited to `surplus[surplusRecipient]`.

## Revenue Summary

| Source | Default | When | Recipient |
|---|---|---|---|
| Creation fee | `5%` | On market creation | Phantom shares + odd dust to surplus |
| Trading fee | `3%` | On each buy/sell | `surplus[surplusRecipient]` |
| Resolution surplus | variable | On resolution | `surplus[surplusRecipient]` |

## Withdrawal

Surplus is withdrawn by the credited address:

```solidity
predictionMarket.withdrawSurplus();
```
