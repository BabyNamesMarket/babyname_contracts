# PredictionMarket API Reference

`src/PredictionMarket.sol`

A prediction market contract using a liquidity-sensitive Logarithmic Market Scoring Rule (LMSR) for outcome pricing. Markets are created with a set of named outcomes, funded by a creation fee that seeds phantom shares. Traders buy and sell outcome tokens, and after the oracle resolves the market, token holders redeem for USDC proportional to the payout split.

---

## Structs

### `CreateMarketParams`

| Field | Type | Description |
|---|---|---|
| `oracle` | `address` | Address authorized to resolve the market |
| `creationFeePerOutcome` | `uint256` | USDC fee per outcome (6 decimals). If 0, uses the global `marketCreationFee` |
| `initialBuyMaxCost` | `uint256` | Max USDC the creator will pay for the optional initial buy trade. 0 to skip |
| `questionId` | `bytes32` | Unique question identifier. First 20 bytes must equal `msg.sender` |
| `surplusRecipient` | `address` | Address that receives trading fees and resolution surplus |
| `metadata` | `bytes` | Arbitrary metadata emitted in the `MarketCreated` event |
| `initialBuyShares` | `int256[]` | Share amounts for an optional initial buy (must be non-negative). Length must match `outcomeNames` |
| `outcomeNames` | `string[]` | Names of each outcome (2 to `maxOutcomes`) |

### `MarketInfo`

| Field | Type | Description |
|---|---|---|
| `oracle` | `address` | Oracle address |
| `resolved` | `bool` | Whether the market has been resolved |
| `paused` | `bool` | Whether trading is paused |
| `alpha` | `uint256` | LMSR alpha parameter (controls price sensitivity) |
| `totalUsdcIn` | `uint256` | Total USDC held by the market's LMSR pool |
| `creator` | `address` | Market creator address |
| `questionId` | `bytes32` | Question identifier |
| `surplusRecipient` | `address` | Recipient of fees and surplus |
| `outcomeQs` | `uint256[]` | Current quantity of shares outstanding per outcome |
| `outcomeTokens` | `address[]` | Outcome token contract addresses |
| `payoutPcts` | `uint256[]` | Payout percentages per outcome (set on resolution, sum to 1e6) |
| `initialSharesPerOutcome` | `uint256` | Phantom shares seeded at creation |

### `Trade`

| Field | Type | Description |
|---|---|---|
| `marketId` | `bytes32` | Market to trade in |
| `deltaShares` | `int256[]` | Shares to buy (positive) or sell (negative) per outcome |
| `maxCost` | `uint256` | Maximum gross USDC to spend (buys, including fee) |
| `minPayout` | `uint256` | Minimum net USDC to receive (sells, after fee) |
| `deadline` | `uint256` | Transaction deadline timestamp |

### `PermitArgs`

| Field | Type | Description |
|---|---|---|
| `value` | `uint256` | Permit approval amount |
| `deadline` | `uint256` | Permit deadline |
| `v` | `uint8` | ECDSA v |
| `r` | `bytes32` | ECDSA r |
| `s` | `bytes32` | ECDSA s |

### `ExponentialTerms`

| Field | Type | Description |
|---|---|---|
| `expTerms` | `uint256[]` | Exponentiated term per outcome |
| `sumExp` | `uint256` | Sum of all exponential terms |
| `offset` | `int256` | Numerical offset for stability |

---

## Constants

| Name | Value | Description |
|---|---|---|
| `ONE` | `1e6` | Fixed-point unit (6 decimals, matches USDC) |
| `DEFAULT_TARGET_VIG` | `70_000` | Default target vig (7% in 6-decimal fixed point) |
| `DEFAULT_MARKET_CREATION_FEE` | `5e6` | Default per-outcome creation fee (5 USDC) |
| `COST_ROUNDING_BUFFER` | `1` | Rounding buffer for cost calculations |
| `QUOTE_TRADE_ROUNDING_BUFFER` | `1` | Rounding buffer added to positive trade quotes |
| `PROTOCOL_MANAGER_ROLE` | `1 << 0` | Role bit for protocol management functions |
| `MARKET_CREATOR_ROLE` | `1 << 1` | Role bit for market creation (when `allowAnyMarketCreator` is false) |
| `MAX_TRADING_FEE_BPS` | `1000` | Maximum trading fee (10%) |

