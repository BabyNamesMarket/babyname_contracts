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

Deploys a fresh `PredictionMarket` stack to Base Sepolia, verifies the deployed contracts on Basescan during the deployment run, and then updates the local `deployments/84532.json` artifact with Goldsky metadata by:

- deriving `startBlock` from the actual deployment tx block
- storing the Goldsky endpoint, subgraph name, and instance config alongside the deployed addresses

The Base Sepolia flow now deploys:

- an implementation contract
- an `ERC1967Proxy` initialized atomically in the proxy constructor
- a separate `MarketValidation` contract bound once via `setValidation`

This avoids the old uninitialized-proxy ownership race while keeping `PredictionMarket` under the EIP-170 size limit.

By default the script deploys a fresh mintable `TestUSDC` that matches real USDC metadata and decimals:

- name: `USD Coin`
- symbol: `USDC`
- decimals: `6`
- extra testnet-only function: `mint(address,uint256)`

Optional environment flags:

- `COLLATERAL_TOKEN_ADDRESS` to override the collateral token for a one-off deploy
- `SEED_SAMPLE_MARKETS=true` to create the sample `liam` and `olivia` markets after deployment

## Tempo Testnet

```bash
foundryup --repo tempoxyz/tempo-foundry
make deploy-tempo-testnet
```

## Current Deployments

### Base Sepolia (84532)

The canonical deployment record lives in `deployments/84532.json` and is overwritten on each fresh Base Sepolia deployment.

Current addresses:

- `PredictionMarket`: `0x99B9922A59C69c30fC3008b715B59Dd0FF029Dd6`
- `PredictionMarketImpl`: `0x6e6CB2A4a133E2eD4aE31b129032BA220fe1e137`
- `MarketValidation`: `0xeb5cDedEcF102c86E8cbf5e0Da9589262F3a3EF6`
- `TestUSDC`: `0x1440ee2e2Fa5Fc93290AF034899cC10423316854`
- `OutcomeTokenImpl`: `0xD347bb9b279F06A04c7c4611d76cF91648D70A58`
- `startBlock`: `40515229`
