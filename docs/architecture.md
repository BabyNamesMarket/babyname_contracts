# Architecture

## Contract Relationships

```
                    ┌─────────────────┐
                    │    Launchpad    │
                    │                 │
                    │  propose()      │
                    │  commit()       │
                    │  launchMarket() │
                    │  claimShares()  │
                    └────────┬────────┘
                             │ createMarket()
                             │ tradeRaw()
                             ▼
                    ┌─────────────────┐         ┌──────────────┐
                    │ PredictionMarket│────────▸│ OutcomeToken │
                    │                 │  clone   │   (YES)      │
                    │  trade()        │  deploy  ├──────────────┤
                    │  redeem()       │────────▸│ OutcomeToken │
                    │  resolve()      │          │   (NO)       │
                    └─────────────────┘         └──────────────┘
                             │
                    USDC flows in/out
```

## Launchpad

Handles the pre-market commitment phase:

- **Name validation** via per-gender Merkle roots of SSA names
- **Gender/year/region scoping** — each `(name, gender, year, region)` is a unique market
- **Commitment accumulation** — users commit USDC to YES/NO outcomes
- **5% fee separation** at commit time — fees fund phantom shares at launch
- **Scheduled launch times** — year-wide launch dates or per-proposal fallback times
- **Lazy share distribution** — `launchMarket()` is O(1), users claim individually
- **Proposal-local budgeting** — one proposal cannot spend another proposal’s funds

After a market launches, the Launchpad's job is done. Users interact with PredictionMarket directly for trading.

## PredictionMarket

The core LMSR automated market maker:

- **Market creation** with deterministic OutcomeToken clones
- **Trading** with 3% fee (skimmed before LMSR math)
- **Fee-exempt `tradeRaw()`** for Launchpad's bootstrap trade
- **Resolution** by oracle with arbitrary payout splits
- **Redemption** — burn tokens for USDC proportional to payout
- **Surplus** — vig + trading fees accumulate for the surplus recipient

## OutcomeToken

Minimal ERC20 (6 decimals, matching USDC) deployed as deterministic clones via `LibClone`. Each market gets one token per outcome (typically YES and NO). Only PredictionMarket can mint/burn.

## Role Model

| Role | Who | Can Do |
|------|-----|--------|
| Owner (msg.sender at deploy) | Deployer / deploying contract | Initialize, grant roles |
| PROTOCOL_MANAGER_ROLE | the protocol multisig | Set fees, vig, max outcomes, bailout |
| MARKET_CREATOR_ROLE | Launchpad contract | Create markets, fee-exempt trades |
| Oracle (per-market) | Deployer (testnet) | Resolve markets, pause/unpause |
| Launchpad Owner | Deployer | Open/close years, set launch dates, set roots, approve names, set parameters |

## USDC Flow

```
User commits $20 to Launchpad
  ├── $1 fee (5%) held by Launchpad
  └── $19 net tracked for share distribution

Launch:
  ├── $1 fee → PredictionMarket (creation fee → phantom shares)
  └── $19 net → PredictionMarket (aggregate trade → outcome tokens)

Post-launch trade of $10:
  ├── $0.30 fee (3%) → surplus[treasury]
  └── $9.70 → LMSR cost function

Resolution (YES wins):
  ├── Token holders redeem YES tokens for $1 each
  └── Remaining USDC → surplus[treasury] (vig)
```