---

## State Variables

| Name | Type | Description |
|---|---|---|
| `usdc` | `IERC20` | USDC token contract |
| `outcomeTokenImplementation` | `address` | OutcomeToken implementation used for minimal proxy clones |
| `targetVig` | `uint256` | Target vig used to derive alpha and initial shares for new markets |
| `marketCreationFee` | `uint256` | Default per-outcome creation fee in USDC |
| `allowAnyMarketCreator` | `bool` | When true, anyone can create markets without `MARKET_CREATOR_ROLE` |
| `tradingFeeBps` | `uint256` | Global trading fee in basis points (default 300 = 3%) |
| `marketTradingFeeBps` | `mapping(bytes32 => uint256)` | Per-market trading fee override. 0 means use global |
| `markets` | `mapping(bytes32 => MarketInfo)` | Market data by market ID |
| `tokenToMarketId` | `mapping(address => bytes32)` | Maps outcome token address to its market ID |
| `tokenToOutcomeIndex` | `mapping(address => uint256)` | Maps outcome token address to its outcome index |
| `questionIdToMarketId` | `mapping(bytes32 => bytes32)` | Maps question ID to market ID |
| `surplus` | `mapping(address => uint256)` | Accumulated surplus (fees + resolution surplus) per recipient |

---

## Functions

### `initialize`

```solidity
function initialize(address _usdc) external
```

Initializes the contract with the USDC token address. Deploys the OutcomeToken implementation, sets default target vig, market creation fee, max outcomes, and trading fee. Can only be called once.

**Access:** `onlyOwner`

**Parameters:**
- `_usdc` -- USDC token contract address

---

### `createMarket`

```solidity
function createMarket(CreateMarketParams calldata params) external returns (bytes32)
```

Creates a new prediction market with the specified outcomes. The creation fee funds phantom shares whose quantity is derived from `totalFee * ONE / targetVig`. Optionally executes an initial buy trade if `initialBuyMaxCost > 0`.

**Access:** `MARKET_CREATOR_ROLE` (unless `allowAnyMarketCreator` is true)

**Parameters:**
- `params` -- Market creation parameters (see `CreateMarketParams` struct)

**Returns:** The `bytes32` market ID.

---

### `trade`

```solidity
function trade(Trade memory tradeData) external returns (int256)
```

Executes a trade with the trading fee applied. On buys, the user pays gross cost (LMSR cost + fee). On sells, the user receives net payout (LMSR payout - fee). Fees accrue to the market's `surplusRecipient`.

**Access:** Anyone

**Parameters:**
- `tradeData` -- Trade parameters (see `Trade` struct)

**Returns:** The raw LMSR cost delta (positive = user paid, negative = user received, before fees).

---

### `tradeWithPermit`

```solidity
function tradeWithPermit(Trade memory tradeData, PermitArgs calldata permitData) external returns (int256)
```

Same as `trade` but first calls EIP-2612 `permit` on the USDC token to set an allowance, enabling gasless approvals.

**Access:** Anyone

**Parameters:**
- `tradeData` -- Trade parameters (see `Trade` struct)
- `permitData` -- EIP-2612 permit arguments (see `PermitArgs` struct)

**Returns:** The raw LMSR cost delta.

---

### `tradeRaw`

```solidity
function tradeRaw(Trade memory tradeData) external returns (int256)
```

Fee-exempt trade intended for the Launchpad's aggregate bootstrapping trade. Executes a pure LMSR trade with no trading fee. `maxCost` and `minPayout` apply to raw LMSR amounts.

**Access:** `onlyRoles(MARKET_CREATOR_ROLE)`

**Parameters:**
- `tradeData` -- Trade parameters (see `Trade` struct)

**Returns:** The raw LMSR cost delta.

---

### `redeem`

```solidity
function redeem(address token, uint256 amount) external
```

