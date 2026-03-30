# Launchpad API Reference

`src/Launchpad.sol`

Commitment-based market bootstrapping for baby name prediction markets. Markets are scoped to (name, year, region). Anyone can propose a market for a valid name and commit USDC capital toward it. A commitment fee (default 5%) is collected from all commitments. When launch eligibility is met, the Launchpad creates a PredictionMarket, executes an aggregate LMSR trade with the pooled funds, and distributes outcome tokens to committers proportionally via `claimShares()`. If a proposal expires without launching, committers receive a full gross refund.

---

## Structs

### `PermitArgs`

| Field | Type | Description |
|---|---|---|
| `value` | `uint256` | Permit approval amount |
| `deadline` | `uint256` | Permit deadline |
| `v` | `uint8` | ECDSA v |
| `r` | `bytes32` | ECDSA r |
| `s` | `bytes32` | ECDSA s |

### `ProposalState` (enum)

| Value | Description |
|---|---|
| `OPEN` | Accepting commitments, not yet launched |
| `LAUNCHED` | Market created, shares claimable |
| `EXPIRED` | Deadline passed without launch |
| `CANCELLED` | Cancelled by admin |

### `ProposalInfo`

Returned by `getProposal()`. Contains all readable proposal fields.

| Field | Type | Description |
|---|---|---|
| `questionId` | `bytes32` | Question ID passed to PredictionMarket |
| `oracle` | `address` | Oracle that will resolve the market |
| `metadata` | `bytes` | Encoded metadata (`abi.encode(name, year, region)`) |
| `outcomeNames` | `string[]` | Outcome labels (e.g., `["YES", "NO"]`) |
| `deadline` | `uint256` | Proposal expiry timestamp |
| `createdAt` | `uint256` | Proposal creation timestamp |
| `state` | `ProposalState` | Current proposal state |
| `marketId` | `bytes32` | PredictionMarket market ID (set after launch) |
| `totalPerOutcome` | `uint256[]` | Net USDC committed per outcome (after fee) |
| `totalCommitted` | `uint256` | Gross USDC committed across all outcomes |
| `totalFeesCollected` | `uint256` | Total commitment fees collected |
| `committers` | `address[]` | List of unique committer addresses |
| `name` | `string` | Lowercased baby name |
| `year` | `uint16` | SSA data year |
| `region` | `string` | Uppercased region code ("" for national) |
| `actualCost` | `uint256` | USDC spent on the aggregate LMSR trade |
| `tradingBudget` | `uint256` | USDC available for trading after market creation |
| `totalSharesPerOutcome` | `uint256[]` | Total outcome tokens purchased per outcome |

---

## Constants

| Name | Value | Description |
|---|---|---|
| `MAX_COMMITMENT_FEE_BPS` | `1000` | Maximum commitment fee (10%) |

---

## State Variables

| Name | Type | Description |
|---|---|---|
| `predictionMarket` | `PredictionMarket` | PredictionMarket contract reference |
| `usdc` | `IERC20` | USDC token contract |
| `namesMerkleRoot` | `bytes32` | Merkle root of valid SSA names. `0` disables the whitelist |
| `approvedNames` | `mapping(bytes32 => bool)` | Manually approved names (`keccak256(lowercased)` => true) |
| `yearOpen` | `mapping(uint16 => bool)` | Whether a year is open for proposals |
| `validRegions` | `mapping(bytes32 => bool)` | Valid region codes (`keccak256(uppercased)` => true) |
| `defaultRegionsSeeded` | `bool` | Whether the 50 US state regions have been seeded |
| `defaultOracle` | `address` | Default oracle for new proposals |
| `defaultDeadlineDuration` | `uint256` | Default proposal duration in seconds |
| `surplusRecipient` | `address` | Recipient of excess fees and trading surplus |
| `commitmentFeeBps` | `uint256` | Commitment fee in basis points (default 500 = 5%) |
| `maxCreationFee` | `uint256` | Maximum USDC used for market creation phantom shares (default 10 USDC) |
| `batchLaunchDate` | `uint256` | Batch launch date. Pre-batch proposals launch on this date. 0 = disabled |
| `postBatchMinThreshold` | `uint256` | Net commitment threshold for immediate post-batch launch (default 10 USDC) |
| `postBatchTimeout` | `uint256` | Time after creation when post-batch proposals auto-qualify (default 24 hours) |
| `marketKeyToProposal` | `mapping(bytes32 => bytes32)` | Maps `hash(name, year, region)` to proposal ID |
| `pendingRefunds` | `mapping(address => uint256)` | Pending USDC refunds from unspent trading funds |

