# BabyNames Prediction Markets

LMSR prediction markets for SSA baby name rankings.

Users bet on whether baby names will appear in the Social Security Administration's annual top rankings. Markets are bootstrapped through commitments: propose a name, commit capital, wait for the scheduled launch time, then claim the resulting outcome tokens once the live market is created.

**[Documentation](https://babynamesmarket.github.io/babyname_contracts/)** | **[API Reference](https://babynamesmarket.github.io/babyname_contracts/api/prediction-market.html)**

## How It Works

```
1. Propose a name      →  launchpad.propose("olivia", 2025, GIRL, proof, [$5, $0])
2. Others commit       →  launchpad.commit(proposalId, [$10, $0])
3. Launch time arrives →  launchpad.launchMarket(proposalId)
4. Claim tokens        →  launchpad.claimShares(proposalId)
5. Trade freely        →  predictionMarket.trade(...)
6. Oracle resolves     →  predictionMarket.resolveMarketWithPayoutSplit(...)
7. Redeem winnings     →  predictionMarket.redeem(token, amount)
```

## Contracts

| Contract | Description |
|----------|-------------|
| **PredictionMarket** | LS-LMSR market maker with 3% trading fee |
| **Launchpad** | Commitment bootstrapping with 5% fee, gender/year/region scoping |
| **OutcomeToken** | ERC20 per outcome (YES/NO), 6 decimals |

Based on [Context Markets](https://github.com/contextwtf/contracts), used under license.

## Fee Model

| Fee | Rate | When | Purpose |
|-----|------|------|---------|
| Commitment | 5% | At commit | Funds phantom shares (market depth) + protocol revenue |
| Trading | 3% | Each trade | protocol revenue (skimmed before LMSR math) |

Commitment fees are separated at commit time. Proposals launch into a live market on schedule; unspent launch budget is claimable as a refund after launch.

## Market Scoping

Markets are unique per **(name, gender, year, region)**:
- `propose("olivia", 2025, GIRL, ...)` — national ranking
- `proposeRegional("olivia", 2025, GIRL, "CA", ...)` — California state ranking

Names are lowercased for validation and uniqueness. Merkle roots and manual approvals are also gender-specific.

50 US states prepopulated. Years locked by default — admin opens with `openYear(2025)`.

## Deployments

### Base Sepolia (84532)

| Contract | Address |
|----------|---------|
| PredictionMarket | [`0x7000...6F6c`](https://sepolia.basescan.org/address/0x7000667CF33833F97120a13b4D12A795142f6F6c) |
| Launchpad | [`0x08ED...882b`](https://sepolia.basescan.org/address/0x08EDA78b3434A7774Cb4a012B2D7c8231F09882b) |
| TestUSDC | [`0x43fA...A575`](https://sepolia.basescan.org/address/0x43fAbD625f96b93edAC2F370a2fe246b2E09A575) |

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
const {
  PredictionMarketABI,
  LaunchpadABI,
  getDeployment,
  getGoldskyConfig,
  CHAIN_IDS,
}
  = require("@babynamesmarket/contracts");

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
- API Reference: [PredictionMarket](docs/api/prediction-market.md) | [Launchpad](docs/api/launchpad.md) | [OutcomeToken](docs/api/outcome-token.md)

## License

BUSL-1.1 (source contracts), MIT (tests and scripts)
