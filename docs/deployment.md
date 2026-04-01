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

Deploys PredictionMarket and Launchpad, uses the configured collateral token, then syncs Goldsky in `../babynames_market/goldsky/` by:

- copying fresh `PredictionMarket` and `Launchpad` ABIs
- updating `goldsky.config.json` addresses
- deriving `startBlock` from the actual deployment tx block

If `COLLATERAL_TOKEN_ADDRESS` is unset, the script deploys a fresh `TestUSDC`.

Set `GOLDSKY_AUTO_DEPLOY=true` if you also want the sync script to run the `goldsky subgraph delete` and `goldsky subgraph deploy` commands after updating the config.

## Tempo Testnet

```bash
foundryup --repo tempoxyz/tempo-foundry
make deploy-tempo-testnet
```

## Current Deployments

### Base Sepolia (84532)

| Contract | Address |
|----------|---------|
| PredictionMarket | `0x7000667CF33833F97120a13b4D12A795142f6F6c` |
| Launchpad | `0x08EDA78b3434A7774Cb4a012B2D7c8231F09882b` |
| TestUSDC / CollateralToken | `0x43fAbD625f96b93edAC2F370a2fe246b2E09A575` |
