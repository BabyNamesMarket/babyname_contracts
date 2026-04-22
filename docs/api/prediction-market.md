# PredictionMarket API Reference

`src/PredictionMarket.sol`

The current `PredictionMarket` contract is a direct baby-name LMSR market maker. Users create binary YES/NO markets for `(name, gender, year, region)` tuples, trade outcome tokens against the LMSR curve, and redeem after oracle resolution.

## Core Types

### `Gender`

| Value | Meaning |
|---|---|
| `0` | `BOY` |
| `1` | `GIRL` |

### `MarketInfo`

| Field | Type | Notes |
|---|---|---|
| `oracle` | `address` | Resolver for the market |
| `resolved` | `bool` | Whether payout percentages are set |
| `paused` | `bool` | Whether trading is paused |
| `alpha` | `uint256` | LMSR sensitivity parameter |
| `totalUsdcIn` | `uint256` | Net USDC held by the LMSR pool |
| `creator` | `address` | Market creator |
| `questionId` | `bytes32` | PM-local question identifier |
| `surplusRecipient` | `address` | Trading fee + resolution surplus recipient |
| `outcomeQs` | `uint256[]` | Current outstanding quantities |
| `outcomeTokens` | `address[]` | YES/NO token addresses |
| `payoutPcts` | `uint256[]` | Resolution payouts, sums to `1e6` |
| `initialSharesPerOutcome` | `uint256` | Phantom shares per outcome |

### `Trade`

| Field | Type | Notes |
|---|---|---|
| `marketId` | `bytes32` | Market to trade |
| `deltaShares` | `int256[]` | Positive = buy, negative = sell |
| `maxCost` | `uint256` | Max gross spend for buys |
| `minPayout` | `uint256` | Min net proceeds for sells |
| `deadline` | `uint256` | Trade expiry |

## Important State

| Name | Type | Notes |
|---|---|---|
| `usdc` | `IERC20` | Collateral token |
| `validation` | `MarketValidation` | External validator for names and regions |
| `outcomeTokenImplementation` | `address` | Clone target for YES/NO tokens |
| `targetVig` | `uint256` | Default `70_000` |
| `tradingFeeBps` | `uint256` | Default `300` = 3% |
| `creationFeeBps` | `uint256` | Default `500` = 5% |
| `globalPaused` | `bool` | Emergency trading pause |
| `yearOpen` | `mapping(uint16 => bool)` | Enabled years |
| `marketKeyToMarketId` | `mapping(bytes32 => bytes32)` | `(name, gender, year, region)` lookup |
| `marketKeyToQuestionId` | `mapping(bytes32 => bytes32)` | Reverse lookup helper |
| `surplus` | `mapping(address => uint256)` | Withdrawable fees + surplus |

## Initialization and Admin

### `initialize`

```solidity
function initialize(address _usdc, address _validation, address _owner) external
```

Initializes the proxy with collateral token, optional validation contract, and explicit owner. On Base Sepolia this runs atomically in the `ERC1967Proxy` constructor.

### `setValidation`

```solidity
function setValidation(address _validation) external
```

One-time owner-only binding for the external `MarketValidation` contract.

### `setDefaultOracle`

```solidity
function setDefaultOracle(address _oracle) external
```

Sets the default oracle used for newly created name markets.

### `setDefaultSurplusRecipient`

```solidity
function setDefaultSurplusRecipient(address _surplusRecipient) external
```

Sets the default fee and resolution-surplus recipient for new markets.

### `openYear` / `closeYear`

```solidity
function openYear(uint16 year) external
function closeYear(uint16 year) external
```

Owner-only year gating for market creation.

### Validation Admin

```solidity
function seedDefaultRegions() external
function addRegion(string calldata region) external
function removeRegion(string calldata region) external
function setNamesMerkleRoot(Gender gender, bytes32 root) external
function approveName(string calldata name, Gender gender) external
function proposeName(string calldata name, Gender gender) external
```

These functions manage the external `MarketValidation` contract. `seedDefaultRegions()` enables the built-in 50-state abbreviation set.

### Fee and Pause Admin

```solidity
function setTargetVig(uint256 newTargetVig) external
function setTradingFee(uint256 _feeBps) external
function setMarketTradingFee(bytes32 marketId, uint256 _feeBps) external
function setCreationFeeBps(uint256 _bps) external
function setGlobalPaused(bool paused) external
```

