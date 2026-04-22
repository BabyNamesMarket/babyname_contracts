# BabyNames Prediction Markets

LMSR prediction markets for SSA baby name rankings.

Users create direct binary YES/NO markets for `(name, gender, year, region)` tuples, trade outcome tokens against the LMSR curve, and redeem after oracle resolution.

**[Documentation](https://babynamesmarket.github.io/babyname_contracts/)** | **[API Reference](https://babynamesmarket.github.io/babyname_contracts/api/prediction-market.html)**

## How It Works

```
1. Admin opens year    →  `openYear(2025)`
2. User creates market →  `createNameMarket("olivia", 2025, GIRL, proof, [100e6, 100e6])`
3. Trade freely        →  `trade(...)` or `buyExactIn(...)`
4. Oracle resolves     →  `resolveMarketWithPayoutSplit(...)`
5. Redeem winnings     →  `redeem(token, amount)`
6. Withdraw fees       →  `withdrawSurplus()`
```

## Contracts

| Contract | Description |
|----------|-------------|
| **PredictionMarket** | LS-LMSR market maker with 3% trading fee |
| **MarketValidation** | External name + region validation module |
| **OutcomeToken** | ERC20 per outcome (YES/NO), 6 decimals |
| **TestUSDC** | Testnet USDC clone with open mint and real USDC metadata |

Based on [Context Markets](https://github.com/contextwtf/contracts), used under license.

## Fee Model

| Fee | Rate | When | Purpose |
|-----|------|------|---------|
| Creation | 5% | At market creation | Funds phantom shares + odd dust surplus |
| Trading | 3% | Each trade | protocol revenue (skimmed before LMSR math) |

## Market Scoping

Markets are unique per **(name, gender, year, region)**:
- `createNameMarket("olivia", 2025, GIRL, ...)` — national ranking
- `createRegionalNameMarket("olivia", 2025, GIRL, "CA", ...)` — California state ranking

Names are lowercased for validation and uniqueness. Merkle roots and manual approvals are also gender-specific.

The built-in 50 US states are enabled with `seedDefaultRegions()`. Years are locked by default and must be opened by admin.

## Deployments

### Base Sepolia (84532)

Run `make deploy-base-sepolia` to deploy a fresh Base Sepolia instance. The deployment wrapper now uses a single script/artifact path, verifies contracts automatically, and defaults to deploying a mintable testnet `USDC` clone with 6 decimals.

## Quick Start

```bash
git clone --recurse-submodules https://github.com/BabyNamesMarket/contracts
cd babynames_contracts
forge build
forge test -vv
```

## npm Package

```bash
npm install github:BabyNamesMarket/contracts
```

```javascript
const { getDeployment, getGoldskyConfig, CHAIN_IDS } = require("@babynamesmarket/contracts");
const deploy = getDeployment(CHAIN_IDS.baseSepolia);
const goldsky = getGoldskyConfig(CHAIN_IDS.baseSepolia);
```

## Documentation

- [Getting Started](docs/getting-started.md)
- [Architecture](docs/architecture.md)
- [Market Lifecycle](docs/lifecycle.md)
- [Fee Model](docs/fees.md)
- [LMSR Pricing](docs/lmsr.md)
- [Integration Guide](docs/integration.md)
- [Deployment](docs/deployment.md)
- API Reference: [PredictionMarket](docs/api/prediction-market.md) | [OutcomeToken](docs/api/outcome-token.md)

## License

BUSL-1.1 (source contracts), MIT (tests and scripts)