Redeems outcome tokens for USDC after market resolution. Burns the specified tokens and transfers USDC proportional to the outcome's payout percentage.

**Access:** Anyone (must hold the outcome tokens)

**Parameters:**
- `token` -- Outcome token address to redeem
- `amount` -- Number of tokens to redeem

---

### `resolveMarketWithPayoutSplit`

```solidity
function resolveMarketWithPayoutSplit(bytes32 marketId, uint256[] calldata payoutPcts) external
```

Resolves a market by setting the payout percentages for each outcome. Payout percentages must sum to `1e6`. Any surplus USDC (market pool minus total owed to token holders) is credited to the `surplusRecipient`.

**Access:** Market oracle only (`msg.sender == market.oracle`)

**Parameters:**
- `marketId` -- Market to resolve
- `payoutPcts` -- Payout percentage for each outcome (must sum to 1e6)

---

### `pauseMarket`

```solidity
function pauseMarket(bytes32 marketId) external
```

Pauses trading on a market. The market must not already be resolved or paused.

**Access:** Market oracle only

**Parameters:**
- `marketId` -- Market to pause

---

### `unpauseMarket`

```solidity
function unpauseMarket(bytes32 marketId) external
```

Resumes trading on a paused market. The market must be currently paused and not resolved.

**Access:** Market oracle only

**Parameters:**
- `marketId` -- Market to unpause

---

### `setMarketCreationFee`

```solidity
function setMarketCreationFee(uint256 _marketCreationFee) external
```

Sets the default per-outcome market creation fee. Must be non-zero.

**Access:** `onlyRoles(PROTOCOL_MANAGER_ROLE)`

**Parameters:**
- `_marketCreationFee` -- New fee in USDC (6 decimals)

---

### `setTargetVig`

```solidity
function setTargetVig(uint256 newTargetVig) external
```

Sets the target vig used to derive alpha and initial shares for new markets. Must be non-zero.

**Access:** `onlyRoles(PROTOCOL_MANAGER_ROLE)`

**Parameters:**
- `newTargetVig` -- New target vig value

---

### `setTradingFee`

```solidity
function setTradingFee(uint256 _feeBps) external
```

Sets the global trading fee in basis points. Cannot exceed `MAX_TRADING_FEE_BPS` (1000 = 10%).

**Access:** `onlyRoles(PROTOCOL_MANAGER_ROLE)`

**Parameters:**
- `_feeBps` -- New fee in basis points (e.g., 300 = 3%)

---

### `setMarketTradingFee`

```solidity
function setMarketTradingFee(bytes32 marketId, uint256 _feeBps) external
```

Sets a per-market trading fee override. Set to 0 to revert to the global fee. Cannot exceed `MAX_TRADING_FEE_BPS`.

**Access:** `onlyRoles(PROTOCOL_MANAGER_ROLE)`

**Parameters:**
- `marketId` -- Market to configure
- `_feeBps` -- Fee in basis points (0 = use global)

---

### `withdrawSurplus`

```solidity
function withdrawSurplus() external
```

Withdraws all accumulated surplus (trading fees + resolution surplus) for `msg.sender`. Reverts if the caller has no surplus.

**Access:** Anyone (withdraws own surplus)

---

### `setAllowAnyMarketCreator`

```solidity
function setAllowAnyMarketCreator(bool allow) external
```

Toggles whether anyone can create markets or only addresses with `MARKET_CREATOR_ROLE`.

**Access:** `onlyRoles(PROTOCOL_MANAGER_ROLE)`

**Parameters:**
- `allow` -- `true` to allow anyone, `false` to require the role

---

### `grantMarketCreatorRole`

```solidity
function grantMarketCreatorRole(address account) external
```

Grants `MARKET_CREATOR_ROLE` to an address.

**Access:** `onlyRoles(PROTOCOL_MANAGER_ROLE)`

**Parameters:**
- `account` -- Address to grant the role to

---

### `revokeMarketCreatorRole`

```solidity
function revokeMarketCreatorRole(address account) external
```

Revokes `MARKET_CREATOR_ROLE` from an address.

**Access:** `onlyRoles(PROTOCOL_MANAGER_ROLE)`