---

## Functions

### `propose`

```solidity
function propose(string calldata name, uint16 year, bytes32[] calldata proof, uint256[] calldata amounts) external returns (bytes32)
```

Proposes a new market for a baby name in the national region and commits capital. The name must pass validation (Merkle proof or manual approval). The year must be open. Creates a 2-outcome (YES/NO) proposal.

**Access:** Anyone

**Parameters:**
- `name` -- Baby name to create a market for
- `year` -- SSA data year (e.g., 2025, 2026)
- `proof` -- Merkle proof that the name is valid (empty if whitelist is disabled)
- `amounts` -- USDC commitment per outcome `[YES_amount, NO_amount]` (gross, fee deducted internally)

**Returns:** The `bytes32` proposal ID.

---

### `proposeWithPermit`

```solidity
function proposeWithPermit(string calldata name, uint16 year, bytes32[] calldata proof, uint256[] calldata amounts, PermitArgs calldata permitData) external returns (bytes32)
```

Same as `propose` but first calls EIP-2612 `permit` on USDC for gasless approval.

**Access:** Anyone

**Parameters:**
- `name` -- Baby name
- `year` -- SSA data year
- `proof` -- Merkle proof
- `amounts` -- USDC commitment per outcome
- `permitData` -- EIP-2612 permit arguments

**Returns:** The `bytes32` proposal ID.

---

### `proposeRegional`

```solidity
function proposeRegional(string calldata name, uint16 year, string calldata region, bytes32[] calldata proof, uint256[] calldata amounts) external returns (bytes32)
```

Proposes a market for a name in a specific region (e.g., "CA" for California). Same as `propose` but with an explicit region parameter.

**Access:** Anyone

**Parameters:**
- `name` -- Baby name
- `year` -- SSA data year
- `region` -- State abbreviation (e.g., "CA") or "" for national
- `proof` -- Merkle proof
- `amounts` -- USDC commitment per outcome

**Returns:** The `bytes32` proposal ID.

---

### `adminPropose`

```solidity
function adminPropose(string[] calldata outcomeNames, address oracle, bytes calldata metadata, uint16 year, string calldata region, uint256 deadline) external returns (bytes32)
```

Admin creates a proposal with custom parameters, bypassing name/year/region validation. Supports arbitrary outcome names and a custom oracle. Does not include an initial commitment.

**Access:** `onlyOwner`

**Parameters:**
- `outcomeNames` -- Outcome labels (minimum 2)
- `oracle` -- Oracle address for market resolution
- `metadata` -- Arbitrary metadata bytes
- `year` -- SSA data year
- `region` -- Region string ("" for national)
- `deadline` -- Proposal expiry timestamp (0 = use default duration)

**Returns:** The `bytes32` proposal ID.

---

### `commit`

```solidity
function commit(bytes32 proposalId, uint256[] calldata amounts) external
```

Commits additional USDC capital to an open proposal. A commitment fee is deducted from each amount. The proposal must be open and not past its deadline.

**Access:** Anyone

**Parameters:**
- `proposalId` -- Proposal to commit to
- `amounts` -- Gross USDC per outcome (fee deducted internally)

---

### `commitWithPermit`

```solidity
function commitWithPermit(bytes32 proposalId, uint256[] calldata amounts, PermitArgs calldata permitData) external
```

Same as `commit` but first calls EIP-2612 `permit` on USDC.

**Access:** Anyone

**Parameters:**
- `proposalId` -- Proposal to commit to
- `amounts` -- Gross USDC per outcome
- `permitData` -- EIP-2612 permit arguments

---

### `launchMarket`

```solidity
function launchMarket(bytes32 proposalId) external
```

Launches the prediction market once eligibility is met. Launch eligibility depends on the proposal's timing relative to `batchLaunchDate`:

- **Pre-batch proposals** (created before `batchLaunchDate`): eligible on or after `batchLaunchDate`.
- **Post-batch proposals** (or batch disabled): eligible when net commitment reaches `postBatchMinThreshold` OR `postBatchTimeout` has elapsed.

On launch: creates the PredictionMarket, uses up to `maxCreationFee` from collected fees for phantom shares, sends excess fees to `surplusRecipient`, and executes an aggregate fee-exempt LMSR trade with remaining funds. Share distribution is deferred to `claimShares()`.

