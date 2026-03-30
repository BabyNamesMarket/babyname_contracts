# OutcomeToken API Reference

`src/OutcomeToken.sol`

A minimal ERC20 token representing a single outcome in a prediction market. Each outcome in a market gets its own OutcomeToken contract, deployed as a minimal proxy (clone) by the PredictionMarket. Minting and burning are restricted to the owning PredictionMarket contract. Uses Solady's ERC20 implementation with 6 decimals (matching USDC).

---

## Structs

### `TokenStorage`

| Field | Type | Description |
|---|---|---|
| `initialized` | `bool` | Whether the token has been initialized |
| `predictionMarket` | `address` | PredictionMarket contract authorized to mint/burn |
| `pendingPredictionMarket` | `address` | Pending new PredictionMarket (two-step transfer) |
| `name` | `string` | Token name |
| `symbol` | `string` | Token symbol |

---

## Functions

### `initialize`

```solidity
function initialize(string memory name_, string memory symbol_, address predictionMarket_) external
```

Initializes the token with a name, symbol, and the PredictionMarket address. Can only be called once. Called by PredictionMarket during market creation.

**Access:** Anyone (but reverts if already initialized)

**Parameters:**
- `name_` -- Token name (typically `"OutcomeName: 0xQuestionId"`)
- `symbol_` -- Token symbol (typically the outcome name)
- `predictionMarket_` -- PredictionMarket contract address (must be non-zero)

---

### `mint`

```solidity
function mint(address to, uint256 amount) external
```

Mints tokens to an address. Called by PredictionMarket when shares are bought.

**Access:** `onlyPredictionMarket`

**Parameters:**
- `to` -- Recipient address
- `amount` -- Amount to mint

---

### `burn`

```solidity
function burn(address account, uint256 amount) external
```

Burns tokens from an address. Called by PredictionMarket when shares are sold or redeemed.

**Access:** `onlyPredictionMarket`

**Parameters:**
- `account` -- Address to burn from
- `amount` -- Amount to burn

---

### `setPendingPredictionMarket`

```solidity
function setPendingPredictionMarket(address pendingPredictionMarket) external
```

Initiates a two-step transfer of the PredictionMarket authority. The pending address must call `acceptPredictionMarket` to complete the transfer.

**Access:** `onlyPredictionMarket`

**Parameters:**
- `pendingPredictionMarket` -- New PredictionMarket address

---

### `acceptPredictionMarket`

```solidity
function acceptPredictionMarket() external
```

Completes the two-step PredictionMarket authority transfer. Must be called by the pending PredictionMarket address.

**Access:** Pending PredictionMarket only (`msg.sender == pendingPredictionMarket`)

---

### `predictionMarket`

```solidity
function predictionMarket() external view returns (address)
```

Returns the current PredictionMarket address authorized to mint and burn.

**Access:** Anyone (view)

**Returns:** PredictionMarket contract address.

---

### `name`

```solidity
function name() public view returns (string memory)
```

Returns the token name.

**Access:** Anyone (view)

---

### `symbol`

```solidity
function symbol() public view returns (string memory)
```

Returns the token symbol.

**Access:** Anyone (view)

---

### `decimals`

```solidity
function decimals() public pure returns (uint8)
```

Returns `6` (matching USDC decimals).

**Access:** Anyone (pure)

**Returns:** `6`

---

## Events

| Event | Description |
|---|---|
| `PredictionMarketTransferInitiated(address indexed from, address indexed to)` | Emitted when a PredictionMarket transfer is initiated |
| `PredictionMarketTransferAccepted(address indexed newPredictionMarket)` | Emitted when a PredictionMarket transfer is accepted |

All standard ERC20 events (`Transfer`, `Approval`) are also emitted by the inherited Solady ERC20.

---

## Errors

| Error | Description |
|---|---|
| `NotPredictionMarket()` | Caller is not the authorized PredictionMarket |
| `AlreadyInitialized()` | Token has already been initialized |
