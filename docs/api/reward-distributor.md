# RewardDistributor API Reference

`src/RewardDistributor.sol`

Distributes USDC rewards to users via Merkle proofs. Rewards are organized by epoch -- an admin sets a Merkle root per epoch, and users claim by providing a proof of their allocation. Supports batch claims across multiple epochs in a single transaction. Uses Solady's `OwnableRoles` for access control.

---

## Constants

| Name | Value | Description |
|---|---|---|
| `ADMIN_ROLE` | `1 << 0` | Role bit for epoch management functions |

---

## State Variables

| Name | Type | Description |
|---|---|---|
| `usdc` | `IERC20` | USDC token contract |
| `epochRoots` | `mapping(uint256 => bytes32)` | Merkle root per epoch ID |
| `epochClaimed` | `mapping(uint256 => mapping(address => bool))` | Whether a user has claimed for a given epoch |

---

## Functions

### `claimReward`

```solidity
function claimReward(uint256 epochId, uint256 amount, bytes32[] calldata proof) external
```

Claims a USDC reward for a specific epoch. The leaf is `keccak256(abi.encodePacked(caller, amount))`. Each user can only claim once per epoch.

**Access:** Anyone

**Parameters:**
- `epochId` -- Epoch to claim from
- `amount` -- USDC amount to claim
- `proof` -- Merkle proof verifying the claim

---

### `batchClaimRewards`

```solidity
function batchClaimRewards(uint256[] calldata epochIds_, uint256[] calldata amounts, bytes32[][] calldata proofs) external
```

Claims rewards for multiple epochs in a single transaction. All arrays must have the same length. USDC is transferred once for the total amount.

**Access:** Anyone

**Parameters:**
- `epochIds_` -- Array of epoch IDs
- `amounts` -- Array of USDC amounts per epoch
- `proofs` -- Array of Merkle proofs per epoch

---

### `setEpochRoot`

```solidity
function setEpochRoot(uint256 epochId, bytes32 merkleRoot) external
```

Sets the Merkle root for an epoch. Reverts if the epoch already has a root.

**Access:** `onlyRoles(ADMIN_ROLE)`

**Parameters:**
- `epochId` -- Epoch ID
- `merkleRoot` -- Merkle root for the epoch

---

### `setEpochRoots`

```solidity
function setEpochRoots(uint256[] calldata epochIds_, bytes32[] calldata merkleRoots) external
```

Sets Merkle roots for multiple epochs in a single call. Arrays must have the same length. Reverts if any epoch already has a root.

**Access:** `onlyRoles(ADMIN_ROLE)`

**Parameters:**
- `epochIds_` -- Array of epoch IDs
- `merkleRoots` -- Array of Merkle roots

---

### `replaceEpochRoot`

```solidity
function replaceEpochRoot(uint256 epochId, bytes32 merkleRoot) external
```

Replaces the Merkle root for an existing epoch. Reverts if the epoch has not been set yet. Note: users who already claimed under the old root remain claimed.

**Access:** `onlyRoles(ADMIN_ROLE)`

**Parameters:**
- `epochId` -- Epoch ID
- `merkleRoot` -- New Merkle root

---

### `hasClaimedEpoch`

```solidity
function hasClaimedEpoch(address user, uint256 epochId) external view returns (bool)
```

Checks whether a user has already claimed for a specific epoch.

**Access:** Anyone (view)

**Parameters:**
- `user` -- Address to check
- `epochId` -- Epoch ID

**Returns:** `true` if the user has claimed.

---

## Events

| Event | Description |
|---|---|
| `RewardClaimed(uint256 indexed epochId, address indexed user, uint256 amount)` | Emitted when a user claims a reward |
| `EpochRootSet(uint256 indexed epochId, bytes32 merkleRoot)` | Emitted when an epoch root is set or replaced |

---

## Errors

| Error | Description |
|---|---|
| `EpochAlreadySet()` | Epoch root has already been set (use `replaceEpochRoot` instead) |
| `InvalidProof()` | Merkle proof verification failed |
| `AlreadyClaimed()` | User has already claimed for this epoch |
| `EpochNotSet()` | Epoch root has not been set |
| `UsdcTransferFailed()` | USDC transfer returned false |
| `MismatchedArrays()` | Input arrays have different lengths |