**Access:** Anyone

**Parameters:**
- `proposalId` -- Proposal to launch

---

### `claimShares`

```solidity
function claimShares(bytes32 proposalId) external
```

Claims outcome tokens and any USDC refund after a market has launched. Tokens are transferred directly to the caller's wallet. Each user's share of each outcome is proportional to their net commitment for that outcome. Any unspent trading funds are refunded proportionally via `pendingRefunds`.

**Access:** Anyone (must have committed to the proposal)

**Parameters:**
- `proposalId` -- Launched proposal to claim from

---

### `withdrawCommitment`

```solidity
function withdrawCommitment(bytes32 proposalId) external
```

Withdraws committed funds when a proposal is expired or cancelled. Returns the full gross amount (including the fee portion) since the market never launched. If the proposal is still `OPEN` but past its deadline, it is automatically transitioned to `EXPIRED`.

**Access:** Anyone (must have committed)

**Parameters:**
- `proposalId` -- Expired or cancelled proposal

---

### `claimRefund`

```solidity
function claimRefund() external
```

Claims pending USDC refunds accumulated from unspent trading funds across launched proposals.

**Access:** Anyone (claims own refunds)

---

### `cancelProposal`

```solidity
function cancelProposal(bytes32 proposalId) external
```

Cancels an open proposal. Committers can then call `withdrawCommitment` for a full refund.

**Access:** `onlyOwner`

**Parameters:**
- `proposalId` -- Proposal to cancel

---

### `openYear`

```solidity
function openYear(uint16 year) external
```

Opens a year for new proposals. Year must be non-zero.

**Access:** `onlyOwner`

**Parameters:**
- `year` -- Year to open (e.g., 2026)

---

### `closeYear`

```solidity
function closeYear(uint16 year) external
```

Closes a year, preventing new proposals for that year.

**Access:** `onlyOwner`

**Parameters:**
- `year` -- Year to close

---

### `seedDefaultRegions`

```solidity
function seedDefaultRegions() external
```

Seeds the `validRegions` mapping with all 50 US state abbreviations. Can only be called once.

**Access:** `onlyOwner`

---

### `addRegion`

```solidity
function addRegion(string calldata region) external
```

Adds a region code to the valid regions set.

**Access:** `onlyOwner`

**Parameters:**
- `region` -- Region code (automatically uppercased)

---

### `removeRegion`

```solidity
function removeRegion(string calldata region) external
```

Removes a region code from the valid regions set.

**Access:** `onlyOwner`

**Parameters:**
- `region` -- Region code to remove

---

### `setNamesMerkleRoot`

```solidity
function setNamesMerkleRoot(bytes32 _root) external
```

Sets the Merkle root for name validation. Set to `bytes32(0)` to disable the whitelist (all names allowed).

**Access:** `onlyOwner`

**Parameters:**
- `_root` -- New Merkle root

---

### `approveName`

```solidity
function approveName(string calldata name) external
```

Manually approves a name, bypassing Merkle proof validation.

**Access:** `onlyOwner`

**Parameters:**
- `name` -- Name to approve (stored lowercased)

---

### `setSurplusRecipient`

```solidity
function setSurplusRecipient(address _surplusRecipient) external
```

Sets the address that receives excess commitment fees and trading surplus.

**Access:** `onlyOwner`

**Parameters:**
- `_surplusRecipient` -- New recipient address (must be non-zero)

---

### `setDefaultOracle`

```solidity
function setDefaultOracle(address _oracle) external
```

Sets the default oracle used for new proposals (not `adminPropose`).

**Access:** `onlyOwner`

**Parameters:**
- `_oracle` -- New oracle address (must be non-zero)

---

### `setDefaultDeadlineDuration`

```solidity
function setDefaultDeadlineDuration(uint256 _duration) external
```

Sets the default proposal deadline duration in seconds.

**Access:** `onlyOwner`

**Parameters:**
- `_duration` -- Duration in seconds

---

### `setCommitmentFeeBps`

```solidity
function setCommitmentFeeBps(uint256 _bps) external
```

Sets the commitment fee in basis points. Cannot exceed `MAX_COMMITMENT_FEE_BPS` (1000 = 10%).

**Access:** `onlyOwner`

**Parameters:**
- `_bps` -- Fee in basis points (e.g., 500 = 5%)

---

### `setMaxCreationFee`