**Parameters:**
- `account` -- Address to revoke the role from

---

### `setMaxOutcomes`

```solidity
function setMaxOutcomes(uint256 newMaxOutcomes) external
```

Sets the maximum number of outcomes allowed per market. Must be at least 2.

**Access:** `onlyRoles(PROTOCOL_MANAGER_ROLE)`

**Parameters:**
- `newMaxOutcomes` -- New maximum

---

### `bailoutMarket`

```solidity
function bailoutMarket(bytes32 marketId, uint256 bailoutAmount) external
```

Injects additional USDC into a market's pool to cover insolvency. Transfers USDC from the caller.

**Access:** `onlyRoles(PROTOCOL_MANAGER_ROLE)`

**Parameters:**
- `marketId` -- Market to bail out
- `bailoutAmount` -- USDC amount to inject

---

### `getPrices`

```solidity
function getPrices(bytes32 marketId) external view returns (uint256[] memory)
```

Returns the current prices for all outcomes in a market.

**Access:** Anyone (view)

**Parameters:**
- `marketId` -- Market to query

**Returns:** Array of prices per outcome (6-decimal fixed point, sum slightly above 1e6 due to vig).

---

### `getMarketInfo`

```solidity
function getMarketInfo(bytes32 marketId) external view returns (MarketInfo memory)
```

Returns the full `MarketInfo` struct for a market.

**Access:** Anyone (view)

**Parameters:**
- `marketId` -- Market to query

**Returns:** `MarketInfo` struct.

---

### `marketExists`

```solidity
function marketExists(bytes32 marketId) public view returns (bool)
```

Checks whether a market exists (has outcome tokens deployed).

**Access:** Anyone (view)

**Parameters:**
- `marketId` -- Market to check

**Returns:** `true` if the market exists.

---

### `calculateAlpha`

```solidity
function calculateAlpha(uint256 nOutcomes, uint256 _targetVig) public pure returns (uint256)
```

Calculates the LMSR alpha parameter for a given number of outcomes and target vig. Formula: `alpha = targetVig / (nOutcomes * ln(nOutcomes))`.

**Access:** Anyone (pure)

**Parameters:**
- `nOutcomes` -- Number of outcomes
- `_targetVig` -- Target vig value

**Returns:** The alpha parameter.

---

### `cost`

```solidity
function cost(uint256[] memory qs, uint256 alpha) public pure returns (uint256 c)
```

Calculates the LMSR cost function for a given market state. Uses the liquidity-sensitive logarithmic scoring rule with offset exponentials for numerical stability.

**Access:** Anyone (pure)

**Parameters:**
- `qs` -- Array of share quantities per outcome
- `alpha` -- LMSR alpha parameter

**Returns:** The cost value.

---

### `calcPrice`

```solidity
function calcPrice(uint256[] memory qs, uint256 alpha) public pure returns (uint256[] memory prices)
```

Calculates current prices for all outcomes from the softmax distribution with an entropy adjustment term.

**Access:** Anyone (pure)

**Parameters:**
- `qs` -- Array of share quantities per outcome
- `alpha` -- LMSR alpha parameter

**Returns:** Array of prices per outcome.

---

### `computeExponentialTerms`

```solidity
function computeExponentialTerms(uint256[] memory qs, uint256 bWad) public pure returns (ExponentialTerms memory terms)
```

Computes offset exponential terms used internally by `cost` and `calcPrice` for numerically stable calculations.

**Access:** Anyone (pure)

**Parameters:**
- `qs` -- Array of share quantities per outcome
- `bWad` -- The `b` parameter in WAD (18-decimal) precision

**Returns:** `ExponentialTerms` struct containing per-outcome exp terms, their sum, and the offset.

---

### `quoteTrade`

```solidity
function quoteTrade(uint256[] memory qs, uint256 alpha, int256[] memory deltaShares) public pure returns (int256 costDelta)
```

Quotes the raw LMSR cost of a trade without executing it. Positive means the user would pay; negative means the user would receive. Does not include the trading fee.

**Access:** Anyone (pure)