`setTargetVig`, `setTradingFee`, `setMarketTradingFee`, and `setGlobalPaused` require `PROTOCOL_MANAGER_ROLE`. `setCreationFeeBps` is owner-only.

## Market Creation

### `createNameMarket`

```solidity
function createNameMarket(
    string calldata name,
    uint16 year,
    Gender gender,
    bytes32[] calldata proof,
    uint256[] calldata initialBuyAmounts
) external returns (bytes32)
```

Creates a national market with region `""`.

### `createRegionalNameMarket`

```solidity
function createRegionalNameMarket(
    string calldata name,
    uint16 year,
    Gender gender,
    string calldata region,
    bytes32[] calldata proof,
    uint256[] calldata initialBuyAmounts
) external returns (bytes32)
```

Creates a regional market. Region must be empty or a valid US state code accepted by `MarketValidation`.

Creation notes:

- `initialBuyAmounts` must have length 2 for YES and NO.
- Each side pays a 5% creation fee by default.
- The fee seeds symmetric phantom shares used for initial LMSR depth.
- Any 1-unit rounding dust is explicitly collected and credited to `surplus`.

## Trading and Resolution

### `trade`

```solidity
function trade(Trade memory tradeData) external returns (int256)
```

Main trading entrypoint. Buys pay gross cost including fee. Sells receive net proceeds after fee.

### `buyExactIn`

```solidity
function buyExactIn(
    bytes32 marketId,
    uint256 outcomeIndex,
    uint256 grossAmount,
    uint256 minSharesOut,
    uint256 deadline
) external returns (uint256 sharesBought)
```

Exact-input buy helper. The trading fee is taken from `grossAmount` first, then the remaining budget is applied to the LMSR curve.

### `pauseMarket` / `unpauseMarket`

```solidity
function pauseMarket(bytes32 marketId) external
function unpauseMarket(bytes32 marketId) external
```

Callable by the market oracle or a protocol manager.

### `resolveMarketWithPayoutSplit`

```solidity
function resolveMarketWithPayoutSplit(bytes32 marketId, uint256[] calldata payoutPcts) external
```

Sets resolution payouts. `payoutPcts` must sum to `1e6`.

### `redeem`

```solidity
function redeem(address token, uint256 amount) external
```

Burns resolved YES/NO tokens and pays the corresponding USDC amount.

### `withdrawSurplus`

```solidity
function withdrawSurplus() external
```

Withdraws accumulated trading fees, odd-fee dust, and post-resolution surplus for `msg.sender`.

## Read Functions

```solidity
function isValidName(string memory name, Gender gender, bytes32[] calldata proof) public view returns (bool)
function isValidRegion(string memory region) public view returns (bool)
function getPrices(bytes32 marketId) external view returns (uint256[] memory)
function quoteBuyExactIn(bytes32 marketId, uint256 outcomeIndex, uint256 grossAmount)
    external
    view
    returns (uint256 sharesBought, uint256 lmsrCost, uint256 fee, uint256 totalCharge)
function getMarketInfo(bytes32 marketId) external view returns (MarketInfo memory)
function marketExists(bytes32 marketId) public view returns (bool)
function namesMerkleRoot(uint8 gender) external view returns (bytes32)
function approvedNames(bytes32 key) external view returns (bool)
function proposedNames(bytes32 key) external view returns (bool)
function validRegions(bytes32 key) external view returns (bool)
function defaultRegionsSeeded() external view returns (bool)
```

## Math Helpers

```solidity
function calculateAlpha(uint256 nOutcomes, uint256 _targetVig) public pure returns (uint256)
function cost(uint256[] memory qs, uint256 alpha) public pure returns (uint256)
function calcPrice(uint256[] memory qs, uint256 alpha) public pure returns (uint256[] memory)
function computeExponentialTerms(uint256[] memory qs, uint256 bWad)
    public
    pure
    returns (ExponentialTerms memory)
function quoteTrade(uint256[] memory qs, uint256 alpha, int256[] memory deltaShares)
    public
    pure
    returns (int256)
```

`quoteTrade` now guarantees that any buy-side trade which mints positive shares costs at least `1` micro-USDC, preventing free mints from rounding-to-zero.
