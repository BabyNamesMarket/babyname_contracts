# Deployment

## Environment Setup

```bash
cp .env.example .env
# Edit .env with PRIVATE_KEY and ETHERSCAN_API_KEY
```

## Base Sepolia

```bash
export COLLATERAL_TOKEN_ADDRESS="$TOKEN_ADDRESS"
forge script script/DeployTestnet.s.sol:DeployTestnet --rpc-url "$BASE_SEPOLIA_RPC_URL" --broadcast
```

Deploys PredictionMarket, Launchpad, RewardDistributor, and uses the configured collateral token. If `COLLATERAL_TOKEN_ADDRESS` is unset, the script deploys a fresh `TestUSDC`.

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
| RewardDistributor | `0x5B740001E88B2df9e96e84B75f7150496fA19Fe0` |
