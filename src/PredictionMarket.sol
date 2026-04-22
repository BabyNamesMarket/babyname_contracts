// SPDX-License-Identifier: BUSL-1.1
// Based on Context Markets contracts, used under license
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {MarketValidation} from "./MarketValidation.sol";

/**
 * @title Prediction Market
 * @notice Baby name prediction market using liquidity-sensitive LMSR pricing.
 * @dev Based on Context Markets with modified fee invariant and derived initial shares.
 */
contract PredictionMarket is OwnableRoles, UUPSUpgradeable {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    uint256 public constant ONE = 1e6;
    uint256 public constant DEFAULT_TARGET_VIG = 70_000;
    int256 public constant QUOTE_TRADE_ROUNDING_BUFFER = 1;

    uint256 public constant PROTOCOL_MANAGER_ROLE = 1 << 0;

    uint256 public constant MAX_TRADING_FEE_BPS = 1000;

    // ========== TYPES ==========

    enum Gender {
        BOY,
        GIRL
    }

    struct MarketInfo {
        address oracle;
        bool resolved;
        bool paused;
        uint256 alpha;
        uint256 totalUsdcIn;
        address creator;
        bytes32 questionId;
        address surplusRecipient;
        uint256[] outcomeQs;
        address[] outcomeTokens;
        uint256[] payoutPcts;
        uint256 initialSharesPerOutcome;
    }

    struct Trade {
        bytes32 marketId;
        int256[] deltaShares; // Positive = buy, negative = sell
        uint256 maxCost; // Share-target buy slippage guard: maximum USDC to spend (including fee)
        uint256 minPayout; // Share-target sell slippage guard: minimum USDC to receive (after fee)
        uint256 deadline;
    }

    struct ExponentialTerms {
        uint256[] expTerms;
        uint256 sumExp;
        int256 offset;
    }

    // ========== CORE STATE ==========

    IERC20 public usdc;
    address public outcomeTokenImplementation;

    uint256 public targetVig;
    bool private _initialized;
    bool public globalPaused;

    /// @notice Trading fee in basis points (e.g. 300 = 3%). Applied on buys and sells.
    uint256 public tradingFeeBps;
    /// @notice Per-market trading fee override. A separate flag is used so `0` can mean a real 0% override.
    mapping(bytes32 => uint256) internal _marketTradingFeeBps;
    mapping(bytes32 => bool) public marketTradingFeeOverrideSet;

    mapping(bytes32 => MarketInfo) internal _markets;
    mapping(address => bytes32) public tokenToMarketId;
    mapping(address => uint256) public tokenToOutcomeIndex;
    mapping(bytes32 => bytes32) public questionIdToMarketId;
    mapping(address => uint256) public surplus;

    // ========== NAME MARKET STATE ==========

    /// @notice Whether a year is open for new markets. Years are locked by default.
    mapping(uint16 => bool) public yearOpen;

    MarketValidation public validation;

    address public defaultOracle;
    address public defaultSurplusRecipient;

    /// @notice Creation fee in basis points (5% = 500 bps)
    uint256 public creationFeeBps;

    /// @notice Maximum allowed creation fee (10% = 1000 bps)
    uint256 public constant MAX_CREATION_FEE_BPS = 1000;

    /// @notice Maps market key hash(name, gender, year, region) to the PM marketId.
    mapping(bytes32 => bytes32) public marketKeyToMarketId;

    /// @notice Maps market key to questionId (for reverse lookups).
    mapping(bytes32 => bytes32) public marketKeyToQuestionId;

    // ========== EVENTS ==========

    event MarketCreated(
        bytes32 indexed marketId,
        address indexed oracle,
        bytes32 indexed questionId,
        address surplusRecipient,
        address creator,
        bytes metadata,
        uint256 alpha,
        uint256 marketCreationFeeTotal,
        address[] outcomeTokens,
        string[] outcomeNames,
        uint256[] outcomeQs
    );
    event MarketResolved(bytes32 indexed marketId, uint256[] payoutPcts, uint256 surplus);
    event MarketTraded(
        bytes32 indexed marketId,
        address indexed trader,
        uint256 alpha,
        int256 usdcFlow,
        uint256 fee,
        int256[] deltaShares,
        uint256[] outcomeQs
    );
    event TokensRedeemed(
        bytes32 indexed marketId, address indexed redeemer, address token, uint256 shares, uint256 payout
    );
    event SurplusWithdrawn(address indexed to, uint256 amount);
    event MarketPausedUpdated(bytes32 indexed marketId, bool paused);
    event TargetVigUpdated(uint256 oldTargetVig, uint256 newTargetVig);
    event TradingFeeUpdated(uint256 oldBps, uint256 newBps);
    event MarketTradingFeeUpdated(bytes32 indexed marketId, uint256 bps);
    event GlobalPausedUpdated(bool paused);

    event NameMarketCreated(
        bytes32 indexed marketId,
        bytes32 indexed questionId,
        string name,
        Gender gender,
        uint16 year,
        string region,
        address creator,
        uint256 creationFee
    );
    event DefaultSurplusRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event DefaultOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event YearOpened(uint16 indexed year);
    event YearClosed(uint16 indexed year);
    event CreationFeeBpsUpdated(uint256 oldBps, uint256 newBps);

    // ========== ERRORS ==========

    error CallerNotOracle();
    error DuplicateQuestionId();
    error EmptyQuestionId();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error InvalidFee();
    error InvalidMarketState();
    error InvalidOracle();
    error InvalidPayout();
    error InvalidInitialShares();
    error InvalidTargetVig();
    error InvalidNumOutcomes();
    error InvalidTradingFee();
    error MarketInsolvent();
    error MarketDoesNotExist();
    error InvalidSurplusRecipient();
    error ZeroSurplus();
    error BuysOnly();
    error InitialFundingInvariantViolation();
    error TradeExpired();
    error UsdcTransferFailed();
    error GlobalPaused();

    error DuplicateMarketKey();
    error InvalidName();
    error InvalidYear();
    error YearNotOpen();
    error InvalidRegion();
    error DefaultsNotSet();
    error FeeTooHigh();
    error InvalidAmounts();
    error InvalidOutcomeIndex();
    error InvalidUsdc();
    error InvalidValidation();
    error ZeroAddress();
    error ValidationAlreadySet();

    constructor() {
        _initialized = true;
    }

    function initialize(address _usdc, address _validation, address _owner) external {
        if (_initialized) revert AlreadyInitialized();
        if (_usdc == address(0) || _usdc.code.length == 0) revert InvalidUsdc();
        if (_owner == address(0)) revert ZeroAddress();
        _initialized = true;
        _initializeOwner(_owner);

        usdc = IERC20(_usdc);
        outcomeTokenImplementation = address(new OutcomeToken());
        if (_validation != address(0)) {
            if (_validation.code.length == 0) revert InvalidValidation();
            validation = MarketValidation(_validation);
        }

        targetVig = DEFAULT_TARGET_VIG;
        emit TargetVigUpdated(0, targetVig);

        tradingFeeBps = 300;
        emit TradingFeeUpdated(0, 300);

        creationFeeBps = 500;
        emit CreationFeeBpsUpdated(0, 500);
    }

    // ========== NAME MARKET CREATION ==========

    /**
     * @notice Creates a baby name prediction market using exact-input semantics.
     *         For each side's gross input, the creation fee is removed first and the
     *         remaining budget is used to buy as many shares as possible on that side.
     *         The summed creation fees fund the phantom shares.
     *
     * @param name The baby name
     * @param year The SSA data year (e.g. 2025)
     * @param gender BOY or GIRL
     * @param proof Merkle proof for name validity
     * @param initialBuyAmounts Per-outcome gross USDC spend budgets [YES, NO]
     * @return marketId The market ID
     */
    function createNameMarket(
        string calldata name,
        uint16 year,
        Gender gender,
        bytes32[] calldata proof,
        uint256[] calldata initialBuyAmounts
    ) external returns (bytes32) {
        return _createNameMarket(name, year, gender, "", proof, initialBuyAmounts);
    }

    function createRegionalNameMarket(
        string calldata name,
        uint16 year,
        Gender gender,
        string calldata region,
        bytes32[] calldata proof,
        uint256[] calldata initialBuyAmounts
    ) external returns (bytes32) {
        return _createNameMarket(name, year, gender, region, proof, initialBuyAmounts);
    }

    function _createNameMarket(
        string calldata name,
        uint16 year,
        Gender gender,
        string memory region,
        bytes32[] calldata proof,
        uint256[] calldata initialBuyAmounts
    ) internal returns (bytes32) {
        if (!validation.isValidName(name, uint8(gender), proof)) revert InvalidName();
        if (!yearOpen[year]) revert YearNotOpen();
        if (!validation.isValidRegion(region)) revert InvalidRegion();
        if (defaultOracle == address(0)) revert DefaultsNotSet();
        if (defaultSurplusRecipient == address(0)) revert DefaultsNotSet();
        if (initialBuyAmounts.length != 2) revert InvalidAmounts();

        string memory lowered = name;
        string memory upperRegion = bytes(region).length > 0 ? _toUpperCase(region) : region;

        // Unique key per (name, gender, year, region)
        bytes32 marketKey = keccak256(abi.encode(lowered, gender, year, upperRegion));
        if (marketKeyToMarketId[marketKey] != bytes32(0)) revert DuplicateMarketKey();

        // questionId: this contract's address (20 bytes) + marketKey truncated (12 bytes)
        bytes32 questionId = bytes32((uint256(uint160(address(this))) << 96) | uint256(uint96(bytes12(marketKey))));

        // Calculate total USDC from user and creation fee
        uint256 gross;
        for (uint256 i; i < initialBuyAmounts.length; i++) {
            gross += initialBuyAmounts[i];
        }
        if (gross == 0) revert InvalidAmounts();

        uint256 fee;
        uint256[] memory netBuyBudgets = new uint256[](2);
        for (uint256 i; i < 2; i++) {
            uint256 amountFee = FixedPointMathLib.mulDiv(initialBuyAmounts[i], creationFeeBps, 10000);
            fee += amountFee;
            netBuyBudgets[i] = initialBuyAmounts[i] - amountFee;
        }

        uint256 creationFeePerOutcome = fee / 2;

        uint256 creationFeeTotal = creationFeePerOutcome * 2;
        uint256 excessFee = fee - creationFeeTotal;

        // Create market internally — tokens minted directly to msg.sender,
        // USDC creation fee pulled directly from msg.sender.
        bytes32 marketId = _createMarketCore(
            defaultOracle,
            creationFeePerOutcome,
            questionId,
            defaultSurplusRecipient,
            abi.encode(lowered, gender, year, upperRegion),
            msg.sender
        );

        for (uint256 i; i < 2; i++) {
            if (netBuyBudgets[i] > 0) {
                _executeBudgetBuyCore(marketId, i, netBuyBudgets[i], msg.sender);
            }
        }

        if (excessFee > 0) {
            if (!usdc.transferFrom(msg.sender, address(this), excessFee)) revert UsdcTransferFailed();
            surplus[defaultSurplusRecipient] += excessFee;
        }

        marketKeyToMarketId[marketKey] = marketId;
        marketKeyToQuestionId[marketKey] = questionId;

        emit NameMarketCreated(marketId, questionId, lowered, gender, year, upperRegion, msg.sender, fee);

        return marketId;
    }

    /**
     * @dev Core market creation logic. Always creates a binary YES/NO market.
     * @param caller The address that pays USDC and receives initial buy tokens.
     */
    function _createMarketCore(
        address oracle,
        uint256 creationFeePerOutcome,
        bytes32 questionId,
        address _surplusRecipient,
        bytes memory metadata,
        address caller
    ) internal returns (bytes32) {
        if (globalPaused) revert GlobalPaused();
        if (questionId == bytes32(0)) revert EmptyQuestionId();
        if (questionIdToMarketId[questionId] != bytes32(0)) revert DuplicateQuestionId();
        if (oracle == address(0)) revert InvalidOracle();
        if (_surplusRecipient == address(0)) revert InvalidSurplusRecipient();

        uint256 alpha = calculateAlpha(2, targetVig);

        uint256 totalFee = creationFeePerOutcome * 2;

        // Derive initialSharesPerOutcome from fee and targetVig
        // s = totalFee * ONE / targetVig
        uint256 derivedShares = FixedPointMathLib.mulDiv(totalFee, ONE, targetVig);
        if (derivedShares == 0) revert InvalidInitialShares();

        uint256[] memory outcomeQs = new uint256[](2);
        outcomeQs[0] = derivedShares;
        outcomeQs[1] = derivedShares;

        // Safety check: fee must cover minFee = targetVig * s / ONE
        uint256 minFee = FixedPointMathLib.mulDiv(targetVig, derivedShares, ONE);
        if (totalFee < minFee) revert InitialFundingInvariantViolation();

        if (!usdc.transferFrom(caller, address(this), totalFee)) revert UsdcTransferFailed();

        bytes32 marketId = EfficientHashLib.hash(abi.encodePacked(caller, oracle, questionId));

        address[] memory outcomeTokens = _deployOutcomeTokens(marketId, questionId);

        _markets[marketId] = MarketInfo({
            oracle: oracle,
            resolved: false,
            paused: false,
            alpha: alpha,
            totalUsdcIn: totalFee,
            creator: caller,
            questionId: questionId,
            surplusRecipient: _surplusRecipient,
            outcomeQs: outcomeQs,
            outcomeTokens: outcomeTokens,
            payoutPcts: new uint256[](2),
            initialSharesPerOutcome: derivedShares
        });
        questionIdToMarketId[questionId] = marketId;

        _emitMarketCreated(
            marketId, oracle, questionId, _surplusRecipient, caller, metadata, alpha, totalFee, outcomeTokens, outcomeQs
        );
        return marketId;
    }

    function _deployOutcomeTokens(bytes32 marketId, bytes32 questionId) internal returns (address[] memory outcomeTokens) {
        outcomeTokens = new address[](2);
        string[2] memory outcomeNames = ["YES", "NO"];

        for (uint256 i = 0; i < 2; i++) {
            OutcomeToken token = OutcomeToken(
                LibClone.cloneDeterministic(
                    outcomeTokenImplementation, EfficientHashLib.hash(abi.encodePacked(marketId, i))
                )
            );
            token.initialize(
                string.concat(outcomeNames[i], ": ", LibString.toHexString(uint256(questionId), 32)),
                outcomeNames[i],
                address(this)
            );

            outcomeTokens[i] = address(token);
            tokenToMarketId[address(token)] = marketId;
            tokenToOutcomeIndex[address(token)] = i;
        }
    }

    function _emitMarketCreated(
        bytes32 marketId,
        address oracle,
        bytes32 questionId,
        address surplusRecipient,
        address caller,
        bytes memory metadata,
        uint256 alpha,
        uint256 totalFee,
        address[] memory outcomeTokens,
        uint256[] memory outcomeQs
    ) internal {
        string[] memory outcomeNamesArray = new string[](2);
        outcomeNamesArray[0] = "YES";
        outcomeNamesArray[1] = "NO";

        emit MarketCreated(
            marketId,
            oracle,
            questionId,
            surplusRecipient,
            caller,
            metadata,
            alpha,
            totalFee,
            outcomeTokens,
            outcomeNamesArray,
            outcomeQs
        );
    }

    // ========== TRADING ==========

    /**
     * @notice Executes a trade with the trading fee.
     *         On buys: fee is skimmed from user's gross payment, net goes to LMSR.
     *         On sells: LMSR payout has fee skimmed, net goes to user.
     * @dev maxCost is the gross amount the user will pay (including fee).
     *      minPayout is the minimum net the user will receive (after fee deduction).
     */
    function trade(Trade memory tradeData) external returns (int256) {
        if (!marketExists(tradeData.marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = _markets[tradeData.marketId];

        uint256 feeBps = _effectiveTradingFeeBps(tradeData.marketId);

        int256 costDelta = _executeTradeCore(tradeData, msg.sender);
        uint256 fee;

        if (costDelta > 0) {
            // BUY: user sends gross, fee skimmed, net covers LMSR cost
            uint256 lmsrCost = uint256(costDelta);
            fee = FixedPointMathLib.mulDiv(lmsrCost, feeBps, 10000 - feeBps);
            uint256 grossCost = lmsrCost + fee;
            if (grossCost > tradeData.maxCost) revert InsufficientInputAmount();
            surplus[m.surplusRecipient] += fee;
            if (!usdc.transferFrom(msg.sender, address(this), grossCost)) revert UsdcTransferFailed();
        } else if (costDelta < 0) {
            // SELL: LMSR pays out, fee skimmed, net goes to user
            uint256 lmsrPayout = uint256(-costDelta);
            fee = FixedPointMathLib.mulDiv(lmsrPayout, feeBps, 10000);
            uint256 userReceives = lmsrPayout - fee;
            if (userReceives < tradeData.minPayout) revert InsufficientOutputAmount();
            surplus[m.surplusRecipient] += fee;
            if (userReceives > 0) {
                if (!usdc.transfer(msg.sender, userReceives)) revert UsdcTransferFailed();
            }
        }

        int256 usdcFlow = costDelta > 0
            ? int256(uint256(costDelta) + fee)
            : costDelta < 0 ? -int256(uint256(-costDelta) - fee) : int256(0);

        emit MarketTraded(tradeData.marketId, msg.sender, m.alpha, usdcFlow, fee, tradeData.deltaShares, m.outcomeQs);
        return costDelta;
    }

    /**
     * @notice Exact-input buy path for regular trading.
     * @dev `grossAmount` is the user's total spend target. The fee is removed first,
     *      then the remaining budget is used to buy as many shares as possible.
     *      Any leftover due to integer rounding is simply not charged.
     */
    function buyExactIn(bytes32 marketId, uint256 outcomeIndex, uint256 grossAmount, uint256 minSharesOut, uint256 deadline)
        external
        returns (uint256 sharesBought)
    {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        if (grossAmount == 0) revert InvalidAmounts();
        MarketInfo storage m = _markets[marketId];

        uint256 feeBps = _effectiveTradingFeeBps(marketId);
        uint256 fee = FixedPointMathLib.mulDiv(grossAmount, feeBps, 10000);
        uint256 budget = grossAmount - fee;

        (sharesBought,) = _quoteBudgetBuy(m.outcomeQs, m.alpha, outcomeIndex, budget);
        if (sharesBought < minSharesOut || sharesBought == 0) revert InsufficientOutputAmount();

        int256[] memory deltaShares = new int256[](m.outcomeQs.length);
        deltaShares[outcomeIndex] = int256(sharesBought);

        Trade memory tradeData =
            Trade({marketId: marketId, deltaShares: deltaShares, maxCost: 0, minPayout: 0, deadline: deadline});

        int256 costDelta = _executeTradeCore(tradeData, msg.sender);
        uint256 lmsrCost = uint256(costDelta);
        surplus[m.surplusRecipient] += fee;

        if (!usdc.transferFrom(msg.sender, address(this), lmsrCost + fee)) revert UsdcTransferFailed();

        emit MarketTraded(marketId, msg.sender, m.alpha, int256(lmsrCost + fee), fee, deltaShares, m.outcomeQs);
    }

    /**
     * @notice Redeems outcome tokens for USDC after market resolution.
     * @dev Not blocked by globalPaused — users should always be able to claim resolved winnings.
     */
    function redeem(address token, uint256 amount) external {
        bytes32 marketId = tokenToMarketId[token];
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = _markets[marketId];
        if (!m.resolved) revert InvalidMarketState();
        uint256 outcomeIndex = tokenToOutcomeIndex[token];
        if (outcomeIndex >= m.payoutPcts.length) revert InvalidNumOutcomes();
        uint256 payoutPct = m.payoutPcts[outcomeIndex];
        uint256 payout = FixedPointMathLib.mulDiv(amount, payoutPct, ONE);
        OutcomeToken(token).burn(msg.sender, amount);
        if (!usdc.transfer(msg.sender, payout)) revert UsdcTransferFailed();
        emit TokensRedeemed(marketId, msg.sender, token, amount, payout);
    }

    // ========== LMSR ENGINE ==========

    /**
     * @dev Core LMSR execution — fee-agnostic. Updates outcomeQs, totalUsdcIn,
     *      mints/burns tokens. Does NOT transfer USDC — caller handles that.
     *      Returns the LMSR cost (positive = market receives, negative = market pays).
     */
    function _executeTradeCore(Trade memory tradeData, address trader) internal returns (int256 costDelta) {
        if (globalPaused) revert GlobalPaused();
        MarketInfo storage m = _markets[tradeData.marketId];
        if (m.resolved || m.paused) revert InvalidMarketState();
        if (block.timestamp > tradeData.deadline) revert TradeExpired();

        costDelta = quoteTrade(m.outcomeQs, m.alpha, tradeData.deltaShares);

        if (costDelta > 0) {
            m.totalUsdcIn += uint256(costDelta);
        } else if (costDelta < 0) {
            m.totalUsdcIn -= uint256(-costDelta);
        }

        for (uint256 i = 0; i < tradeData.deltaShares.length; i++) {
            if (tradeData.deltaShares[i] > 0) {
                uint256 buyAmount = uint256(tradeData.deltaShares[i]);
                m.outcomeQs[i] += buyAmount;
                OutcomeToken(m.outcomeTokens[i]).mint(trader, buyAmount);
            } else if (tradeData.deltaShares[i] < 0) {
                uint256 sellAmount = uint256(-tradeData.deltaShares[i]);
                m.outcomeQs[i] -= sellAmount;
                OutcomeToken(m.outcomeTokens[i]).burn(trader, sellAmount);
            }
        }
    }

    function _executeBudgetBuyCore(bytes32 marketId, uint256 outcomeIndex, uint256 budget, address trader)
        internal
        returns (uint256 sharesBought, uint256 lmsrCost)
    {
        if (budget == 0) return (0, 0);
        MarketInfo storage m = _markets[marketId];
        (sharesBought, lmsrCost) = _quoteBudgetBuy(m.outcomeQs, m.alpha, outcomeIndex, budget);
        if (sharesBought == 0) return (0, 0);

        int256[] memory deltaShares = new int256[](m.outcomeQs.length);
        deltaShares[outcomeIndex] = int256(sharesBought);

        Trade memory tradeData =
            Trade({marketId: marketId, deltaShares: deltaShares, maxCost: 0, minPayout: 0, deadline: block.timestamp});
        int256 costDelta = _executeTradeCore(tradeData, trader);
        lmsrCost = uint256(costDelta);

        if (!usdc.transferFrom(trader, address(this), lmsrCost)) revert UsdcTransferFailed();
    }

    function _quoteBudgetBuy(uint256[] memory qs, uint256 alpha, uint256 outcomeIndex, uint256 budget)
        internal
        pure
        returns (uint256 sharesBought, uint256 lmsrCost)
    {
        if (outcomeIndex >= qs.length) revert InvalidOutcomeIndex();
        if (budget == 0) return (0, 0);

        uint256 lo = 0;
        uint256 hi = 1;

        while (true) {
            uint256 quoted = _quoteSingleOutcomeBuy(qs, alpha, outcomeIndex, hi);
            if (quoted > budget) break;
            lo = hi;
            if (hi > type(uint256).max / 2) break;
            hi <<= 1;
        }

        while (lo < hi) {
            uint256 mid = lo + (hi - lo + 1) / 2;
            uint256 quoted = _quoteSingleOutcomeBuy(qs, alpha, outcomeIndex, mid);
            if (quoted <= budget) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }

        sharesBought = lo;
        if (sharesBought == 0) return (0, 0);
        lmsrCost = _quoteSingleOutcomeBuy(qs, alpha, outcomeIndex, sharesBought);
    }

    function _quoteSingleOutcomeBuy(uint256[] memory qs, uint256 alpha, uint256 outcomeIndex, uint256 shares)
        internal
        pure
        returns (uint256 lmsrCost)
    {
        int256[] memory deltaShares = new int256[](qs.length);
        deltaShares[outcomeIndex] = int256(shares);
        lmsrCost = uint256(quoteTrade(qs, alpha, deltaShares));
    }

    function calculateAlpha(uint256 nOutcomes, uint256 _targetVig) public pure returns (uint256) {
        uint256 lnN = uint256(FixedPointMathLib.lnWad(int256(nOutcomes * 1e18)));
        return FixedPointMathLib.divWad(_targetVig, nOutcomes * lnN);
    }

    function cost(uint256[] memory qs, uint256 alpha) public pure returns (uint256 c) {
        uint256 b = _calculateB(qs, alpha);
        uint256 bWad = b * 1e12;
        ExponentialTerms memory terms = computeExponentialTerms(qs, bWad);
        int256 lnSum = FixedPointMathLib.lnWad(int256(terms.sumExp));
        c = FixedPointMathLib.mulDiv(b, uint256(lnSum + terms.offset), FixedPointMathLib.WAD);
    }

    function calcPrice(uint256[] memory qs, uint256 alpha) public pure returns (uint256[] memory prices) {
        uint256 n = qs.length;
        prices = new uint256[](n);

        uint256 totalQ = _totalQ(qs);
        uint256 b = FixedPointMathLib.mulDiv(alpha, totalQ, ONE);
        if (b == 0) revert InvalidMarketState();
        uint256 bWad = b * 1e12;

        ExponentialTerms memory terms = computeExponentialTerms(qs, bWad);

        uint256[] memory sWad = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            sWad[i] = FixedPointMathLib.divWad(terms.expTerms[i], terms.sumExp);
        }

        int256 logSumExpWadSigned = FixedPointMathLib.lnWad(int256(terms.sumExp)) + terms.offset;
        uint256 logSumExpWad = uint256(logSumExpWadSigned);

        uint256 numWad = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 qWad = qs[i] * 1e12;
            numWad += FixedPointMathLib.mulWad(qWad, terms.expTerms[i]);
        }
        uint256 ratioWad = FixedPointMathLib.divWad(numWad, terms.sumExp);
        uint256 sDotZWad = FixedPointMathLib.divWad(ratioWad, bWad);

        uint256 entropyWad = logSumExpWad - sDotZWad;

        uint256 alphaWad = alpha * 1e12;
        uint256 alphaShiftOne = FixedPointMathLib.mulWad(alphaWad, entropyWad) / 1e12;

        for (uint256 i = 0; i < n; i++) {
            uint256 siOne = sWad[i] / 1e12;
            prices[i] = siOne + alphaShiftOne;
        }
    }

    function computeExponentialTerms(uint256[] memory qs, uint256 bWad)
        public
        pure
        returns (ExponentialTerms memory terms)
    {
        uint256 n = qs.length;
        if (n < 2) revert InvalidNumOutcomes();

        uint256 maxQ;
        for (uint256 i = 0; i < n; i++) {
            if (qs[i] > maxQ) {
                maxQ = qs[i];
            }
        }

        terms.offset = int256(FixedPointMathLib.divWad(maxQ * 1e12, bWad));
        terms.expTerms = new uint256[](n);

        for (uint256 i = 0; i < n; i++) {
            uint256 qWad = qs[i] * 1e12;
            int256 exponent = int256(FixedPointMathLib.divWad(qWad, bWad)) - terms.offset;
            uint256 expTerm = uint256(FixedPointMathLib.expWad(exponent));
            terms.expTerms[i] = expTerm;
            terms.sumExp += expTerm;
        }
    }

    function quoteTrade(uint256[] memory qs, uint256 alpha, int256[] memory deltaShares)
        public
        pure
        returns (int256 costDelta)
    {
        if (qs.length != deltaShares.length) revert InvalidNumOutcomes();

        uint256[] memory newQs = new uint256[](qs.length);
        bool hasPositiveDelta;
        for (uint256 i = 0; i < qs.length; i++) {
            if (deltaShares[i] < 0 && uint256(-deltaShares[i]) > qs[i]) {
                revert InvalidMarketState();
            }
            if (deltaShares[i] > 0) hasPositiveDelta = true;
            newQs[i] = deltaShares[i] >= 0 ? qs[i] + uint256(deltaShares[i]) : qs[i] - uint256(-deltaShares[i]);
        }

        uint256 costBefore = cost(qs, alpha);
        uint256 costAfter = cost(newQs, alpha);
        costDelta = int256(costAfter) - int256(costBefore);
        if (costDelta > 0) {
            costDelta += QUOTE_TRADE_ROUNDING_BUFFER;
        } else if (costDelta == 0 && hasPositiveDelta) {
            costDelta = QUOTE_TRADE_ROUNDING_BUFFER;
        }
    }

    function _calculateB(uint256[] memory qs, uint256 alpha) internal pure returns (uint256) {
        return FixedPointMathLib.mulDiv(alpha, _totalQ(qs), ONE);
    }

    function _totalQ(uint256[] memory qs) internal pure returns (uint256 totalQ) {
        for (uint256 i = 0; i < qs.length; i++) {
            if (qs[i] == 0) revert InvalidMarketState();
            totalQ += qs[i];
        }
    }

    // ========== ORACLE ==========

    /**
     * @notice Resolves a market with specified payout percentages for each outcome.
     * @dev Only callable by the market's oracle. Payouts must sum to 1e6.
     *      Not blocked by globalPaused — oracle can wind down markets during emergency.
     */
    function resolveMarketWithPayoutSplit(bytes32 marketId, uint256[] calldata payoutPcts) external {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = _markets[marketId];
        if (m.resolved) revert InvalidMarketState();
        if (msg.sender != m.oracle) revert CallerNotOracle();
        if (payoutPcts.length != m.outcomeQs.length) revert InvalidPayout();

        uint256 sumPayout = 0;
        for (uint256 i = 0; i < payoutPcts.length; i++) {
            sumPayout += payoutPcts[i];
        }
        if (sumPayout != ONE) revert InvalidPayout();

        m.resolved = true;
        m.payoutPcts = payoutPcts;

        uint256 totalPayout = 0;
        uint256 initialSharesPerOutcomeLocal = m.initialSharesPerOutcome;
        for (uint256 i = 0; i < m.outcomeQs.length; i++) {
            uint256 outstandingShares = m.outcomeQs[i] - initialSharesPerOutcomeLocal;
            totalPayout += FixedPointMathLib.mulDiv(outstandingShares, payoutPcts[i], ONE);
        }

        uint256 totalUsdcIn = m.totalUsdcIn;
        if (totalUsdcIn < totalPayout) revert MarketInsolvent();

        uint256 surplusAmount = totalUsdcIn - totalPayout;
        if (surplusAmount > 0) surplus[m.surplusRecipient] += surplusAmount;

        emit MarketResolved(marketId, payoutPcts, surplusAmount);
    }

    function pauseMarket(bytes32 marketId) external {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = _markets[marketId];
        if (msg.sender != m.oracle && !hasAnyRole(msg.sender, PROTOCOL_MANAGER_ROLE)) revert CallerNotOracle();
        if (m.resolved) revert InvalidMarketState();
        if (m.paused) revert InvalidMarketState();
        m.paused = true;
        emit MarketPausedUpdated(marketId, true);
    }

    function unpauseMarket(bytes32 marketId) external {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = _markets[marketId];
        if (msg.sender != m.oracle && !hasAnyRole(msg.sender, PROTOCOL_MANAGER_ROLE)) revert CallerNotOracle();
        if (m.resolved) revert InvalidMarketState();
        if (!m.paused) revert InvalidMarketState();
        m.paused = false;
        emit MarketPausedUpdated(marketId, false);
    }

    // ========== NAME VALIDATION ==========

    function isValidName(string memory name, Gender gender, bytes32[] calldata proof) public view returns (bool) {
        return validation.isValidName(name, uint8(gender), proof);
    }

    function isValidRegion(string memory region) public view returns (bool) {
        return validation.isValidRegion(region);
    }

    // ========== ADMIN ==========

    function setTargetVig(uint256 newTargetVig) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (newTargetVig == 0) revert InvalidTargetVig();
        uint256 oldTargetVig = targetVig;
        targetVig = newTargetVig;
        emit TargetVigUpdated(oldTargetVig, newTargetVig);
    }

    function setTradingFee(uint256 _feeBps) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (_feeBps > MAX_TRADING_FEE_BPS) revert InvalidTradingFee();
        emit TradingFeeUpdated(tradingFeeBps, _feeBps);
        tradingFeeBps = _feeBps;
    }

    function setMarketTradingFee(bytes32 marketId, uint256 _feeBps) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (_feeBps > MAX_TRADING_FEE_BPS) revert InvalidTradingFee();
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        _marketTradingFeeBps[marketId] = _feeBps;
        marketTradingFeeOverrideSet[marketId] = true;
        emit MarketTradingFeeUpdated(marketId, _feeBps);
    }

    function withdrawSurplus() external {
        uint256 amount = surplus[msg.sender];
        if (amount == 0) revert ZeroSurplus();
        surplus[msg.sender] = 0;
        if (!usdc.transfer(msg.sender, amount)) revert UsdcTransferFailed();
        emit SurplusWithdrawn(msg.sender, amount);
    }

    function setGlobalPaused(bool paused) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        globalPaused = paused;
        emit GlobalPausedUpdated(paused);
    }

    // ========== NAME MARKET ADMIN ==========

    function openYear(uint16 year) external onlyOwner {
        if (year == 0) revert InvalidYear();
        yearOpen[year] = true;
        emit YearOpened(year);
    }

    function closeYear(uint16 year) external onlyOwner {
        yearOpen[year] = false;
        emit YearClosed(year);
    }

    function seedDefaultRegions() external onlyOwner {
        validation.seedDefaultRegions();
    }

    function addRegion(string calldata region) external onlyOwner {
        validation.addRegion(region);
    }

    function removeRegion(string calldata region) external onlyOwner {
        validation.removeRegion(region);
    }

    function setNamesMerkleRoot(Gender gender, bytes32 _root) external onlyOwner {
        validation.setNamesMerkleRoot(uint8(gender), _root);
    }

    function approveName(string calldata name, Gender gender) external onlyOwner {
        validation.approveName(name, uint8(gender));
    }

    function proposeName(string calldata name, Gender gender) external {
        validation.proposeName(name, uint8(gender), msg.sender);
    }

    function setValidation(address _validation) external onlyOwner {
        if (_validation == address(0) || _validation.code.length == 0) revert InvalidValidation();
        if (address(validation) != address(0)) revert ValidationAlreadySet();
        validation = MarketValidation(_validation);
    }

    function setDefaultSurplusRecipient(address _surplusRecipient) external onlyOwner {
        if (_surplusRecipient == address(0)) revert ZeroAddress();
        emit DefaultSurplusRecipientUpdated(defaultSurplusRecipient, _surplusRecipient);
        defaultSurplusRecipient = _surplusRecipient;
    }

    function setDefaultOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert InvalidOracle();
        emit DefaultOracleUpdated(defaultOracle, _oracle);
        defaultOracle = _oracle;
    }

    function setCreationFeeBps(uint256 _bps) external onlyOwner {
        if (_bps == 0) revert InvalidFee();
        if (_bps > MAX_CREATION_FEE_BPS) revert FeeTooHigh();
        emit CreationFeeBpsUpdated(creationFeeBps, _bps);
        creationFeeBps = _bps;
    }

    // ========== UUPS ==========

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ========== INFO ==========

    function getPrices(bytes32 marketId) external view returns (uint256[] memory) {
        MarketInfo storage m = _markets[marketId];
        return calcPrice(m.outcomeQs, m.alpha);
    }

    function quoteBuyExactIn(bytes32 marketId, uint256 outcomeIndex, uint256 grossAmount)
        external
        view
        returns (uint256 sharesBought, uint256 lmsrCost, uint256 fee, uint256 totalCharge)
    {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = _markets[marketId];

        fee = FixedPointMathLib.mulDiv(grossAmount, _effectiveTradingFeeBps(marketId), 10000);
        (sharesBought, lmsrCost) = _quoteBudgetBuy(m.outcomeQs, m.alpha, outcomeIndex, grossAmount - fee);
        totalCharge = lmsrCost + fee;
    }

    function marketTradingFeeBps(bytes32 marketId) external view returns (uint256) {
        if (!marketTradingFeeOverrideSet[marketId]) return 0;
        return _marketTradingFeeBps[marketId];
    }

    function getMarketInfo(bytes32 marketId) external view returns (MarketInfo memory) {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        return _markets[marketId];
    }

    function marketExists(bytes32 marketId) public view returns (bool) {
        return _markets[marketId].outcomeTokens.length > 0;
    }

    function namesMerkleRoot(uint8 gender) external view returns (bytes32) {
        return validation.namesMerkleRoot(gender);
    }

    function approvedNames(bytes32 key) external view returns (bool) {
        return validation.approvedNames(key);
    }

    function proposedNames(bytes32 key) external view returns (bool) {
        return validation.proposedNames(key);
    }

    function validRegions(bytes32 key) external view returns (bool) {
        return validation.validRegions(key);
    }

    function defaultRegionsSeeded() external view returns (bool) {
        return validation.defaultRegionsSeeded();
    }

    // ========== INTERNAL HELPERS ==========

    function _effectiveTradingFeeBps(bytes32 marketId) internal view returns (uint256) {
        if (marketTradingFeeOverrideSet[marketId]) return _marketTradingFeeBps[marketId];
        return tradingFeeBps;
    }

    function _toUpperCase(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bUpper = new bytes(bStr.length);
        for (uint256 i; i < bStr.length; i++) {
            if (bStr[i] >= 0x61 && bStr[i] <= 0x7A) {
                bUpper[i] = bytes1(uint8(bStr[i]) - 32);
            } else {
                bUpper[i] = bStr[i];
            }
        }
        return string(bUpper);
    }

}
