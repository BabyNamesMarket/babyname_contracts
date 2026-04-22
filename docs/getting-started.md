# Getting Started

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git

## Clone and Build

```bash
git clone --recurse-submodules https://github.com/BabyNamesMarket/contracts
cd babynames_contracts
forge build
```

## Run Tests

```bash
forge test -vv
forge test -vvvv
```

Current suite totals in this repo:

- `PredictionMarket.t.sol`: 46 tests
- `PredictionMarketFuzz.t.sol`: 7 tests
- `Launchpad.t.sol`: 28 tests
- `LaunchpadEdge.t.sol`: 9 tests

Note: the `Launchpad*.t.sol` files now exercise direct name-market flows on `PredictionMarket`; there is no active `src/Launchpad.sol` in this repository.

## Test Structure

```
test/
  PredictionMarket.t.sol      # creation, trading, fees, resolution, upgrades
  PredictionMarketFuzz.t.sol  # solvency and round-trip fuzzing
  Launchpad.t.sol             # direct name-market flows and validation
  LaunchpadEdge.t.sol         # edge cases for tiny markets and region rules
```

## Base Sepolia

```bash
make deploy-base-sepolia
```

This deploys:

- `PredictionMarket` implementation
- `ERC1967Proxy` with atomic initialization
- `MarketValidation`
- `TestUSDC` by default on testnet

and runs automatic Basescan verification.
