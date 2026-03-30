# Deployment

## Environment Setup

```bash
cp .env.example .env
# Edit .env with PRIVATE_KEY and ETHERSCAN_API_KEY
```

## Base Sepolia

```bash
make deploy-base-sepolia
```

Deploys TestUSDC, PredictionMarket, Launchpad, RewardDistributor. Auto-verified on Basescan.

## Tempo Testnet

```bash
foundryup --repo tempoxyz/tempo-foundry
make deploy-tempo-testnet
```

## Current Deployments

### Base Sepolia (84532)

| Contract | Address |
|----------|---------|
| PredictionMarket | `0x168a1808b563224b0AA69FA3bb7214940ac7E366` |
| Launchpad | `0x3c1fc7971b0e965eC76cce38108AE2d7c1A6974f` |
| TestUSDC | `0x4e9F02904c36F7CeB044eB53112Eaf3276fD49bc` |
| RewardDistributor | `0x8d87a9Df10aB58D6cD886283f5884D2243AA1ab1` |
