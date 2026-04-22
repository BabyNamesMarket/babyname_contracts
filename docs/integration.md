# Integration Guide

## Deployment Artifact

Use `deployments/84532.json` for Base Sepolia addresses. The current artifact includes:

- `PredictionMarket`
- `PredictionMarketImpl`
- `Validation`
- `TestUSDC`
- `CollateralToken`
- `OutcomeTokenImpl`

## Common Operations

### Mint Test USDC on Testnet

```typescript
await testUsdc.write.mint([userAddress, 1_000_000_000n]); // 1000 USDC
```

### Create a National Market

```typescript
await usdc.write.approve([predictionMarketAddress, 200_000_000n]);

const marketId = await pm.write.createNameMarket([
  "olivia",
  2025,
  1,                // GIRL
  [],               // proof
  [100_000_000n, 100_000_000n],
]);
```

### Create a Regional Market

```typescript
const marketId = await pm.write.createRegionalNameMarket([
  "olivia",
  2025,
  1,                // GIRL
  "CA",
  [],
  [50_000_000n, 50_000_000n],
]);
```

### Quote an Exact-Input Buy

```typescript
const quote = await pm.read.quoteBuyExactIn([
  marketId,
  0,                // YES
  10_000_000n,      // 10 USDC gross
]);

// quote = [sharesBought, lmsrCost, fee, totalCharge]
```

### Trade

```typescript
await pm.write.trade([{
  marketId,
  deltaShares: [10_000_000n, 0n],
  maxCost: 15_000_000n,
  minPayout: 0n,
  deadline: BigInt(Math.floor(Date.now() / 1000) + 300),
}]);
```

### Resolve

```typescript
await pm.write.resolveMarketWithPayoutSplit([
  marketId,
  [1_000_000n, 0n],
]);
```

### Redeem

```typescript
const info = await pm.read.getMarketInfo([marketId]);
const yesToken = info.outcomeTokens[0];
const balance = await outcomeToken.read.balanceOf([userAddress]);

await pm.write.redeem([yesToken, balance]);
```

## Useful Reads

```typescript
const info = await pm.read.getMarketInfo([marketId]);
const prices = await pm.read.getPrices([marketId]);
const exists = await pm.read.marketExists([marketId]);

const validName = await pm.read.isValidName(["olivia", 1, []]);
const validRegion = await pm.read.isValidRegion(["CA"]);
```

Validation helpers:

```typescript
const boysRoot = await pm.read.namesMerkleRoot([0]);
const caAllowed = await pm.read.validRegions([keccak256(toBytes("CA"))]);
const defaultsSeeded = await pm.read.defaultRegionsSeeded();
```

## Key Types

| Value | Type | Notes |
|---|---|---|
| Market IDs | `bytes32` | returned by market creation |
| USDC amounts | `uint256` | 6 decimals |
| Share amounts | `uint256` | 6 decimals |
| Delta shares | `int256[]` | positive buy, negative sell |
| Prices | `uint256` | 6 decimals |
| Year | `uint16` | e.g. `2025` |

## Notes

- Names must be lowercased ASCII letters.
- Regions are `""` for national or uppercase 2-letter US state codes.
- The current repo does not expose a Launchpad contract.
