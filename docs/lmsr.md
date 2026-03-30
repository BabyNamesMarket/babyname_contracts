# LMSR Pricing

The market uses Liquidity-Sensitive LMSR (LS-LMSR) from [Othman et al. 2013](https://dl.acm.org/doi/10.1145/2509413.2509414). This page explains the math for those who want to understand the pricing.

## Core Formulas

### Alpha (market responsiveness)

```
alpha = targetVig / (n × ln(n))
```

For a binary market (n=2) with 7% vig:
```
alpha = 0.07 / (2 × ln(2)) = 0.05049
```

### Liquidity parameter b

```
b = alpha × totalQ / ONE
```

Where `totalQ = sum of all outcome quantities`. b grows as trading volume increases — the market becomes deeper over time (liquidity-sensitive).

### Cost function

```
cost(q) = b × ln(Σ exp(qᵢ / b))
```

The cost of moving from state A to state B is:
```
tradeCost = cost(B) - cost(A)
```

This is **path-independent** — the cost is the same regardless of the order trades are executed.

### Prices

```
price_i = softmax(qᵢ / b) + alpha × H(s)
```

Where `H(s)` is the entropy of the softmax distribution. Prices always sum to slightly above 1.0 (the excess is the vig).

### Numerical stability

All exponentials use offset subtraction to prevent overflow:

```
offset = max(qᵢ) / b
expᵢ = exp(qᵢ/b - offset)
sumExp = Σ expᵢ
lnSum = ln(sumExp) + offset    // add offset back
cost = b × lnSum
```

## Phantom Shares

When a market is created, each outcome starts with `initialSharesPerOutcome` (s) phantom shares. These aren't owned by anyone — they provide the initial liquidity curve.

```
s = totalCreationFee × ONE / targetVig
```

At $5 per outcome (binary): `s = 10,000,000 / 70,000 = 142.86`

The phantom shares determine initial market depth:

| Creation Fee (total) | s (shares) | b₀ | Cost: 50¢ → 90¢ |
|---------------------|------------|-----|------------------|
| $0.10 | 1.4 | 0.14 | $0.27 |
| $1.00 | 14.3 | 1.44 | $2.74 |
| $5.00 | 71.4 | 7.21 | $13.68 |
| $10.00 | 142.9 | 14.43 | $27.36 |

## Solvency

The LMSR guarantees solvency: `cost(q) >= max(qᵢ)` for any state. This means the contract always holds enough USDC to cover the worst-case payout. This is a mathematical property of log-sum-exp.

Verified across 512 randomized trade sequences in fuzz tests with zero insolvency events.

## How Trading Fees Interact

Trading fees are a layer **on top of** the LMSR:

```
User wants to buy shares:
  1. User sends $10 gross to PredictionMarket
  2. PM skims 3% fee ($0.31) → surplus
  3. Remaining $9.69 goes to LMSR cost function
  4. LMSR computes how many shares $9.69 buys
  5. Tokens minted to user
```

The LMSR never sees the fee. `quoteTrade()` returns the pure LMSR cost. The fee is added on top by the `trade()` function.

The Launchpad's bootstrap trade uses `tradeRaw()` which skips the fee entirely — the commitment fee already covered the bootstrap.

## Example: Price Movement

Starting from 50/50 with s=142.9 (from $10 creation fee):

| Action | YES Price | NO Price | Cost |
|--------|-----------|----------|------|
| Initial state | $0.535 | $0.535 | - |
| Buy 10 YES | $0.546 | $0.524 | $5.44 |
| Buy 50 YES | $0.601 | $0.471 | $26.84 |
| Buy 100 YES | $0.685 | $0.394 | $51.91 |
| Buy 500 YES | $0.969 | $0.063 | $190.97 |

Prices approach but never reach $0 or $1 — there's always a small probability assigned to every outcome.
