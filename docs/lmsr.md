# LMSR Pricing

The market uses a liquidity-sensitive LMSR. This page focuses on the math used by the current `PredictionMarket` contract.

## Core Formulas

### Alpha

```
alpha = targetVig / (n × ln(n))
```

For a binary market with `n = 2` and `targetVig = 70_000`:

```
alpha ≈ 0.05049 in normalized units
```

### Liquidity Parameter

```
b = alpha × totalQ / ONE
```

Where `totalQ` is the sum of outstanding YES and NO quantities.

### Cost Function

```
cost(q) = b × ln(Σ exp(qᵢ / b))
```

Trade cost is the delta between the old and new market states:

```
tradeCost = cost(newQ) - cost(oldQ)
```

## Phantom Shares

Markets are seeded with symmetric phantom shares funded by the creation fee:

```
initialSharesPerOutcome = totalCreationFee × ONE / targetVig
```

Example:

```
Initial budgets: [100 USDC, 100 USDC]
Creation fee: 5% per side
Total creation fee: 10 USDC
initialSharesPerOutcome = 10e6 × 1e6 / 70_000 ≈ 142.857 shares
```

These phantom shares are not owned by users. They provide initial depth so the first trades do not move price infinitely.

## Numerical Stability

Exponentials are computed with an offset:

```
offset = max(qᵢ) / b
expᵢ = exp(qᵢ / b - offset)
```

This avoids overflow while preserving the correct `log-sum-exp` result.

## Trading Fees vs LMSR Cost

The fee layer sits on top of the pure LMSR quote.

### Buy

```
gross paid by user = LMSR cost + fee
fee = LMSR cost × feeBps / (10000 - feeBps)
```

### Sell

```
gross LMSR payout = -quoteTrade(...)
fee = gross payout × feeBps / 10000
net received by user = gross payout - fee
```

`quoteTrade()` returns the fee-free LMSR delta.

## Rounding Safety

The contract rounds buy-side quotes so that any positive mint costs at least `1` micro-USDC. This prevents zero-cost minting from integer rounding.

## Solvency

At resolution, the contract verifies:

```
totalUsdcIn >= totalPayout
```

Any remainder becomes withdrawable surplus for the configured recipient.
