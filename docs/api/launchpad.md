# Launchpad API Reference

`src/Launchpad.sol`

Commitment-based market bootstrapping for baby-name prediction markets. Proposals are scoped by `(name, gender, year, region)`. Commitments are final, proposals launch on a scheduled timestamp, and launch converts pooled commitments into a live `PredictionMarket`.

## Core Model

- Names are validated per gender by Merkle root or manual approval.
- Years must be opened by the owner before proposals can be created.
- Each proposal accepts commitments until its `launchTs`.
- At or after `launchTs`, anyone can call `launchMarket`.
- There is no proposal withdrawal or cancellation flow. The legacy selectors still exist and revert with `CommitmentsFinal()`.
- After launch, users claim outcome tokens and any refund from unspent budget with `claimShares`, then withdraw USDC refunds via `claimRefund`.

## Enums

### `Gender`

| Value | Meaning |
|---|---|
| `0` | `BOY` |
| `1` | `GIRL` |

### `ProposalState`

| Value | Meaning |
|---|---|
| `0` | `OPEN` |
| `1` | `LAUNCHED` |
| `2` | `EXPIRED` |
| `3` | `CANCELLED` |

`EXPIRED` and `CANCELLED` remain in the enum for compatibility, but the current public lifecycle only uses `OPEN` and `LAUNCHED`.

## Structs

### `PermitArgs`

| Field | Type |
|---|---|
| `value` | `uint256` |
| `deadline` | `uint256` |
| `v` | `uint8` |
| `r` | `bytes32` |
| `s` | `bytes32` |

### `ProposalInfo`

Returned by `getProposal(bytes32)`.

| Field | Type | Notes |
|---|---|---|
| `questionId` | `bytes32` | Unique market question ID passed into `PredictionMarket` |
| `oracle` | `address` | Resolver for the launched market |
| `metadata` | `bytes` | Encoded proposal metadata |
| `outcomeNames` | `string[]` | Usually `["YES", "NO"]` |
| `gender` | `Gender` | Proposal gender namespace |
| `launchTs` | `uint256` | Effective launch timestamp |
| `createdAt` | `uint256` | Proposal creation timestamp |
| `state` | `ProposalState` | Current state |
| `marketId` | `bytes32` | Set after launch |
| `totalPerOutcome` | `uint256[]` | Net commitments per outcome after fee |
| `totalCommitted` | `uint256` | Gross committed USDC |
| `totalFeesCollected` | `uint256` | Fee pool separated at commit time |
| `committers` | `address[]` | Unique committers |
| `name` | `string` | Lowercased name |
| `year` | `uint16` | Market year |
| `region` | `string` | `""` for national or uppercase region code |
| `actualCost` | `uint256` | Actual aggregate trade cost |
| `tradingBudget` | `uint256` | Proposal-local trading budget |
| `totalSharesPerOutcome` | `uint256[]` | Shares acquired in aggregate launch trade |

## Important State

| Variable | Type | Notes |
|---|---|---|
| `namesMerkleRoot` | `mapping(uint8 => bytes32)` | Separate Merkle root per gender |
| `approvedNames` | `mapping(bytes32 => bool)` | Manual approvals keyed by `(lowercasedName, gender)` |
| `proposedNames` | `mapping(bytes32 => bool)` | User-submitted names awaiting approval |
| `yearOpen` | `mapping(uint16 => bool)` | Whether proposals for a year are allowed |
| `yearLaunchDate` | `mapping(uint16 => uint256)` | Shared launch date for a year |
| `validRegions` | `mapping(bytes32 => bool)` | Region whitelist |
| `commitmentFeeBps` | `uint256` | Default `500` = 5% |
| `maxCreationFee` | `uint256` | Max gross fee budget used for market creation |
| `postBatchTimeout` | `uint256` | Per-proposal fallback launch delay |
| `pendingRefunds` | `mapping(address => uint256)` | Claimable USDC refunds from unspent launch budget |

## Main Functions

### `propose`

```solidity
function propose(
    string calldata name,
    uint16 year,
    Gender gender,
    bytes32[] calldata proof,
    uint256[] calldata amounts
) external returns (bytes32)
```

Creates a national proposal and commits in one transaction.

### `proposeWithPermit`

```solidity
function proposeWithPermit(
    string calldata name,
    uint16 year,
    Gender gender,
    bytes32[] calldata proof,
    uint256[] calldata amounts,
    PermitArgs calldata permitData
) external returns (bytes32)
```

Same as `propose`, but uses EIP-2612 permit first.

### `proposeRegional`

```solidity
function proposeRegional(
    string calldata name,
    uint16 year,
    Gender gender,
    string calldata region,
    bytes32[] calldata proof,
    uint256[] calldata amounts
) external returns (bytes32)
```

Creates a regional proposal.

### `adminPropose`

```solidity
function adminPropose(
    string[] calldata outcomeNames,
    address oracle,
    bytes calldata metadata,
    Gender gender,
    uint16 year,
    string calldata region,
    uint256 launchTs
) external returns (bytes32)
```