**Parameters:**
- `qs` -- Current share quantities per outcome
- `alpha` -- LMSR alpha parameter
- `deltaShares` -- Shares to buy (positive) or sell (negative) per outcome

**Returns:** The LMSR cost delta.

---

## Events

| Event | Description |
|---|---|
| `MarketCreated(bytes32 indexed marketId, address indexed oracle, bytes32 indexed questionId, address surplusRecipient, address creator, bytes metadata, uint256 alpha, uint256 marketCreationFeeTotal, address[] outcomeTokens, string[] outcomeNames, uint256[] outcomeQs)` | Emitted when a market is created |
| `MarketResolved(bytes32 indexed marketId, uint256[] payoutPcts, uint256 surplus)` | Emitted when a market is resolved |
| `MarketTraded(bytes32 indexed marketId, address indexed trader, uint256 alpha, int256 usdcFlow, uint256 fee, int256[] deltaShares, uint256[] outcomeQs)` | Emitted on every trade |
| `TokensRedeemed(bytes32 indexed marketId, address indexed redeemer, address token, uint256 shares, uint256 payout)` | Emitted when tokens are redeemed for USDC |
| `SurplusWithdrawn(address indexed to, uint256 amount)` | Emitted when surplus is withdrawn |
| `AllowAnyMarketCreatorUpdated(bool allow)` | Emitted when the open-creation flag changes |
| `MarketPausedUpdated(bytes32 indexed marketId, bool paused)` | Emitted when a market is paused or unpaused |
| `MarketCreationFeeUpdated(uint256 oldFee, uint256 newFee)` | Emitted when the creation fee changes |
| `TargetVigUpdated(uint256 oldTargetVig, uint256 newTargetVig)` | Emitted when the target vig changes |
| `MaxOutcomesUpdated(uint256 oldMaxOutcomes, uint256 newMaxOutcomes)` | Emitted when max outcomes changes |
| `TradingFeeUpdated(uint256 oldBps, uint256 newBps)` | Emitted when the global trading fee changes |
| `MarketTradingFeeUpdated(bytes32 indexed marketId, uint256 bps)` | Emitted when a per-market trading fee is set |

---

## Errors

| Error | Description |
|---|---|
| `CallerNotOracle()` | Caller is not the market's oracle |
| `CallerNotMarketCreator()` | Caller lacks `MARKET_CREATOR_ROLE` |
| `DuplicateQuestionId()` | A market already exists for this question ID |
| `EmptyOutcomeName()` | An outcome name is empty |
| `EmptyQuestionId()` | Question ID is `bytes32(0)` |
| `InsufficientInputAmount()` | Trade cost exceeds `maxCost` |
| `InsufficientOutputAmount()` | Trade payout is below `minPayout` |
| `InvalidFee()` | Fee value is invalid (e.g., zero creation fee) |
| `InvalidMarketState()` | Market is in a state that does not allow this operation |
| `InvalidOracle()` | Oracle address is zero |
| `InvalidPayout()` | Payout array is wrong length or does not sum to 1e6 |
| `InvalidInitialShares()` | Derived initial shares are zero |
| `InvalidMaxOutcomes()` | Max outcomes is below minimum (2) |
| `InvalidTargetVig()` | Target vig is zero |
| `InvalidNumOutcomes()` | Outcome count is out of range or mismatched |
| `InvalidTradingFee()` | Trading fee exceeds `MAX_TRADING_FEE_BPS` |
| `MarketInsolvent()` | Market USDC is less than total owed payouts |
| `ParameterOutOfRange()` | Generic parameter validation failure |
| `MarketDoesNotExist()` | No market found for the given ID |
| `InvalidSurplusRecipient()` | Surplus recipient is zero address |
| `ZeroSurplus()` | No surplus to withdraw |
| `BuysOnly()` | Initial trade contains negative (sell) deltas |
| `InitialFundingInvariantViolation()` | Fee does not cover the minimum funding requirement |
| `TradeExpired()` | Trade deadline has passed |
| `QuestionIdCreatorMismatch()` | First 20 bytes of `questionId` do not match `msg.sender` |
| `UsdcTransferFailed()` | USDC transfer returned false |
