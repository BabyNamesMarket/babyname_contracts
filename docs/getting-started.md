# Getting Started

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git

## Clone and Build

```bash
git clone --recurse-submodules https://github.com/BabyNamesMarket/babyname_contracts
cd babynames_contracts
forge build
```

## Run Tests

```bash
forge test -vv          # 96 tests across 4 suites
forge test -vvvv        # Verbose with traces
```

## Test Structure

```
test/
  PredictionMarket.t.sol      # 39 tests - creation, trading, fees, resolution, solvency
  PredictionMarketFuzz.t.sol  #  8 tests - solvency fuzz (512 runs), round-trip bounds
  Launchpad.t.sol             # 33 tests - propose, commit, launch, claims, scoping
  LaunchpadEdge.t.sol         # 16 tests - fee cap, tiny commits, timing edge cases
```

## npm Package

For frontend integration:

```bash
npm install github:BabyNamesMarket/babyname_contracts
```

```javascript
const {
  PredictionMarketABI,
  LaunchpadABI,
  OutcomeTokenABI,
  getDeployment,
  CHAIN_IDS,
} = require("@babynamesmarket/contracts");

const deploy = getDeployment(CHAIN_IDS.baseSepolia);
```

See the [Integration Guide](integration.md) for detailed frontend usage.
