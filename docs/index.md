# BabyNames Prediction Markets

Prediction markets for SSA baby name rankings, powered by LMSR automated market making.

## How It Works

Users bet on whether a baby name will appear in the Social Security Administration's annual top name rankings. Markets are bootstrapped through a commitment system — users propose names, commit capital, and once enough interest accumulates the market launches automatically. After launch, anyone can trade freely on the LMSR market maker.

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
| [Launchpad](api/launchpad.md) | Commitment bootstrapping with 5% fee, year/region scoping |
| [OutcomeToken](api/outcome-token.md) | ERC20 outcome tokens (YES/NO) |
| [RewardDistributor](api/reward-distributor.md) | Merkle-based USDC rewards |

## Deployed Addresses

### Base Sepolia (84532)

| Contract | Address |
|----------|---------|
| PredictionMarket | [`0x168a...7E366`](https://sepolia.basescan.org/address/0x168a1808b563224b0AA69FA3bb7214940ac7E366) |
| Launchpad | [`0x3c1f...974f`](https://sepolia.basescan.org/address/0x3c1fc7971b0e965eC76cce38108AE2d7c1A6974f) |
| TestUSDC | [`0x4e9F...d49bc`](https://sepolia.basescan.org/address/0x4e9F02904c36F7CeB044eB53112Eaf3276fD49bc) |

Based on [Context Markets](https://github.com/contextwtf/contracts) contracts, used under license.