```solidity
function setMaxCreationFee(uint256 _maxFee) external
```

Sets the maximum USDC used from commitment fees for market creation phantom shares.

**Access:** `onlyOwner`

**Parameters:**
- `_maxFee` -- Maximum creation fee in USDC (6 decimals)

---

### `setBatchLaunchDate`

```solidity
function setBatchLaunchDate(uint256 _date) external
```

Sets the batch launch date. Proposals created before this date can only launch on or after it. Set to 0 to disable batch mode.

**Access:** `onlyOwner`

**Parameters:**
- `_date` -- Unix timestamp (0 = disabled)

---

### `setPostBatchMinThreshold`

```solidity
function setPostBatchMinThreshold(uint256 _threshold) external
```

Sets the minimum net commitment for immediate launch of post-batch proposals.

**Access:** `onlyOwner`

**Parameters:**
- `_threshold` -- Threshold in USDC (6 decimals)

---

### `setPostBatchTimeout`

```solidity
function setPostBatchTimeout(uint256 _timeout) external
```

Sets the timeout after which post-batch proposals auto-qualify for launch.

**Access:** `onlyOwner`

**Parameters:**
- `_timeout` -- Timeout in seconds

---

### `setUsdcAllowance`

```solidity
function setUsdcAllowance(uint256 amount) external
```

Sets the USDC approval for the PredictionMarket contract. The constructor sets `type(uint256).max`; use this to adjust if needed.

**Access:** `onlyOwner`

**Parameters:**
- `amount` -- New allowance amount

---

### `withdrawUsdc`

```solidity
function withdrawUsdc(uint256 amount, address to) external
```

Withdraws USDC from the Launchpad contract to the specified address.

**Access:** `onlyOwner`

**Parameters:**
- `amount` -- USDC amount to withdraw
- `to` -- Recipient address

---

### `isValidName`

```solidity
function isValidName(string memory name, bytes32[] calldata proof) public view returns (bool)
```

Checks whether a name is valid via the Merkle whitelist or manual approval. Returns `true` for all names if `namesMerkleRoot` is `bytes32(0)`.

**Access:** Anyone (view)

**Parameters:**
- `name` -- Name to validate
- `proof` -- Merkle proof (can be empty if whitelist is disabled or name is manually approved)

**Returns:** `true` if the name is valid.

---

### `isValidRegion`

```solidity
function isValidRegion(string memory region) public view returns (bool)
```

Checks whether a region code is valid. Empty string (national) is always valid.

**Access:** Anyone (view)

**Parameters:**
- `region` -- Region code to check

**Returns:** `true` if valid.

---

### `getProposal`

```solidity
function getProposal(bytes32 proposalId) external view returns (ProposalInfo memory)
```

Returns full proposal details as a `ProposalInfo` struct.

**Access:** Anyone (view)

**Parameters:**
- `proposalId` -- Proposal to query

**Returns:** `ProposalInfo` struct.

---

### `getCommitted`

```solidity
function getCommitted(bytes32 proposalId, address user) external view returns (uint256[] memory)
```

Returns the net committed amounts per outcome for a user.

**Access:** Anyone (view)

**Parameters:**
- `proposalId` -- Proposal to query
- `user` -- User address

**Returns:** Array of net USDC committed per outcome.

---

### `hasClaimed`

```solidity
function hasClaimed(bytes32 proposalId, address user) external view returns (bool)
```

Checks whether a user has already claimed shares for a launched proposal.

**Access:** Anyone (view)

**Parameters:**
- `proposalId` -- Proposal to check
- `user` -- User address

**Returns:** `true` if claimed.

---

### `getMarketKey`

```solidity
function getMarketKey(string calldata name, uint16 year, string calldata region) external pure returns (bytes32)
```

Computes the market key hash for a (name, year, region) combination. Useful for checking `marketKeyToProposal`.

**Access:** Anyone (pure)

**Parameters:**
- `name` -- Baby name
- `year` -- Year
- `region` -- Region code

**Returns:** The `bytes32` market key.

---

### `getProposalByMarketKey`

```solidity
function getProposalByMarketKey(string calldata name, uint16 year, string calldata region) external view returns (bytes32)
```

Returns the proposal ID for a given (name, year, region) combination, or `bytes32(0)` if none exists.

**Access:** Anyone (view)

**Parameters:**
- `name` -- Baby name
- `year` -- Year
- `region` -- Region code

**Returns:** The `bytes32` proposal ID.

---

## Events

