# BabyNames Prediction Markets

Prediction markets for SSA baby name rankings, powered by LMSR automated market making.

## How It Works

Users bet on whether a baby name will appear in the Social Security Administration's annual top name rankings. Markets are bootstrapped through a commitment system: users propose names, commit capital until the scheduled launch time, then claim into a live LMSR market after launch.

## Quick Links

- [Getting Started](getting-started.md) - Setup, build, and test
- [Architecture](architecture.md) - Contract design and relationships
- [Market Lifecycle](lifecycle.md) - From proposal to resolution
- [Fee Model](fees.md) - Commitment fees, trading fees, and revenue
- [LMSR Pricing](lmsr.md) - How the market maker works
- [API Reference](api/prediction-market.md) - Contract interfaces
- [Integration Guide](integration.md) - Frontend integration with npm package
- [Deployment](deployment.md) - Deploy to testnets and mainnet

## Contracts

| Contract | Description |
|----------|-------------|
| [PredictionMarket](api/prediction-market.md) | LMSR market maker with 3% trading fee |
| [Launchpad](api/launchpad.md) | Commitment bootstrapping with 5% fee, gender/year/region scoping |
| [OutcomeToken](api/outcome-token.md) | ERC20 outcome tokens (YES/NO) |
| [RewardDistributor](api/reward-distributor.md) | Merkle-based USDC rewards |

## Deployed Addresses

### Base Sepolia (84532)

| Contract | Address |
|----------|---------|
| PredictionMarket | [`0x7000...6F6c`](https://sepolia.basescan.org/address/0x7000667CF33833F97120a13b4D12A795142f6F6c) |
| Launchpad | [`0x08ED...882b`](https://sepolia.basescan.org/address/0x08EDA78b3434A7774Cb4a012B2D7c8231F09882b) |
| TestUSDC | [`0x43fA...A575`](https://sepolia.basescan.org/address/0x43fAbD625f96b93edAC2F370a2fe246b2E09A575) |
| RewardDistributor | [`0x5B74...9Fe0`](https://sepolia.basescan.org/address/0x5B740001E88B2df9e96e84B75f7150496fA19Fe0) |

Based on [Context Markets](https://github.com/contextwtf/contracts) contracts, used under license.
