// SPDX-License-Identifier: BUSL-1.1
// Based on Context Markets contracts, used under license
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {OutcomeToken} from "./OutcomeToken.sol";

/**
 * @title Prediction Market
 * @notice A prediction market using liquidity sensitive LMSR for outcome pricing
 * @dev Based on Context Markets with modified fee invariant and derived initial shares
 */
contract PredictionMarket is OwnableRoles {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int256;

    uint256 public constant ONE = 1e6;
    uint256 public constant DEFAULT_TARGET_VIG = 70_000;
    uint256 public constant DEFAULT_MARKET_CREATION_FEE = 5e6;
    uint256 public constant COST_ROUNDING_BUFFER = 1;
    int256 public constant QUOTE_TRADE_ROUNDING_BUFFER = 1;

    uint256 public constant PROTOCOL_MANAGER_ROLE = 1 << 0;
    uint256 public constant MARKET_CREATOR_ROLE = 1 << 1;

    uint256 public constant MAX_TRADING_FEE_BPS = 1000;

    struct CreateMarketParams {
        address oracle;
        uint256 creationFeePerOutcome;
        uint256 initialBuyMaxCost;
        bytes32 questionId;
        address surplusRecipient;
        bytes metadata;
        int256[] initialBuyShares;
        string[] outcomeNames;
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
        uint256 maxCost; // Maximum USDC to spend (for net buys, including fee)
        uint256 minPayout; // Minimum USDC to receive (for net sells, after fee)
        uint256 deadline;
    }

    struct PermitArgs {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct ExponentialTerms {
        uint256[] expTerms;
        uint256 sumExp;
        int256 offset;
    }

    IERC20 public usdc;
    address public outcomeTokenImplementation;

    uint256 public targetVig;
    /// @notice Per-outcome market creation fee in USDC (6 decimals). Used as default when creationFeePerOutcome is 0.
    uint256 public marketCreationFee;
    bool public allowAnyMarketCreator;
    bool private _initialized;

    /// @notice Trading fee in basis points (e.g. 300 = 3%). Applied on buys and sells.
    uint256 public tradingFeeBps = 300;
    /// @notice Per-market trading fee override. 0 means use global tradingFeeBps.
    mapping(bytes32 => uint256) public marketTradingFeeBps;

    mapping(bytes32 => MarketInfo) public markets;
    mapping(address => bytes32) public tokenToMarketId;
    mapping(address => uint256) public tokenToOutcomeIndex;
    mapping(bytes32 => bytes32) public questionIdToMarketId;
    mapping(address => uint256) public surplus;

    uint256 internal constant MIN_OUTCOMES = 2;
    uint256 internal maxOutcomes;

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
    event AllowAnyMarketCreatorUpdated(bool allow);
    event MarketPausedUpdated(bytes32 indexed marketId, bool paused);
    event MarketCreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event TargetVigUpdated(uint256 oldTargetVig, uint256 newTargetVig);
    event MaxOutcomesUpdated(uint256 oldMaxOutcomes, uint256 newMaxOutcomes);
    event TradingFeeUpdated(uint256 oldBps, uint256 newBps);
    event MarketTradingFeeUpdated(bytes32 indexed marketId, uint256 bps);

    error CallerNotOracle();
    error CallerNotMarketCreator();
    error DuplicateQuestionId();
    error EmptyOutcomeName();
    error EmptyQuestionId();
    error InsufficientInputAmount();
    error InsufficientOutputAmount();
    error InvalidFee();
    error InvalidMarketState();
    error InvalidOracle();
    error InvalidPayout();
    error InvalidInitialShares();
    error InvalidMaxOutcomes();
    error InvalidTargetVig();
    error InvalidNumOutcomes();
    error InvalidTradingFee();
    error MarketInsolvent();
    error ParameterOutOfRange();
    error MarketDoesNotExist();
    error InvalidSurplusRecipient();
    error ZeroSurplus();
    error BuysOnly();
    error InitialFundingInvariantViolation();
    error TradeExpired();
    error QuestionIdCreatorMismatch();
    error UsdcTransferFailed();

    constructor() {
        _initializeOwner(tx.origin);
    }

    function initialize(address _usdc) external onlyOwner {
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;

        usdc = IERC20(_usdc);
        outcomeTokenImplementation = address(new OutcomeToken());

        targetVig = DEFAULT_TARGET_VIG;
        emit TargetVigUpdated(0, targetVig);

        marketCreationFee = DEFAULT_MARKET_CREATION_FEE;
        emit MarketCreationFeeUpdated(0, marketCreationFee);

        emit AllowAnyMarketCreatorUpdated(false);

        maxOutcomes = 10;
        emit MaxOutcomesUpdated(0, maxOutcomes);

        tradingFeeBps = 300;
        emit TradingFeeUpdated(0, 300);
    }

    // ========== MARKETS ==========

    /**
     * @notice Creates a new prediction market with specified outcomes
     * @dev initialSharesPerOutcome is derived from the creation fee and targetVig:
     *      s = (totalFee * ONE) / targetVig
     *      If params.creationFeePerOutcome is 0, the global marketCreationFee is used.
     */
    function createMarket(CreateMarketParams calldata params) external returns (bytes32) {
        return _createMarket(params);
    }

    function _createMarket(CreateMarketParams calldata params) internal returns (bytes32) {
        if (params.questionId == bytes32(0)) revert EmptyQuestionId();
        if (questionIdToMarketId[params.questionId] != bytes32(0)) revert DuplicateQuestionId();
        if (!allowAnyMarketCreator) _checkRoles(MARKET_CREATOR_ROLE);
        if (params.outcomeNames.length < MIN_OUTCOMES || params.outcomeNames.length > maxOutcomes) {
            revert InvalidNumOutcomes();
        }
        if (params.outcomeNames.length != params.initialBuyShares.length) revert InvalidNumOutcomes();
        if (params.oracle == address(0)) revert InvalidOracle();
        if (address(uint160(bytes20(params.questionId))) != msg.sender) revert QuestionIdCreatorMismatch();
        if (params.surplusRecipient == address(0)) revert InvalidSurplusRecipient();

        uint256 n = params.outcomeNames.length;
        uint256 alpha = calculateAlpha(n, targetVig);

        uint256 feePerOutcome = params.creationFeePerOutcome > 0 ? params.creationFeePerOutcome : marketCreationFee;
        uint256 totalFee = feePerOutcome * n;

        // Derive initialSharesPerOutcome from fee and targetVig
        // s = totalFee * ONE / targetVig
        uint256 derivedShares = FixedPointMathLib.mulDiv(totalFee, ONE, targetVig);
        if (derivedShares == 0) revert InvalidInitialShares();

        uint256[] memory outcomeQs = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            outcomeQs[i] = derivedShares;
        }

        // Safety check: fee must cover minFee = targetVig * s / ONE
        // Trivially satisfied by construction (s derived from totalFee), but kept as belt-and-suspenders.
        // No rounding buffer needed — this is pure integer arithmetic, not LMSR approximation.
        uint256 minFee = FixedPointMathLib.mulDiv(targetVig, derivedShares, ONE);
        if (totalFee < minFee) revert InitialFundingInvariantViolation();

        if (!usdc.transferFrom(msg.sender, address(this), totalFee)) revert UsdcTransferFailed();

        bytes32 marketId = EfficientHashLib.hash(abi.encodePacked(msg.sender, params.oracle, params.questionId));

        address[] memory outcomeTokens = new address[](n);

        for (uint256 i = 0; i < n; i++) {
            if (bytes(params.outcomeNames[i]).length == 0) revert EmptyOutcomeName();

            OutcomeToken token = OutcomeToken(
                LibClone.cloneDeterministic(
                    outcomeTokenImplementation, EfficientHashLib.hash(abi.encodePacked(marketId, i))
                )
            );
            token.initialize(
                string.concat(params.outcomeNames[i], ": ", LibString.toHexString(uint256(params.questionId), 32)),
                params.outcomeNames[i],
                address(this)
            );

            outcomeTokens[i] = address(token);
            tokenToMarketId[address(token)] = marketId;
            tokenToOutcomeIndex[address(token)] = i;
        }

        markets[marketId] = MarketInfo({
            oracle: params.oracle,
            resolved: false,
            paused: false,
            alpha: alpha,
            totalUsdcIn: totalFee,
            creator: msg.sender,
            questionId: params.questionId,
            surplusRecipient: params.surplusRecipient,
            outcomeQs: outcomeQs,
            outcomeTokens: outcomeTokens,
            payoutPcts: new uint256[](n),
            initialSharesPerOutcome: derivedShares
        });
        questionIdToMarketId[params.questionId] = marketId;

        emit MarketCreated(
            marketId,
            params.oracle,
            params.questionId,
            params.surplusRecipient,
            msg.sender,
            params.metadata,
            alpha,
            totalFee,
            outcomeTokens,
            params.outcomeNames,
            outcomeQs
        );

        if (params.initialBuyMaxCost > 0) {
            for (uint256 i = 0; i < params.initialBuyShares.length; i++) {
                if (params.initialBuyShares[i] < 0) revert BuysOnly();
            }
            Trade memory initialTrade = Trade({
                marketId: marketId,
                deltaShares: params.initialBuyShares,
                maxCost: params.initialBuyMaxCost,
                minPayout: 0,
                deadline: block.timestamp
            });
            int256 cd = _executeTradeCore(initialTrade, msg.sender);
            if (cd > 0) {
                if (!usdc.transferFrom(msg.sender, address(this), uint256(cd))) revert UsdcTransferFailed();
            }
        }
        return marketId;
    }

    /**
     * @notice Calculates the alpha parameter for market pricing based on outcomes and target vig
     * @param nOutcomes Number of outcomes in the market
     * @param _targetVig Target vig (see global targetVig) at the time of market creation
     * @return alpha
     */
    function calculateAlpha(uint256 nOutcomes, uint256 _targetVig) public pure returns (uint256) {
        uint256 lnN = uint256(FixedPointMathLib.lnWad(int256(nOutcomes * 1e18)));
        uint256 alpha = FixedPointMathLib.divWad(_targetVig, nOutcomes * lnN);
        return alpha;
    }

    function _calculateB(uint256 totalQ, uint256 alpha) internal pure returns (uint256) {
        return FixedPointMathLib.mulDiv(alpha, totalQ, ONE);
    }

    function _calculateB(uint256[] memory qs, uint256 alpha) internal pure returns (uint256) {
        return _calculateB(_totalQ(qs), alpha);
    }

    function _totalQ(uint256[] memory qs) internal pure returns (uint256 totalQ) {
        for (uint256 i = 0; i < qs.length; i++) {
            if (qs[i] == 0) revert InvalidMarketState();
            totalQ += qs[i];
        }
    }

    /**
     * @notice Calculates the cost function for a given market state
     * @dev Uses liquidity sensitive logarithmic scoring rule
     */
    function cost(uint256[] memory qs, uint256 alpha) public pure returns (uint256 c) {
        uint256 b = _calculateB(qs, alpha);

        uint256 bWad = b * 1e12;
        ExponentialTerms memory terms = computeExponentialTerms(qs, bWad);
        int256 lnSum = FixedPointMathLib.lnWad(int256(terms.sumExp));
        c = FixedPointMathLib.mulDiv(b, uint256(lnSum + terms.offset), FixedPointMathLib.WAD);
    }

    /**
     * @notice Calculates current prices for all outcomes in a market
     * @dev Prices are derived from the softmax distribution with entropy adjustment
     */
    function calcPrice(uint256[] memory qs, uint256 alpha) public pure returns (uint256[] memory prices) {
        uint256 n = qs.length;
        prices = new uint256[](n);

        uint256 totalQ = _totalQ(qs);
        uint256 b = _calculateB(totalQ, alpha);
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

    /**
     * @notice Computes exponential terms for stable numerical calculation
     * @dev Uses offset exponentials to prevent overflow in exp calculations
     */
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

    /**
     * @notice Quotes the cost of a trade without executing it
     * @dev Positive cost means user pays, negative means user receives
     */
    function quoteTrade(uint256[] memory qs, uint256 alpha, int256[] memory deltaShares)
        public
        pure
        returns (int256 costDelta)
    {
        if (qs.length != deltaShares.length) revert InvalidNumOutcomes();

        uint256[] memory newQs = new uint256[](qs.length);
        for (uint256 i = 0; i < qs.length; i++) {
            if (deltaShares[i] < 0 && uint256(-deltaShares[i]) > qs[i]) {
                revert InvalidMarketState();
            }
            newQs[i] = deltaShares[i] >= 0 ? qs[i] + uint256(deltaShares[i]) : qs[i] - uint256(-deltaShares[i]);
        }

        uint256 costBefore = cost(qs, alpha);
        uint256 costAfter = cost(newQs, alpha);
        costDelta = int256(costAfter) - int256(costBefore);
        if (costDelta > 0) costDelta += QUOTE_TRADE_ROUNDING_BUFFER;
    }

    /**
     * @dev Core LMSR execution — fee-agnostic. Updates outcomeQs, totalUsdcIn,
     *      mints/burns tokens. Does NOT transfer USDC — caller handles that.
     *      Returns the LMSR cost (positive = market receives, negative = market pays).
     */
    function _executeTradeCore(Trade memory tradeData, address trader) internal returns (int256 costDelta) {
        MarketInfo storage m = markets[tradeData.marketId];
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

    /**
     * @notice Executes a trade with the trading fee.
     *         On buys: fee is skimmed from user's gross payment, net goes to LMSR.
     *         On sells: LMSR payout has fee skimmed, net goes to user.
     * @dev maxCost is the gross amount the user will pay (including fee).
     *      minPayout is the minimum net the user will receive (after fee deduction).
     */
    function trade(Trade memory tradeData) external returns (int256) {
        return _tradeWithFee(tradeData, msg.sender);
    }

    function tradeWithPermit(Trade memory tradeData, PermitArgs calldata permitData) external returns (int256) {
        IERC20Permit(address(usdc)).permit(
            msg.sender, address(this), permitData.value, permitData.deadline,
            permitData.v, permitData.r, permitData.s
        );
        return _tradeWithFee(tradeData, msg.sender);
    }

    /**
     * @notice Fee-exempt trade for Launchpad's aggregate bootstrapping trade.
     *         Callable only by MARKET_CREATOR_ROLE. Pure LMSR, no trading fee.
     *         maxCost/minPayout apply to raw LMSR amounts.
     */
    function tradeRaw(Trade memory tradeData) external onlyRoles(MARKET_CREATOR_ROLE) returns (int256) {
        if (!marketExists(tradeData.marketId)) revert MarketDoesNotExist();

        int256 costDelta = _executeTradeCore(tradeData, msg.sender);

        // Handle USDC transfers for raw trade
        if (costDelta > 0) {
            uint256 lmsrCost = uint256(costDelta);
            if (lmsrCost > tradeData.maxCost) revert InsufficientInputAmount();
            if (!usdc.transferFrom(msg.sender, address(this), lmsrCost)) revert UsdcTransferFailed();
        } else if (costDelta < 0) {
            uint256 payout = uint256(-costDelta);
            if (payout < tradeData.minPayout) revert InsufficientOutputAmount();
            if (payout > 0) {
                if (!usdc.transfer(msg.sender, payout)) revert UsdcTransferFailed();
            }
        }

        emit MarketTraded(tradeData.marketId, msg.sender, markets[tradeData.marketId].alpha,
            costDelta, 0, tradeData.deltaShares, markets[tradeData.marketId].outcomeQs);
        return costDelta;
    }

    function _tradeWithFee(Trade memory tradeData, address trader) internal returns (int256) {
        if (!marketExists(tradeData.marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = markets[tradeData.marketId];

        uint256 feeBps = marketTradingFeeBps[tradeData.marketId];
        if (feeBps == 0) feeBps = tradingFeeBps;

        int256 costDelta = _executeTradeCore(tradeData, trader);
        uint256 fee;

        if (costDelta > 0) {
            // BUY: user sends gross, fee skimmed, net covers LMSR cost
            uint256 lmsrCost = uint256(costDelta);
            fee = FixedPointMathLib.mulDiv(lmsrCost, feeBps, 10000 - feeBps);
            uint256 grossCost = lmsrCost + fee;
            if (grossCost > tradeData.maxCost) revert InsufficientInputAmount();
            surplus[m.surplusRecipient] += fee;
            if (!usdc.transferFrom(trader, address(this), grossCost)) revert UsdcTransferFailed();
        } else if (costDelta < 0) {
            // SELL: LMSR pays out, fee skimmed, net goes to user
            uint256 lmsrPayout = uint256(-costDelta);
            fee = FixedPointMathLib.mulDiv(lmsrPayout, feeBps, 10000);
            uint256 userReceives = lmsrPayout - fee;
            if (userReceives < tradeData.minPayout) revert InsufficientOutputAmount();
            surplus[m.surplusRecipient] += fee;
            if (userReceives > 0) {
                if (!usdc.transfer(trader, userReceives)) revert UsdcTransferFailed();
            }
        }

        int256 usdcFlow = costDelta > 0
            ? int256(uint256(costDelta) + fee)
            : costDelta < 0 ? -int256(uint256(-costDelta) - fee) : int256(0);

        emit MarketTraded(tradeData.marketId, trader, m.alpha, usdcFlow, fee, tradeData.deltaShares, m.outcomeQs);
        return costDelta;
    }

    /**
     * @notice Redeems outcome tokens for USDC after market resolution
     */
    function redeem(address token, uint256 amount) external {
        bytes32 marketId = tokenToMarketId[token];
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = markets[marketId];
        if (!m.resolved) revert InvalidMarketState();
        uint256 outcomeIndex = tokenToOutcomeIndex[token];
        if (outcomeIndex >= m.payoutPcts.length) revert InvalidNumOutcomes();
        uint256 payoutPct = m.payoutPcts[outcomeIndex];
        uint256 payout = FixedPointMathLib.mulDiv(amount, payoutPct, ONE);
        OutcomeToken(token).burn(msg.sender, amount);
        if (!usdc.transfer(msg.sender, payout)) revert UsdcTransferFailed();
        emit TokensRedeemed(marketId, msg.sender, token, amount, payout);
    }

    // ========== ORACLE ==========

    /**
     * @notice Resolves a market with specified payout percentages for each outcome
     * @dev Only callable by the market's oracle. Payouts must sum to 1e6
     */
    function resolveMarketWithPayoutSplit(bytes32 marketId, uint256[] calldata payoutPcts) external {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = markets[marketId];
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
        MarketInfo storage m = markets[marketId];
        if (msg.sender != m.oracle) revert CallerNotOracle();
        if (m.resolved) revert InvalidMarketState();
        if (m.paused) revert InvalidMarketState();
        m.paused = true;
        emit MarketPausedUpdated(marketId, true);
    }

    function unpauseMarket(bytes32 marketId) external {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = markets[marketId];
        if (msg.sender != m.oracle) revert CallerNotOracle();
        if (m.resolved) revert InvalidMarketState();
        if (!m.paused) revert InvalidMarketState();
        m.paused = false;
        emit MarketPausedUpdated(marketId, false);
    }

    // ========== ADMIN ==========

    /**
     * @notice Sets the per-outcome market creation fee (used as default when creationFeePerOutcome is 0)
     * @dev initialSharesPerOutcome is derived at market creation time as:
     *      s = (totalFee * ONE) / targetVig
     */
    function setMarketCreationFee(uint256 _marketCreationFee) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (_marketCreationFee == 0) revert InvalidFee();
        uint256 oldFee = marketCreationFee;
        marketCreationFee = _marketCreationFee;
        emit MarketCreationFeeUpdated(oldFee, _marketCreationFee);
    }

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
        marketTradingFeeBps[marketId] = _feeBps;
        emit MarketTradingFeeUpdated(marketId, _feeBps);
    }

    function withdrawSurplus() external {
        uint256 amount = surplus[msg.sender];
        if (amount == 0) revert ZeroSurplus();
        surplus[msg.sender] = 0;
        if (!usdc.transfer(msg.sender, amount)) revert UsdcTransferFailed();
        emit SurplusWithdrawn(msg.sender, amount);
    }

    function setAllowAnyMarketCreator(bool allow) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (allow == allowAnyMarketCreator) return;
        allowAnyMarketCreator = allow;
        emit AllowAnyMarketCreatorUpdated(allow);
    }

    function grantMarketCreatorRole(address account) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        _grantRoles(account, MARKET_CREATOR_ROLE);
    }

    function revokeMarketCreatorRole(address account) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        _removeRoles(account, MARKET_CREATOR_ROLE);
    }

    function setMaxOutcomes(uint256 newMaxOutcomes) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (newMaxOutcomes < MIN_OUTCOMES) revert InvalidMaxOutcomes();
        uint256 oldMaxOutcomes = maxOutcomes;
        maxOutcomes = newMaxOutcomes;
        emit MaxOutcomesUpdated(oldMaxOutcomes, newMaxOutcomes);
    }

    function bailoutMarket(bytes32 marketId, uint256 bailoutAmount) external onlyRoles(PROTOCOL_MANAGER_ROLE) {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        MarketInfo storage m = markets[marketId];
        m.totalUsdcIn += bailoutAmount;
        if (!usdc.transferFrom(msg.sender, address(this), bailoutAmount)) revert UsdcTransferFailed();
    }

    // ========== INFO ==========

    function getPrices(bytes32 marketId) external view returns (uint256[] memory) {
        MarketInfo storage m = markets[marketId];
        return calcPrice(m.outcomeQs, m.alpha);
    }

    function getMarketInfo(bytes32 marketId) external view returns (MarketInfo memory) {
        if (!marketExists(marketId)) revert MarketDoesNotExist();
        return markets[marketId];
    }

    function marketExists(bytes32 marketId) public view returns (bool) {
        return markets[marketId].outcomeTokens.length > 0;
    }
}