| Event | Description |
|---|---|
| `ProposalCreated(bytes32 indexed proposalId, bytes32 indexed questionId, string name, uint16 year, string region, address proposer, uint256 deadline)` | Emitted when a proposal is created |
| `Committed(bytes32 indexed proposalId, address indexed user, uint256[] amounts, uint256 total)` | Emitted when a user commits capital |
| `CommitmentWithdrawn(bytes32 indexed proposalId, address indexed user, uint256 amount)` | Emitted when a user withdraws from an expired/cancelled proposal |
| `MarketLaunched(bytes32 indexed proposalId, bytes32 indexed marketId, uint256 actualCost, uint256 feesUsedForCreation, uint256 excessFees, uint256 committerCount)` | Emitted when a proposal launches a market |
| `SharesClaimed(bytes32 indexed proposalId, address indexed user, uint256[] shares, uint256 refund)` | Emitted when a user claims outcome tokens |
| `ProposalCancelled(bytes32 indexed proposalId)` | Emitted when a proposal is cancelled by admin |
| `RefundClaimed(address indexed user, uint256 amount)` | Emitted when pending refunds are claimed |
| `SurplusRecipientUpdated(address indexed oldRecipient, address indexed newRecipient)` | Emitted when surplus recipient changes |
| `NamesMerkleRootUpdated(bytes32 oldRoot, bytes32 newRoot)` | Emitted when the names Merkle root changes |
| `NameApproved(string name)` | Emitted when a name is manually approved |
| `DefaultOracleUpdated(address indexed oldOracle, address indexed newOracle)` | Emitted when the default oracle changes |
| `DefaultDeadlineDurationUpdated(uint256 oldDuration, uint256 newDuration)` | Emitted when the default deadline duration changes |
| `DefaultRegionsSeeded()` | Emitted when US state regions are seeded |
| `YearOpened(uint16 indexed year)` | Emitted when a year is opened |
| `YearClosed(uint16 indexed year)` | Emitted when a year is closed |
| `RegionAdded(string region)` | Emitted when a region is added |
| `RegionRemoved(string region)` | Emitted when a region is removed |
| `CommitmentFeeBpsUpdated(uint256 oldBps, uint256 newBps)` | Emitted when the commitment fee changes |
| `MaxCreationFeeUpdated(uint256 oldFee, uint256 newFee)` | Emitted when the max creation fee changes |
| `BatchLaunchDateUpdated(uint256 oldDate, uint256 newDate)` | Emitted when the batch launch date changes |
| `PostBatchMinThresholdUpdated(uint256 oldThreshold, uint256 newThreshold)` | Emitted when the post-batch min threshold changes |
| `PostBatchTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout)` | Emitted when the post-batch timeout changes |

---

## Errors

| Error | Description |
|---|---|
| `NotOpen()` | Proposal is not in the OPEN state |
| `NotLaunched()` | Proposal is not in the LAUNCHED state |
| `AlreadyClaimed()` | User has already claimed shares |
| `DeadlinePassed()` | Proposal deadline has passed |
| `InvalidAmounts()` | Amounts array is wrong length or all zeros |
| `ProposalExists()` | A proposal with this ID already exists |
| `DuplicateMarketKey()` | An active proposal already exists for this (name, year, region) |
| `InvalidDeadline()` | Deadline is in the past |
| `InvalidOracle()` | Oracle address is zero |
| `InvalidOutcomes()` | Fewer than 2 outcomes provided |
| `InvalidName()` | Name fails Merkle proof and manual approval validation |
| `InvalidYear()` | Year is zero |
| `YearNotOpen()` | The specified year is not open for proposals |
| `InvalidRegion()` | Region code is not in the valid regions set |
| `BelowThreshold()` | Total commitment is zero |
| `NotEligibleForLaunch()` | Launch eligibility conditions not met |
| `NotWithdrawable()` | Proposal state does not allow withdrawal |
| `NothingToWithdraw()` | User has no committed funds to withdraw |
| `NothingToClaim()` | User has no shares or refunds to claim |
| `TransferFailed()` | USDC transfer returned false |
| `ZeroAddress()` | Address parameter is zero |
| `DefaultsNotSet()` | Default oracle or deadline duration is not configured |
| `DefaultRegionsAlreadySeeded()` | `seedDefaultRegions` has already been called |
| `FeeTooHigh()` | Commitment fee exceeds `MAX_COMMITMENT_FEE_BPS` |
