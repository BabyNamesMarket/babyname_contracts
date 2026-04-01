# Integration Guide

## Install

```bash
npm install github:BabyNamesMarket/babyname_contracts
```

## Imports

```typescript
import {
  PredictionMarketABI,
  LaunchpadABI,
  OutcomeTokenABI,
  RewardDistributorABI,
  getDeployment,
  CHAIN_IDS,
} from "@babynamesmarket/contracts";

// Available chain IDs
// CHAIN_IDS.baseSepolia = 84532
// CHAIN_IDS.base = 8453
// CHAIN_IDS.tempo = 4217
// CHAIN_IDS.tempoTestnet = 42431

const deploy = getDeployment(CHAIN_IDS.baseSepolia);
// deploy.PredictionMarket - address
// deploy.Launchpad - address
// deploy.TestUSDC - address (testnet only)
// deploy.CollateralToken - address
// deploy.RewardDistributor - address
// deploy.OutcomeTokenImpl - address
```

## Common Operations

### Propose a Name

```typescript
// 1. Approve Launchpad to spend USDC
await usdc.write.approve([launchpadAddress, amount]);

// 2. Propose (creates proposal + commits in one tx)
const proposalId = await launchpad.write.propose([
  "olivia",           // name
  2025,               // year (uint16)
  1,                  // gender (0 = BOY, 1 = GIRL)
  [],                 // merkle proof (empty if no whitelist)
  [5000000n, 0n],     // amounts: [$5 YES, $0 NO]
]);
```

### Commit to Existing Proposal

```typescript
await launchpad.write.commit([
  proposalId,         // bytes32
  [10000000n, 0n],    // amounts: [$10 YES, $0 NO]
]);
```

### Launch a Market

```typescript
// Anyone can call once eligible
await launchpad.write.launchMarket([proposalId]);
```

### Claim Shares After Launch

```typescript
await launchpad.write.claimShares([proposalId]);
// Tokens sent directly to your wallet

// Claim any USDC refund from unspent budget
const refund = await launchpad.read.pendingRefunds([userAddress]);
if (refund > 0n) {
  await launchpad.write.claimRefund();
}
```

### Trade on a Live Market

```typescript
// Get market info for quoting
const info = await pm.read.getMarketInfo([marketId]);
const prices = await pm.read.getPrices([marketId]);

// Quote a trade (returns raw LMSR cost, no fee)
const lmsrCost = await pm.read.quoteTrade([
  info.outcomeQs,
  info.alpha,
  [10000000n, 0n],    // buy 10 YES shares (int256[])
]);

// Actual cost with 3% fee
const fee = (lmsrCost * 300n) / (10000n - 300n);
const grossCost = lmsrCost + fee;

// Execute trade
await pm.write.trade([{
  marketId,
  deltaShares: [10000000n, 0n],
  maxCost: grossCost + 1000n,   // small buffer for rounding
  minPayout: 0n,
  deadline: BigInt(Math.floor(Date.now() / 1000) + 300),
}]);
```

### Redeem After Resolution

```typescript
// Check if market is resolved
const info = await pm.read.getMarketInfo([marketId]);
if (info.resolved) {
  const yesToken = info.outcomeTokens[0];
  const balance = await outcomeToken.read.balanceOf([userAddress]);

  // Redeem: burns tokens, pays USDC
  await pm.write.redeem([yesToken, balance]);
}
```

## Reading State

### Proposal Info

```typescript
const proposal = await launchpad.read.getProposal([proposalId]);
// proposal.state: 0=OPEN, 1=LAUNCHED
// proposal.gender: 0=BOY, 1=GIRL
// proposal.launchTs: no more commits after this time
// proposal.totalCommitted: gross USDC committed
// proposal.totalFeesCollected: fees separated from commitments
// proposal.totalPerOutcome: net USDC per outcome
// proposal.name, proposal.year, proposal.region
// proposal.marketId: set after launch
```

### Enumerating Proposals

There's no `proposalCount()`. Enumerate via event logs:

```typescript
const events = await publicClient.getLogs({
  address: launchpadAddress,
  event: parseAbiItem(
    'event ProposalCreated(bytes32 indexed proposalId, bytes32 indexed questionId, string name, uint8 gender, uint16 year, string region, address proposer, uint256 launchTs)'
  ),
  fromBlock: deploymentBlock,
});
```

### Name and Market Keys

```typescript
const marketKey = await launchpad.read.getMarketKey([
  "olivia",
  1,        // GIRL
  2025,
  "",
]);

const proposalId = await launchpad.read.getProposalByMarketKey([
  "olivia",
  1,        // GIRL
  2025,
  "",
]);
```

### Market Prices

```typescript
const prices = await pm.read.getPrices([marketId]);
// prices[0] = YES price in 1e6 units (e.g. 535000 = $0.535)
// prices[1] = NO price
// Sum is slightly > 1e6 due to vig
```

## Key Types

| Value | Type | Notes |
|-------|------|-------|
| Proposal IDs | `bytes32` | NOT uint256 |
| Market IDs | `bytes32` | NOT uint256 |
| USDC amounts | `uint256` | 6 decimals (1e6 = $1) |
| Share amounts | `uint256` | 6 decimals (1e6 = 1 share) |
| Delta shares | `int256[]` | Positive = buy, negative = sell |
| Prices | `uint256` | 6 decimals (1e6 = $1.00) |
| Year | `uint16` | e.g. 2025 |
| Fee bps | `uint256` | 300 = 3%, 500 = 5% |

## Testnet USDC

On testnets, `TestUSDC` has an open mint:

```typescript
await testUsdc.write.mint([userAddress, 1000000000n]); // mint $1000
```
