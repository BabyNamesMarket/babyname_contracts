# Architecture

## Contract Relationships

```
                ┌────────────────────┐
                │   PredictionMarket │
                │                    │
                │ createNameMarket() │
                │ trade()            │
                │ resolve()          │
                │ redeem()           │
                └───────┬─────┬──────┘
                        │     │
         validation()   │     │ cloneDeterministic()
                        ▼     ▼
              ┌──────────────────┐   ┌──────────────┐
              │ MarketValidation │   │ OutcomeToken │
              │                  │   │  YES / NO    │
              │ name roots       │   └──────────────┘
              │ approved names   │
              │ 50-state rules   │
              └──────────────────┘
```

`TestUSDC` is a testnet-only collateral token with real USDC metadata plus open minting.

## PredictionMarket

The core contract owns market state and the LMSR engine:

- creates direct binary YES/NO baby-name markets
- deploys deterministic `OutcomeToken` clones
- collects creation fees and trading fees
- enforces pausability and oracle-based resolution
- stores surplus balances for withdrawal

Markets are unique per `(name, gender, year, region)`.

## MarketValidation

Validation is intentionally split out of `PredictionMarket` to keep PM under the EIP-170 runtime limit while still enforcing:

- per-gender Merkle roots
- manual lowercased name approvals
- user name proposals
- built-in 50-state US abbreviation validation
- explicit region add/remove overrides

On Base Sepolia, `PredictionMarket` is deployed behind an `ERC1967Proxy`, initialized atomically, then bound once to a separately deployed `MarketValidation`.

## OutcomeToken

Each market gets two 6-decimal ERC20 outcome tokens:

- `YES`
- `NO`

Only `PredictionMarket` can mint and burn them.

## Roles

| Role | Can Do |
|---|---|
| Owner | Bind validation, open/close years, set roots, approve names, set defaults, set creation fee, authorize upgrades |
| `PROTOCOL_MANAGER_ROLE` | Set vig, trading fees, market fee overrides, global pause |
| Oracle | Resolve markets, pause/unpause its markets |

## USDC Flow

```
Creator creates market with [YES budget, NO budget]
  ├── 5% creation fee per side
  ├── fee seeds phantom shares
  ├── odd fee dust is collected and credited to surplus
  └── remaining net budgets buy YES/NO shares

Trader buys shares
  ├── trading fee → surplus[surplusRecipient]
  └── net amount → LMSR pool

Trader sells shares
  ├── LMSR pays gross proceeds
  ├── trading fee retained as surplus
  └── trader receives net proceeds

Resolution
  ├── winners redeem tokens for USDC
  └── leftover market pool → surplus[surplusRecipient]
```