Owner-only proposal creation path for custom markets.

### `commit`

```solidity
function commit(bytes32 proposalId, uint256[] calldata amounts) external
```

Adds more gross USDC commitments to an existing `OPEN` proposal before `launchTs`.

### `commitWithPermit`

```solidity
function commitWithPermit(
    bytes32 proposalId,
    uint256[] calldata amounts,
    PermitArgs calldata permitData
) external
```

Same as `commit`, but uses permit first.

### `launchMarket`

```solidity
function launchMarket(bytes32 proposalId) external
```

Callable by anyone at or after `launchTs`. Requires at least `$1` gross committed. Uses proposal-local accounting:

- fee pool funds market creation up to `maxCreationFee`
- excess fee goes to `surplusRecipient`
- remaining proposal funds become `tradingBudget`
- Launchpad executes an aggregate `tradeRaw` into the newly-created market

### `claimShares`

```solidity
function claimShares(bytes32 proposalId) external
```

Claims a user’s outcome tokens and assigns their share of any unspent launch budget into `pendingRefunds`.

### `claimRefund`

```solidity
function claimRefund() external
```

Withdraws accumulated USDC refunds.

## Name Admin

### `setNamesMerkleRoot`

```solidity
function setNamesMerkleRoot(Gender gender, bytes32 root) external
```

Sets the whitelist root for one gender.

### `approveName`

```solidity
function approveName(string calldata name, Gender gender) external
```

Manually approves a lowercased `(name, gender)` pair.

### `proposeName`

```solidity
function proposeName(string calldata name, Gender gender) external
```

Lets users submit candidate names for manual review/approval.

### `isValidName`

```solidity
function isValidName(string memory name, Gender gender, bytes32[] calldata proof) public view returns (bool)
```

Returns true if:

- whitelist for that gender is disabled, or
- the `(lowercasedName, gender)` pair is manually approved, or
- the supplied proof matches that gender’s Merkle root

## Year / Region Admin

### `openYear` / `closeYear`

```solidity
function openYear(uint16 year) external
function closeYear(uint16 year) external
```

Controls whether new proposals may be created for a year.

### `setYearLaunchDate`

```solidity
function setYearLaunchDate(uint16 year, uint256 date) external
```

Sets the shared launch date for commit-stage proposals tied to that year schedule.

### `seedDefaultRegions`, `addRegion`, `removeRegion`, `isValidRegion`

Region-management helpers. National markets use `""`; state codes are uppercased.

## View Helpers

### `getProposal`

```solidity
function getProposal(bytes32 proposalId) external view returns (ProposalInfo memory)
```

### `getCommitted`

```solidity
function getCommitted(bytes32 proposalId, address user) external view returns (uint256[] memory)
```

Returns the user’s net per-outcome commitment.

### `hasClaimed`

```solidity
function hasClaimed(bytes32 proposalId, address user) external view returns (bool)
```

### `getMarketKey`

```solidity
function getMarketKey(string calldata name, Gender gender, uint16 year, string calldata region)
    external
    pure
    returns (bytes32)
```

### `getProposalByMarketKey`

```solidity
function getProposalByMarketKey(string calldata name, Gender gender, uint16 year, string calldata region)
    external
    view
    returns (bytes32)
```

## Legacy Functions

### `withdrawCommitment`

```solidity
function withdrawCommitment(bytes32 proposalId) external
```

Always reverts with `CommitmentsFinal()`.

### `cancelProposal`

```solidity
function cancelProposal(bytes32 proposalId) external
```

Always reverts with `CommitmentsFinal()`.

## Key Events

- `ProposalCreated(bytes32 proposalId, bytes32 questionId, string name, Gender gender, uint16 year, string region, address proposer, uint256 launchTs)`
- `Committed(bytes32 proposalId, address user, uint256[] amounts, uint256 total)`
- `MarketLaunched(bytes32 proposalId, bytes32 marketId, uint256 actualCost, uint256 feesUsedForCreation, uint256 excessFees, uint256 committerCount)`
- `SharesClaimed(bytes32 proposalId, address user, uint256[] shares, uint256 refund)`
- `RefundClaimed(address user, uint256 amount)`
- `NamesMerkleRootUpdated(Gender gender, bytes32 oldRoot, bytes32 newRoot)`
- `NameApproved(string name, Gender gender)`
- `NameProposed(string name, Gender gender, address proposer)`
- `YearLaunchDateUpdated(uint16 year, uint256 oldDate, uint256 newDate)`

## Common Reverts

- `InvalidName()`
- `YearNotOpen()`
- `InvalidRegion()`
- `DuplicateMarketKey()`
- `DuplicateQuestionId()`
- `DeadlinePassed()`
- `NotEligibleForLaunch()`
- `BelowThreshold()`
- `CommitmentsFinal()`
- `NothingToClaim()`
