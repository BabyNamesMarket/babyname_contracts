# BabyNames Prediction Markets

Prediction markets for SSA baby name rankings, powered by an LMSR automated market maker.

## How It Works

Users bet on whether a baby name will appear in the Social Security Administration's annual top name rankings. Markets are created directly on `PredictionMarket` for `(name, gender, year, region)` tuples and trade as binary YES/NO LMSR markets.

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
| MarketValidation | External validation rules for names and regions |
| [OutcomeToken](api/outcome-token.md) | ERC20 outcome tokens (YES/NO) |

## Deployed Addresses

### Base Sepolia (84532)

| Contract | Address |
|----------|---------|
| PredictionMarket | [`0x99B9...9Dd6`](https://sepolia.basescan.org/address/0x99B9922A59C69c30fC3008b715B59Dd0FF029Dd6) |
| PredictionMarket Impl | [`0x6e6C...e137`](https://sepolia.basescan.org/address/0x6e6CB2A4a133E2eD4aE31b129032BA220fe1e137) |
| MarketValidation | [`0xeb5c...3EF6`](https://sepolia.basescan.org/address/0xeb5cDedEcF102c86E8cbf5e0Da9589262F3a3EF6) |
| TestUSDC | [`0x1440...6854`](https://sepolia.basescan.org/address/0x1440ee2e2Fa5Fc93290AF034899cC10423316854) |

Based on [Context Markets](https://github.com/contextwtf/contracts) contracts, used under license.
