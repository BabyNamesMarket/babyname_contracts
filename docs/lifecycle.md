# Market Lifecycle

## Phase 1: Proposal

Anyone can propose a market for a valid `(name, gender, year, region)` tuple. The proposer commits capital in the same transaction.

```solidity
// Propose "olivia" for 2025 girls national ranking, commit $20 to YES
launchpad.propose("olivia", 2025, Launchpad.Gender.GIRL, merkleProof, [20e6, 0]);
```

Requirements:
- Name must be valid for that gender (Merkle proof or manually approved)
- Year must be open (`yearOpen[2025] == true`)
- Region must be valid (empty string for national, or a US state abbreviation like "CA")
- No active proposal for the same `(name, gender, year, region)` combination
- At least one non-zero commitment amount

The 5% commitment fee is separated immediately:
- $20 gross → $1 fee + $19 net
- Net amounts are tracked per-outcome for share distribution
- Gross totals are tracked for proposal budgeting

## Phase 2: Commitment

Other users add capital to the proposal:

```solidity
launchpad.commit(proposalId, [10e6, 0]);  // $10 more on YES
launchpad.commit(proposalId, [0, 5e6]);   // $5 on NO
```

Users can commit multiple times. Amounts accumulate. Each commitment has its 5% fee separated.

## Phase 3: Launch

Anyone can trigger the launch once `block.timestamp >= launchTs`:

```solidity
launchpad.launchMarket(proposalId);
```

### How `launchTs` Is Determined

- If `yearLaunchDate[year]` is in the future when the proposal is created, the proposal is tied to that shared year launch date.
- Otherwise the proposal gets an individual launch time of `createdAt + postBatchTimeout` (default 24 hours).
- Updating `yearLaunchDate(year, newDate)` changes the effective launch time for commit-stage proposals that are still tied to the shared year schedule.

Commitments are accepted only before `launchTs`. There is no withdrawal or cancellation path.

### What Happens at Launch

1. **Fee split**: `min(totalFeesCollected, maxCreationFee)` funds symmetric phantom shares, excess goes to the protocol
2. **Market creation**: PredictionMarket deploys OutcomeToken clones, sets up LMSR state
3. **Proposal-local budgeting**: the Launchpad derives this proposal’s `tradingBudget` from its own committed funds only
4. **Binary search**: Finds the maximum affordable aggregate trade within that proposal-local budget
5. **Aggregate trade**: Buys shares proportional to commitment ratios at the initial 50/50 price (fee-exempt via `tradeRaw`)
5. **Store results**: Share totals and cost recorded for lazy distribution

The launch transaction is O(1) in committer count — no loop over users.

## Phase 4: Claim Shares

Each user calls `claimShares` to receive their outcome tokens:

```solidity
launchpad.claimShares(proposalId);
// Outcome tokens sent directly to wallet
// Any unspent USDC credited to pendingRefunds

launchpad.claimRefund();  // withdraw pending refunds
```

Shares are distributed proportional to each user's net committed amount per outcome. All users get the same effective price (same-price guarantee).

After claiming, users hold standard ERC20 outcome tokens and can trade freely.

## Phase 5: Trading

The market is live on PredictionMarket. Anyone can trade:

```solidity
// Buy 10 YES shares (maxCost includes 3% fee)
predictionMarket.trade(Trade({
    marketId: marketId,
    deltaShares: [int256(10e6), int256(0)],
    maxCost: 15e6,     // willing to pay up to $15 gross
    minPayout: 0,
    deadline: block.timestamp + 300
}));

// Sell 5 YES shares
predictionMarket.trade(Trade({
    marketId: marketId,
    deltaShares: [int256(-5e6), int256(0)],
    maxCost: 0,
    minPayout: 1e6,    // want at least $1 net after fee
    deadline: block.timestamp + 300
}));
```

The 3% trading fee is skimmed before the LMSR calculation:
- **Buys**: User pays gross, fee deducted, net covers LMSR cost
- **Sells**: LMSR pays out, fee deducted, net goes to user

## Phase 6: Resolution

The oracle resolves the market when SSA data is published:

```solidity
// YES wins 100%
predictionMarket.resolveMarketWithPayoutSplit(marketId, [1e6, 0]);

// Or a 60/40 split
predictionMarket.resolveMarketWithPayoutSplit(marketId, [600000, 400000]);
```

Payout percentages must sum to exactly `1e6` (100%). The oracle can also pause/unpause markets while waiting for data.

At resolution:
- Outstanding shares (above phantom shares) determine total payout
- Remaining USDC in the market becomes surplus (vig revenue for the protocol)

## Phase 7: Redemption

Token holders redeem for USDC:

```solidity
predictionMarket.redeem(yesTokenAddress, amount);
// Burns tokens, pays amount * payoutPct / 1e6 in USDC
```

If YES won 100%: each YES token redeems for $1.00, each NO token for $0.00.

## Proposal Notes

- `withdrawCommitment(proposalId)` and `cancelProposal(proposalId)` are legacy selectors and now always revert with `CommitmentsFinal()`.
- Namespaces are gender-specific throughout the proposal flow and Merkle validation.
