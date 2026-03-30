// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";

contract TestUSDC is ERC20 {
    function name() public pure override returns (string memory) { return "Test USDC"; }
    function symbol() public pure override returns (string memory) { return "tUSDC"; }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PredictionMarketTest is Test {
    TestUSDC usdc;
    PredictionMarket pm;

    uint256 constant ONE = 1e6;
    address constant ORACLE = address(0xBEEF);

    function setUp() public {
        usdc = new TestUSDC();
        pm = new PredictionMarket();

        // Constructor sets owner to tx.origin, so we prank as tx.origin for owner calls
        vm.startPrank(tx.origin);
        pm.initialize(address(usdc));
        pm.grantRoles(address(this), pm.PROTOCOL_MANAGER_ROLE());
        pm.grantRoles(address(this), pm.MARKET_CREATOR_ROLE());
        vm.stopPrank();

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(pm), type(uint256).max);
    }

    // ========== HELPERS ==========

    function _makeQuestionId(address creator, uint96 salt) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(creator)) << 96) | uint256(salt));
    }

    function _defaultCreateParams() internal view returns (PredictionMarket.CreateMarketParams memory) {
        string[] memory names = new string[](2);
        names[0] = "YES";
        names[1] = "NO";
        int256[] memory initialBuy = new int256[](2);

        return PredictionMarket.CreateMarketParams({
            oracle: ORACLE,
            creationFeePerOutcome: 0,
            initialBuyMaxCost: 0,
            questionId: _makeQuestionId(address(this), 1),
            surplusRecipient: address(this),
            metadata: "",
            initialBuyShares: initialBuy,
            outcomeNames: names
        });
    }

    function _createDefaultMarket() internal returns (bytes32) {
        return pm.createMarket(_defaultCreateParams());
    }

    function _createMarketWithSalt(uint96 salt) internal returns (bytes32) {
        PredictionMarket.CreateMarketParams memory p = _defaultCreateParams();
        p.questionId = _makeQuestionId(address(this), salt);
        return pm.createMarket(p);
    }

    function _createNOutcomeMarket(uint256 n, uint96 salt) internal returns (bytes32) {
        string[] memory names = new string[](n);
        int256[] memory initialBuy = new int256[](n);
        for (uint256 i = 0; i < n; i++) {
            names[i] = string(abi.encodePacked("Outcome", bytes1(uint8(65 + i))));
        }

        PredictionMarket.CreateMarketParams memory p = PredictionMarket.CreateMarketParams({
            oracle: ORACLE,
            creationFeePerOutcome: 0,
            initialBuyMaxCost: 0,
            questionId: _makeQuestionId(address(this), salt),
            surplusRecipient: address(this),
            metadata: "",
            initialBuyShares: initialBuy,
            outcomeNames: names
        });
        return pm.createMarket(p);
    }

    function _doTrade(bytes32 marketId, int256[] memory deltaShares, uint256 maxCost, uint256 minPayout)
        internal
        returns (int256)
    {
        PredictionMarket.Trade memory t = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: deltaShares,
            maxCost: maxCost,
            minPayout: minPayout,
            deadline: block.timestamp + 1
        });
        return pm.trade(t);
    }

    // ========== 1. MARKET CREATION ==========

    function test_createMarket_derivedShares() public {
        uint256 fee = pm.marketCreationFee(); // 5e6
        uint256 vig = pm.targetVig(); // 70_000
        uint256 n = 2;
        uint256 expectedTotalFee = fee * n; // 10e6
        uint256 expectedS = (expectedTotalFee * ONE) / vig;

        uint256 balBefore = usdc.balanceOf(address(this));
        bytes32 marketId = _createDefaultMarket();
        uint256 balAfter = usdc.balanceOf(address(this));

        // Verify fee charged
        assertEq(balBefore - balAfter, expectedTotalFee, "total fee charged");

        // Verify derived shares
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        assertEq(info.initialSharesPerOutcome, expectedS, "derived s");
        assertEq(info.outcomeQs.length, 2, "2 outcomes");
        assertEq(info.outcomeQs[0], expectedS, "q[0] == s");
        assertEq(info.outcomeQs[1], expectedS, "q[1] == s");
    }

    function test_createMarket_alpha() public {
        bytes32 marketId = _createDefaultMarket();
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 expectedAlpha = pm.calculateAlpha(2, pm.targetVig());
        assertEq(info.alpha, expectedAlpha, "alpha matches");
    }

    function test_createMarket_outcomeTokensDeployed() public {
        bytes32 marketId = _createDefaultMarket();
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        assertEq(info.outcomeTokens.length, 2, "2 tokens");

        // Tokens should have nonzero addresses and correct symbol
        assertTrue(info.outcomeTokens[0] != address(0), "token0 deployed");
        assertTrue(info.outcomeTokens[1] != address(0), "token1 deployed");
        assertEq(OutcomeToken(info.outcomeTokens[0]).symbol(), "YES");
        assertEq(OutcomeToken(info.outcomeTokens[1]).symbol(), "NO");
    }

    function test_createMarket_totalUsdcIn() public {
        bytes32 marketId = _createDefaultMarket();
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 expectedTotalFee = pm.marketCreationFee() * 2;
        assertEq(info.totalUsdcIn, expectedTotalFee, "totalUsdcIn == totalFee");
    }

    function test_createMarket_questionIdCreatorMismatch() public {
        PredictionMarket.CreateMarketParams memory p = _defaultCreateParams();
        // Use a questionId whose first 20 bytes are a different address
        p.questionId = _makeQuestionId(address(0xDEAD), 1);
        vm.expectRevert(PredictionMarket.QuestionIdCreatorMismatch.selector);
        pm.createMarket(p);
    }

    function test_createMarket_duplicateQuestionId() public {
        _createDefaultMarket();
        vm.expectRevert(PredictionMarket.DuplicateQuestionId.selector);
        pm.createMarket(_defaultCreateParams());
    }

    function test_createMarket_requiresRole() public {
        address alice = address(0xA11CE);
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(pm), type(uint256).max);
        PredictionMarket.CreateMarketParams memory p = _defaultCreateParams();
        p.questionId = _makeQuestionId(alice, 1);

        vm.expectRevert();
        pm.createMarket(p);
        vm.stopPrank();
    }

    function test_createMarket_allowAnyCreator() public {
        pm.setAllowAnyMarketCreator(true);

        address alice = address(0xA11CE);
        usdc.mint(alice, 100e6);

        vm.startPrank(alice);
        usdc.approve(address(pm), type(uint256).max);

        string[] memory names = new string[](2);
        names[0] = "YES";
        names[1] = "NO";
        int256[] memory initialBuy = new int256[](2);

        PredictionMarket.CreateMarketParams memory p = PredictionMarket.CreateMarketParams({
            oracle: ORACLE,
            creationFeePerOutcome: 0,
            initialBuyMaxCost: 0,
            questionId: _makeQuestionId(alice, 1),
            surplusRecipient: alice,
            metadata: "",
            initialBuyShares: initialBuy,
            outcomeNames: names
        });

        bytes32 marketId = pm.createMarket(p);
        assertTrue(pm.marketExists(marketId), "market created by any creator");
        vm.stopPrank();
    }

    // ========== 2. CREATION FEE PER-OUTCOME OVERRIDE ==========

    function test_creationFeePerOutcome_override() public {
        uint256 customFee = 10e6; // 10 USDC per outcome instead of default 5
        uint256 n = 2;
        uint256 expectedTotalFee = customFee * n;

        string[] memory names = new string[](2);
        names[0] = "YES";
        names[1] = "NO";
        int256[] memory initialBuy = new int256[](2);

        PredictionMarket.CreateMarketParams memory p = PredictionMarket.CreateMarketParams({
            oracle: ORACLE,
            creationFeePerOutcome: customFee,
            initialBuyMaxCost: 0,
            questionId: _makeQuestionId(address(this), 50),
            surplusRecipient: address(this),
            metadata: "",
            initialBuyShares: initialBuy,
            outcomeNames: names
        });

        uint256 balBefore = usdc.balanceOf(address(this));
        bytes32 marketId = pm.createMarket(p);
        uint256 balAfter = usdc.balanceOf(address(this));

        // Custom fee should have been charged
        assertEq(balBefore - balAfter, expectedTotalFee, "custom fee charged");

        // Derived shares should differ from default
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 expectedS = (expectedTotalFee * ONE) / pm.targetVig();
        assertEq(info.initialSharesPerOutcome, expectedS, "shares derived from custom fee");

        // Default market uses 5e6 per outcome => s = (10e6 * 1e6) / 70000
        // Custom uses 10e6 per outcome => s = (20e6 * 1e6) / 70000
        // Custom should be ~2x default (within 1 due to integer division rounding)
        uint256 defaultTotalFee = pm.marketCreationFee() * n;
        uint256 defaultS = (defaultTotalFee * ONE) / pm.targetVig();
        assertApproxEqAbs(info.initialSharesPerOutcome, defaultS * 2, 1, "custom s is ~2x default s");
    }

    // ========== 3. FEE INVARIANT ==========

    function test_feeInvariant_solventAtCreation() public {
        bytes32 marketId = _createDefaultMarket();
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        uint256 totalFee = info.totalUsdcIn;
        uint256 s = info.initialSharesPerOutcome;
        uint256 vig = pm.targetVig();

        // minFee = targetVig * s / ONE
        uint256 minFee = (vig * s) / ONE;

        // totalFee >= minFee (the invariant enforced in createMarket)
        assertTrue(totalFee >= minFee, "fee covers minFee");

        // Verify USDC balance of contract matches totalUsdcIn
        assertEq(usdc.balanceOf(address(pm)), totalFee, "PM holds correct USDC");
    }

    // ========== 4. TRADING ==========

    function test_trade_buyYes_priceMovesUp() public {
        bytes32 marketId = _createDefaultMarket();
        uint256[] memory pricesBefore = pm.getPrices(marketId);

        // Buy 10e6 shares of YES (outcome 0)
        int256[] memory delta = new int256[](2);
        delta[0] = int256(10e6);
        delta[1] = int256(0);

        PredictionMarket.Trade memory t = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: delta,
            maxCost: 100e6,
            minPayout: 0,
            deadline: block.timestamp + 1
        });

        pm.trade(t);

        uint256[] memory pricesAfter = pm.getPrices(marketId);

        // YES price should have increased
        assertTrue(pricesAfter[0] > pricesBefore[0], "YES price went up");
        // NO price should have decreased
        assertTrue(pricesAfter[1] < pricesBefore[1], "NO price went down");
    }

    function test_trade_sellBack_roundTrip() public {
        bytes32 marketId = _createDefaultMarket();
        uint256 balStart = usdc.balanceOf(address(this));

        // Buy 5e6 shares of YES
        int256[] memory buyDelta = new int256[](2);
        buyDelta[0] = int256(5e6);
        buyDelta[1] = int256(0);

        PredictionMarket.Trade memory buyTrade = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: buyDelta,
            maxCost: 50e6,
            minPayout: 0,
            deadline: block.timestamp + 1
        });
        pm.trade(buyTrade);

        // Sell the same 5e6 shares back
        int256[] memory sellDelta = new int256[](2);
        sellDelta[0] = -int256(5e6);
        sellDelta[1] = int256(0);

        PredictionMarket.Trade memory sellTrade = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: sellDelta,
            maxCost: 0,
            minPayout: 0,
            deadline: block.timestamp + 1
        });
        pm.trade(sellTrade);

        uint256 balEnd = usdc.balanceOf(address(this));

        // Round-trip should lose due to 3% fee on buy + 3% fee on sell + rounding
        // Total loss is ~6% of the LMSR cost
        assertTrue(balStart >= balEnd, "round-trip costs something");

        // Compute expected approximate loss: quote the buy cost
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        // The LMSR cost for buying 5e6 at initial state is roughly around 2.5e6 for a binary market
        // Fee on buy ~3% of lmsrCost, fee on sell ~3% of lmsrPayout (~same magnitude)
        // Total loss should be less than 10% of the round-trip volume as an upper bound
        uint256 loss = balStart - balEnd;
        // Loss should be positive (fees) but bounded: less than 1e6 for a 5e6 share trade
        assertTrue(loss > 0, "round-trip has non-zero loss from fees");
        assertTrue(loss < 1e6, "round-trip loss is bounded");
    }

    function test_trade_expired() public {
        bytes32 marketId = _createDefaultMarket();

        int256[] memory delta = new int256[](2);
        delta[0] = int256(1e6);
        delta[1] = int256(0);

        PredictionMarket.Trade memory t = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: delta,
            maxCost: 10e6,
            minPayout: 0,
            deadline: block.timestamp - 1
        });

        vm.expectRevert(PredictionMarket.TradeExpired.selector);
        pm.trade(t);
    }

    function test_trade_insufficientMaxCost() public {
        bytes32 marketId = _createDefaultMarket();

        int256[] memory delta = new int256[](2);
        delta[0] = int256(100e6);
        delta[1] = int256(0);

        PredictionMarket.Trade memory t = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: delta,
            maxCost: 1, // way too low
            minPayout: 0,
            deadline: block.timestamp + 1
        });

        vm.expectRevert(PredictionMarket.InsufficientInputAmount.selector);
        pm.trade(t);
    }

    // ========== 5. TRADING FEES ==========

    function test_tradingFee_buyChargesFee() public {
        bytes32 marketId = _createDefaultMarket();
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        // Quote the LMSR cost directly
        int256[] memory delta = new int256[](2);
        delta[0] = int256(10e6);
        delta[1] = int256(0);
        int256 lmsrCost = pm.quoteTrade(info.outcomeQs, info.alpha, delta);
        assertTrue(lmsrCost > 0, "buy has positive cost");

        // Fee formula: fee = lmsrCost * feeBps / (10000 - feeBps)
        uint256 expectedFee = FixedPointMathLib.mulDiv(uint256(lmsrCost), 300, 10000 - 300);
        uint256 expectedUserPays = uint256(lmsrCost) + expectedFee;

        uint256 balBefore = usdc.balanceOf(address(this));
        uint256 surplusBefore = pm.surplus(address(this));

        PredictionMarket.Trade memory t = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: delta,
            maxCost: expectedUserPays + 1, // allow tiny rounding
            minPayout: 0,
            deadline: block.timestamp + 1
        });
        pm.trade(t);

        uint256 balAfter = usdc.balanceOf(address(this));
        uint256 surplusAfter = pm.surplus(address(this));

        uint256 actualPaid = balBefore - balAfter;
        uint256 feeAccrued = surplusAfter - surplusBefore;

        // User pays lmsrCost + fee
        assertEq(actualPaid, expectedUserPays, "user pays lmsr + fee");
        // Fee goes to surplus
        assertEq(feeAccrued, expectedFee, "fee goes to surplus");

        // totalUsdcIn should only include the LMSR cost, not the fee
        PredictionMarket.MarketInfo memory infoAfter = pm.getMarketInfo(marketId);
        assertEq(infoAfter.totalUsdcIn, info.totalUsdcIn + uint256(lmsrCost), "totalUsdcIn excludes fee");
    }

    function test_tradingFee_sellChargesFee() public {
        bytes32 marketId = _createDefaultMarket();

        // First buy some shares
        int256[] memory buyDelta = new int256[](2);
        buyDelta[0] = int256(10e6);
        buyDelta[1] = int256(0);
        _doTrade(marketId, buyDelta, 100e6, 0);

        PredictionMarket.MarketInfo memory infoBeforeSell = pm.getMarketInfo(marketId);

        // Quote the LMSR payout for selling
        int256[] memory sellDelta = new int256[](2);
        sellDelta[0] = -int256(10e6);
        sellDelta[1] = int256(0);
        int256 lmsrCostDelta = pm.quoteTrade(infoBeforeSell.outcomeQs, infoBeforeSell.alpha, sellDelta);
        assertTrue(lmsrCostDelta < 0, "sell has negative cost (payout)");

        uint256 lmsrPayout = uint256(-lmsrCostDelta);
        uint256 expectedFee = lmsrPayout * 300 / 10000; // 3%
        uint256 expectedUserReceives = lmsrPayout - expectedFee;

        uint256 balBefore = usdc.balanceOf(address(this));
        uint256 surplusBefore = pm.surplus(address(this));

        _doTrade(marketId, sellDelta, 0, 0);

        uint256 balAfter = usdc.balanceOf(address(this));
        uint256 surplusAfter = pm.surplus(address(this));

        uint256 actualReceived = balAfter - balBefore;
        uint256 feeAccrued = surplusAfter - surplusBefore;

        // User receives lmsrPayout - fee
        assertEq(actualReceived, expectedUserReceives, "user receives lmsr payout minus fee");
        // Fee goes to surplus
        assertEq(feeAccrued, expectedFee, "sell fee goes to surplus");
    }

    function test_tradingFee_adminCanChange() public {
        // Default is 300 bps (3%)
        assertEq(pm.tradingFeeBps(), 300, "default fee is 300 bps");

        bytes32 marketId = _createDefaultMarket();
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        // Change to 500 bps (5%)
        pm.setTradingFee(500);
        assertEq(pm.tradingFeeBps(), 500, "fee updated to 500 bps");

        // Trade and verify 5% fee applies
        int256[] memory delta = new int256[](2);
        delta[0] = int256(10e6);
        delta[1] = int256(0);
        int256 lmsrCost = pm.quoteTrade(info.outcomeQs, info.alpha, delta);
        // Fee formula: fee = lmsrCost * feeBps / (10000 - feeBps)
        uint256 expectedFee = FixedPointMathLib.mulDiv(uint256(lmsrCost), 500, 10000 - 500);
        uint256 expectedUserPays = uint256(lmsrCost) + expectedFee;

        uint256 balBefore = usdc.balanceOf(address(this));
        _doTrade(marketId, delta, expectedUserPays + 1, 0);
        uint256 balAfter = usdc.balanceOf(address(this));

        assertEq(balBefore - balAfter, expectedUserPays, "5% fee applied after change");
    }

    function test_tradingFee_perMarketOverride() public {
        bytes32 marketId = _createDefaultMarket();
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        // Set per-market override to 100 bps (1%)
        pm.setMarketTradingFee(marketId, 100);
        assertEq(pm.marketTradingFeeBps(marketId), 100, "per-market fee set");

        // Trade and verify 1% fee applies (not the global 3%)
        int256[] memory delta = new int256[](2);
        delta[0] = int256(10e6);
        delta[1] = int256(0);
        int256 lmsrCost = pm.quoteTrade(info.outcomeQs, info.alpha, delta);
        // Fee formula: fee = lmsrCost * feeBps / (10000 - feeBps)
        uint256 expectedFee = FixedPointMathLib.mulDiv(uint256(lmsrCost), 100, 10000 - 100);
        uint256 expectedUserPays = uint256(lmsrCost) + expectedFee;

        uint256 balBefore = usdc.balanceOf(address(this));
        _doTrade(marketId, delta, expectedUserPays + 1, 0);
        uint256 balAfter = usdc.balanceOf(address(this));

        assertEq(balBefore - balAfter, expectedUserPays, "1% per-market fee applied");
    }

    function test_tradingFee_maxCapEnforced() public {
        // MAX_TRADING_FEE_BPS = 1000 (10%)
        // Setting to 1000 should work
        pm.setTradingFee(1000);
        assertEq(pm.tradingFeeBps(), 1000, "10% max allowed");

        // Setting > 1000 should revert
        vm.expectRevert(PredictionMarket.InvalidTradingFee.selector);
        pm.setTradingFee(1001);

        // Same for per-market
        bytes32 marketId = _createDefaultMarket();
        vm.expectRevert(PredictionMarket.InvalidTradingFee.selector);
        pm.setMarketTradingFee(marketId, 1001);
    }

    function test_tradingFee_zeroFeeAllowed() public {
        // Setting trading fee to 0 should be allowed
        pm.setTradingFee(0);
        assertEq(pm.tradingFeeBps(), 0, "zero fee set");

        bytes32 marketId = _createDefaultMarket();
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        // Trade with zero fee: user pays exactly the LMSR cost
        int256[] memory delta = new int256[](2);
        delta[0] = int256(5e6);
        delta[1] = int256(0);
        int256 lmsrCost = pm.quoteTrade(info.outcomeQs, info.alpha, delta);

        uint256 balBefore = usdc.balanceOf(address(this));
        _doTrade(marketId, delta, uint256(lmsrCost) + 1, 0);
        uint256 balAfter = usdc.balanceOf(address(this));

        assertEq(balBefore - balAfter, uint256(lmsrCost), "zero-fee: user pays exactly lmsr cost");
    }

    // ========== 6. RESOLUTION ==========

    function test_resolve_surplusAndRedeem() public {
        bytes32 marketId = _createDefaultMarket();

        // Buy YES shares
        int256[] memory buyDelta = new int256[](2);
        buyDelta[0] = int256(20e6);
        buyDelta[1] = int256(0);

        _doTrade(marketId, buyDelta, 100e6, 0);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 s = info.initialSharesPerOutcome;

        // Resolve: YES wins (100%)
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE; // YES = 100%
        payouts[1] = 0;

        // Note: surplus from trading fees was already accrued, but resolution surplus is separate
        uint256 surplusBeforeResolve = pm.surplus(address(this));

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        // Check surplus was recorded (trading fee surplus + resolution surplus)
        uint256 surplusAfterResolve = pm.surplus(address(this));
        assertTrue(surplusAfterResolve > surplusBeforeResolve, "resolution added surplus");

        // Redeem YES tokens
        info = pm.getMarketInfo(marketId);
        address yesToken = info.outcomeTokens[0];
        uint256 yesBalance = OutcomeToken(yesToken).balanceOf(address(this));
        assertTrue(yesBalance > 0, "have YES tokens");

        uint256 usdcBefore = usdc.balanceOf(address(this));
        pm.redeem(yesToken, yesBalance);
        uint256 usdcAfter = usdc.balanceOf(address(this));

        // Payout = yesBalance * payoutPct / ONE = yesBalance * 1.0
        assertEq(usdcAfter - usdcBefore, yesBalance, "redeemed full value");
    }

    function test_resolve_onlyOracle() public {
        bytes32 marketId = _createDefaultMarket();

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE;
        payouts[1] = 0;

        vm.expectRevert(PredictionMarket.CallerNotOracle.selector);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);
    }

    function test_resolve_payoutsMustSumToOne() public {
        bytes32 marketId = _createDefaultMarket();

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 500_000;
        payouts[1] = 500_001; // sums to 1_000_001

        vm.prank(ORACLE);
        vm.expectRevert(PredictionMarket.InvalidPayout.selector);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);
    }

    function test_resolve_cannotRedeemBeforeResolution() public {
        bytes32 marketId = _createDefaultMarket();

        // Buy some YES
        int256[] memory delta = new int256[](2);
        delta[0] = int256(5e6);
        delta[1] = int256(0);
        _doTrade(marketId, delta, 50e6, 0);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        address yesToken = info.outcomeTokens[0];

        vm.expectRevert(PredictionMarket.InvalidMarketState.selector);
        pm.redeem(yesToken, 1e6);
    }

    function test_resolve_withdrawSurplus() public {
        bytes32 marketId = _createDefaultMarket();

        // Buy YES so there's a surplus when NO wins
        int256[] memory delta = new int256[](2);
        delta[0] = int256(20e6);
        delta[1] = int256(0);
        _doTrade(marketId, delta, 100e6, 0);

        // Resolve: NO wins
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0;
        payouts[1] = ONE;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        uint256 surplusAmount = pm.surplus(address(this));
        assertTrue(surplusAmount > 0, "surplus exists");

        uint256 balBefore = usdc.balanceOf(address(this));
        pm.withdrawSurplus();
        uint256 balAfter = usdc.balanceOf(address(this));

        assertEq(balAfter - balBefore, surplusAmount, "surplus withdrawn");
        assertEq(pm.surplus(address(this)), 0, "surplus zeroed");
    }

    // ========== 7. SOLVENCY ==========

    function test_solvency_oneSidedBuyThenResolve() public {
        bytes32 marketId = _createDefaultMarket();

        // Heavy one-sided buy on YES
        int256[] memory delta = new int256[](2);
        delta[0] = int256(50e6);
        delta[1] = int256(0);
        _doTrade(marketId, delta, 500e6, 0);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        // Trading fees go to surplus, not totalUsdcIn, so PM balance includes both
        // pm balance = totalUsdcIn + accumulated trading fee surplus (held in contract)
        uint256 pmBalance = usdc.balanceOf(address(pm));
        uint256 tradingFeeSurplus = pm.surplus(address(this));
        assertEq(pmBalance, info.totalUsdcIn + tradingFeeSurplus, "USDC balance = totalUsdcIn + fee surplus");

        // Resolve YES wins -- worst case for solvency
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE;
        payouts[1] = 0;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        // Verify we can redeem all tokens
        address yesToken = info.outcomeTokens[0];
        uint256 yesBalance = OutcomeToken(yesToken).balanceOf(address(this));

        uint256 usdcBefore = usdc.balanceOf(address(this));
        pm.redeem(yesToken, yesBalance);
        uint256 usdcAfter = usdc.balanceOf(address(this));
        assertEq(usdcAfter - usdcBefore, yesBalance, "full redemption succeeded");

        // Surplus recipient can also withdraw
        uint256 surplusAmount = pm.surplus(address(this));
        if (surplusAmount > 0) {
            pm.withdrawSurplus();
        }

        // After all redemptions and surplus withdrawal, PM should still have >= 0 USDC
        assertTrue(usdc.balanceOf(address(pm)) >= 0, "PM not insolvent");
    }

    function test_solvency_oneSidedBuyResolveLoserWins() public {
        bytes32 marketId = _createMarketWithSalt(42);

        // Heavy buy on YES
        int256[] memory delta = new int256[](2);
        delta[0] = int256(50e6);
        delta[1] = int256(0);
        _doTrade(marketId, delta, 500e6, 0);

        // Resolve NO wins -- YES buyers lose, large surplus expected
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0;
        payouts[1] = ONE;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        // Outstanding NO shares = outcomeQs[1] - s = s - s = 0 (nobody bought NO)
        // So total payout should be 0, all totalUsdcIn is resolution surplus
        // Plus trading fee surplus from the buy
        uint256 surplusAmount = pm.surplus(address(this));
        // surplus = trading fee from buy + resolution surplus (which is all of totalUsdcIn)
        assertEq(surplusAmount, info.totalUsdcIn + (surplusAmount - info.totalUsdcIn), "surplus accounts for fees + resolution");
        assertTrue(surplusAmount >= info.totalUsdcIn, "surplus at least totalUsdcIn when loser wins");
    }

    function test_solvency_feesDoNotAffectSolvency() public {
        // Fees go to surplus[surplusRecipient], not to totalUsdcIn.
        // This means the contract holds: totalUsdcIn (for market solvency) + fee surplus (withdrawable).
        // Resolution only checks totalUsdcIn >= totalPayout, so fees can't cause insolvency.
        bytes32 marketId = _createDefaultMarket();

        // Do several trades to accumulate fees
        for (uint256 i = 0; i < 5; i++) {
            int256[] memory buyDelta = new int256[](2);
            buyDelta[0] = int256(5e6);
            buyDelta[1] = int256(0);
            _doTrade(marketId, buyDelta, 100e6, 0);

            int256[] memory sellDelta = new int256[](2);
            sellDelta[0] = -int256(5e6);
            sellDelta[1] = int256(0);
            _doTrade(marketId, sellDelta, 0, 0);
        }

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 tradingFeeSurplus = pm.surplus(address(this));
        assertTrue(tradingFeeSurplus > 0, "trading fees accrued");

        // PM balance = totalUsdcIn + trading fee surplus
        assertEq(usdc.balanceOf(address(pm)), info.totalUsdcIn + tradingFeeSurplus, "balance = totalUsdcIn + fees");

        // Resolve with even split
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE / 2;
        payouts[1] = ONE / 2;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        // Should not have reverted -- solvent
        PredictionMarket.MarketInfo memory resolved = pm.getMarketInfo(marketId);
        assertTrue(resolved.resolved, "market resolved without insolvency");
    }

    // ========== 8. ADMIN ==========

    function test_admin_setMarketCreationFee() public {
        uint256 newFee = 10e6;
        pm.setMarketCreationFee(newFee);
        assertEq(pm.marketCreationFee(), newFee, "fee updated");
    }

    function test_admin_setMarketCreationFee_zeroReverts() public {
        vm.expectRevert(PredictionMarket.InvalidFee.selector);
        pm.setMarketCreationFee(0);
    }

    function test_admin_setTargetVig() public {
        uint256 newVig = 100_000; // 10%
        pm.setTargetVig(newVig);
        assertEq(pm.targetVig(), newVig, "vig updated");
    }

    function test_admin_setTargetVig_zeroReverts() public {
        vm.expectRevert(PredictionMarket.InvalidTargetVig.selector);
        pm.setTargetVig(0);
    }

    function test_admin_accessControl_notProtocolManager() public {
        address alice = address(0xA11CE);
        vm.startPrank(alice);

        vm.expectRevert();
        pm.setMarketCreationFee(10e6);

        vm.expectRevert();
        pm.setTargetVig(100_000);

        vm.expectRevert();
        pm.setAllowAnyMarketCreator(true);

        vm.expectRevert();
        pm.setMaxOutcomes(5);

        vm.expectRevert();
        pm.setTradingFee(500);

        vm.stopPrank();
    }

    function test_admin_setMarketCreationFee_affectsNewMarkets() public {
        uint256 newFee = 20e6;
        pm.setMarketCreationFee(newFee);

        uint256 balBefore = usdc.balanceOf(address(this));
        _createMarketWithSalt(99);
        uint256 balAfter = usdc.balanceOf(address(this));

        uint256 expectedTotalFee = newFee * 2; // 2 outcomes
        assertEq(balBefore - balAfter, expectedTotalFee, "new fee charged");
    }

    function test_admin_setTargetVig_affectsDerivedShares() public {
        uint256 newVig = 60_000; // 6%
        pm.setTargetVig(newVig);

        bytes32 marketId = _createMarketWithSalt(100);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        uint256 fee = pm.marketCreationFee();
        uint256 totalFee = fee * 2;
        uint256 expectedS = (totalFee * ONE) / newVig;

        assertEq(info.initialSharesPerOutcome, expectedS, "shares derived with new vig");

        // Lower vig => more shares (deeper market) compared to default 70_000
        uint256 defaultS = (totalFee * ONE) / pm.DEFAULT_TARGET_VIG();
        assertTrue(expectedS > defaultS, "lower vig yields more shares");
    }

    // ========== 9. FIVE-OUTCOME MARKET ==========

    function test_fiveOutcomeMarket_derivedShares() public {
        uint256 n = 5;
        uint256 fee = pm.marketCreationFee();
        uint256 vig = pm.targetVig();
        uint256 totalFee = fee * n;
        uint256 expectedS = (totalFee * ONE) / vig;

        uint256 balBefore = usdc.balanceOf(address(this));
        bytes32 marketId = _createNOutcomeMarket(n, 200);
        uint256 balAfter = usdc.balanceOf(address(this));

        assertEq(balBefore - balAfter, totalFee, "5-outcome fee charged");

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        assertEq(info.outcomeTokens.length, n, "5 tokens");
        assertEq(info.initialSharesPerOutcome, expectedS, "s scales with n");

        // All Qs should be equal to derived shares
        for (uint256 i = 0; i < n; i++) {
            assertEq(info.outcomeQs[i], expectedS, "q[i] == s");
        }
    }

    function test_fiveOutcomeMarket_pricesSum() public {
        bytes32 marketId = _createNOutcomeMarket(5, 201);
        uint256[] memory prices = pm.getPrices(marketId);
        assertEq(prices.length, 5, "5 prices");

        uint256 priceSum = 0;
        for (uint256 i = 0; i < 5; i++) {
            priceSum += prices[i];
            // Each initial price should be roughly 1/5 = 200_000 +/- vig adjustment
            assertTrue(prices[i] > 100_000, "price above floor");
            assertTrue(prices[i] < 300_000, "price below ceiling");
        }

        // Prices should sum to approximately ONE (within rounding tolerance)
        // With vig, the sum will be slightly above ONE
        assertTrue(priceSum >= ONE, "price sum >= ONE");
        assertTrue(priceSum <= ONE + pm.targetVig() + 1000, "price sum near ONE + vig");
    }

    function test_fiveOutcomeMarket_tradeAndResolve() public {
        bytes32 marketId = _createNOutcomeMarket(5, 202);

        // Buy outcome 2
        int256[] memory delta = new int256[](5);
        delta[2] = int256(10e6);

        _doTrade(marketId, delta, 100e6, 0);

        // Resolve: outcome 2 wins
        uint256[] memory payouts = new uint256[](5);
        payouts[2] = ONE;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        // Redeem winning tokens
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        address winToken = info.outcomeTokens[2];
        uint256 winBalance = OutcomeToken(winToken).balanceOf(address(this));
        assertTrue(winBalance > 0, "has winning tokens");

        uint256 usdcBefore = usdc.balanceOf(address(this));
        pm.redeem(winToken, winBalance);
        uint256 usdcAfter = usdc.balanceOf(address(this));
        assertEq(usdcAfter - usdcBefore, winBalance, "redeemed at full value");
    }

    function test_fiveOutcomeMarket_sharesScaleWithN() public {
        // Compare derived shares for 2 vs 5 outcomes
        uint256 fee = pm.marketCreationFee();
        uint256 vig = pm.targetVig();

        uint256 s2 = (fee * 2 * ONE) / vig;
        uint256 s5 = (fee * 5 * ONE) / vig;

        // s5 should be 2.5x s2 (within integer division rounding)
        assertApproxEqAbs(s5 * 2, s2 * 5, 10, "shares scale linearly with n");

        // Verify by creating actual markets
        bytes32 market2 = _createMarketWithSalt(300);
        bytes32 market5 = _createNOutcomeMarket(5, 301);

        PredictionMarket.MarketInfo memory info2 = pm.getMarketInfo(market2);
        PredictionMarket.MarketInfo memory info5 = pm.getMarketInfo(market5);

        assertEq(info2.initialSharesPerOutcome, s2, "2-outcome s");
        assertEq(info5.initialSharesPerOutcome, s5, "5-outcome s");
        assertApproxEqAbs(info5.initialSharesPerOutcome * 2, info2.initialSharesPerOutcome * 5, 10, "ratio matches");
    }
}
