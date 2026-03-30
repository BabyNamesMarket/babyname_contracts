# BabyNames Prediction Markets

LMSR prediction markets for SSA baby name rankings.

Users bet on whether baby names will appear in the Social Security Administration's annual top rankings. Markets are bootstrapped through commitments — propose a name, commit capital, and once enough interest accumulates the market launches with all participants getting the same fair price.

**[Documentation](https://babynamesmarket.github.io/babyname_contracts/)** | **[API Reference](https://babynamesmarket.github.io/babyname_contracts/api/prediction-market.html)**

## How It Works

```
1. Propose a name      →  launchpad.propose("olivia", 2025, proof, [$5, $0])
2. Others commit       →  launchpad.commit(proposalId, [$10, $0])
3. Market launches     →  launchpad.launchMarket(proposalId)
4. Claim tokens        →  launchpad.claimShares(proposalId)
5. Trade freely        →  predictionMarket.trade(...)
6. Oracle resolves     →  predictionMarket.resolveMarketWithPayoutSplit(...)
7. Redeem winnings     →  predictionMarket.redeem(token, amount)
```

## Contracts

| Contract | Description |
|----------|-------------|
| **PredictionMarket** | LS-LMSR market maker with 3% trading fee |
| **Launchpad** | Commitment bootstrapping with 5% fee, year/region scoping |
| **OutcomeToken** | ERC20 per outcome (YES/NO), 6 decimals |
| **RewardDistributor** | Merkle-based USDC reward distribution |

Based on [Context Markets](https://github.com/contextwtf/contracts), used under license.

## Fee Model

| Fee | Rate | When | Purpose |
|-----|------|------|---------|
| Commitment | 5% | At commit | Funds phantom shares (market depth) + protocol revenue |
| Trading | 3% | Each trade | protocol revenue (skimmed before LMSR math) |

Commitment fees are refunded in full if the market never launches.

## Market Scoping

Markets are unique per **(name, year, region)**:
- `propose("olivia", 2025, ...)` — national ranking
- `proposeRegional("olivia", 2025, "CA", ...)` — California state ranking

50 US states prepopulated. Years locked by default — admin opens with `openYear(2025)`.

## Deployments

### Base Sepolia (84532) — verified

| Contract | Address |
|----------|---------|
| PredictionMarket | [`0x168a...7E366`](https://sepolia.basescan.org/address/0x168a1808b563224b0AA69FA3bb7214940ac7E366) |
| Launchpad | [`0x3c1f...974f`](https://sepolia.basescan.org/address/0x3c1fc7971b0e965eC76cce38108AE2d7c1A6974f) |
| TestUSDC | [`0x4e9F...d49bc`](https://sepolia.basescan.org/address/0x4e9F02904c36F7CeB044eB53112Eaf3276fD49bc) |

## Quick Start

```bash
git clone --recurse-submodules https://github.com/BabyNamesMarket/contracts
cd babynames_contracts
forge build
forge test -vv     # 96 tests
```

## npm Package

```bash
npm install github:BabyNamesMarket/contracts
```

```javascript
const { PredictionMarketABI, LaunchpadABI, getDeployment, CHAIN_IDS }
  = require("@babynamesmarket/contracts");

const deploy = getDeployment(CHAIN_IDS.baseSepolia);
```

## Documentation

- [Getting Started](docs/getting-started.md)
- [Architecture](docs/architecture.md)
- [Market Lifecycle](docs/lifecycle.md)
- [Fee Model](docs/fees.md)
- [LMSR Pricing](docs/lmsr.md)
- [Integration Guide](docs/integration.md)
- [Deployment](docs/deployment.md)
- API Reference: [PredictionMarket](docs/api/prediction-market.md) | [Launchpad](docs/api/launchpad.md) | [OutcomeToken](docs/api/outcome-token.md) | [RewardDistributor](docs/api/reward-distributor.md)

## License

BUSL-1.1 (source contracts), MIT (tests and scripts)
