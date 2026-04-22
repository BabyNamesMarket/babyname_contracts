// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketValidation} from "../src/MarketValidation.sol";

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
    address constant TREASURY = address(0xCAFE);

    uint256 nameCounter;

    function setUp() public {
        usdc = new TestUSDC();
        PredictionMarket impl = new PredictionMarket();
        address proxy = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(PredictionMarket.initialize, (address(usdc), address(0), address(this)))
            )
        );
        pm = PredictionMarket(proxy);
        MarketValidation validation = new MarketValidation(address(pm));

        vm.startPrank(address(this));
        pm.setValidation(address(validation));
        pm.grantRoles(address(this), pm.PROTOCOL_MANAGER_ROLE());
        vm.stopPrank();

        pm.setDefaultOracle(ORACLE);
        pm.setDefaultSurplusRecipient(TREASURY);
        pm.seedDefaultRegions();
        pm.openYear(2025);

        usdc.mint(address(this), 1_000_000e6);
        usdc.approve(address(pm), type(uint256).max);
    }

    // ========== HELPERS ==========

    /// @dev Creates a name market with a unique name each time. Returns marketId.
    function _createMarket(uint256 yesAmt, uint256 noAmt) internal returns (bytes32) {
        nameCounter++;
        string memory name = string(abi.encodePacked("name", _alphaSuffix(nameCounter)));
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = yesAmt;
        amounts[1] = noAmt;
        bytes32[] memory proof = new bytes32[](0);
        return pm.createNameMarket(name, 2025, PredictionMarket.Gender.GIRL, proof, amounts);
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

    function _alphaSuffix(uint256 n) internal pure returns (string memory) {
        bytes memory out = new bytes(6);
        for (uint256 i = 0; i < 6; i++) {
            out[5 - i] = bytes1(uint8(97 + (n % 26)));
            n /= 26;
        }
        return string(out);
    }

    function _validation() internal view returns (MarketValidation) {
        return pm.validation();
    }

    // ========== 1. MARKET CREATION ==========

    function test_createMarket_derivedShares() public {
        uint256 gross = 200e6; // 100 per side
        uint256 feeBps = pm.creationFeeBps(); // 500 = 5%
        uint256 fee = FixedPointMathLib.mulDiv(gross, feeBps, 10000);
        uint256 creationFeePerOutcome = fee / 2;
        uint256 totalFee = creationFeePerOutcome * 2;
        uint256 vig = pm.targetVig();
        uint256 expectedS = (totalFee * ONE) / vig;

        bytes32 marketId = _createMarket(100e6, 100e6);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        assertEq(info.initialSharesPerOutcome, expectedS, "derived s");
        assertEq(info.outcomeQs.length, 2, "2 outcomes");
        assertTrue(info.outcomeQs[0] > expectedS, "q[0] increased from creator buy");
        assertTrue(info.outcomeQs[1] > expectedS, "q[1] increased from creator buy");
    }

    function test_createMarket_alpha() public {
        bytes32 marketId = _createMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 expectedAlpha = pm.calculateAlpha(2, pm.targetVig());
        assertEq(info.alpha, expectedAlpha, "alpha matches");
    }

    function test_createMarket_outcomeTokensDeployed() public {
        bytes32 marketId = _createMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        assertEq(info.outcomeTokens.length, 2, "2 tokens");

        assertTrue(info.outcomeTokens[0] != address(0), "token0 deployed");
        assertTrue(info.outcomeTokens[1] != address(0), "token1 deployed");
        assertEq(OutcomeToken(info.outcomeTokens[0]).symbol(), "YES");
        assertEq(OutcomeToken(info.outcomeTokens[1]).symbol(), "NO");
    }

    function test_createMarket_duplicateQuestionId() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);
        pm.createNameMarket("uniquetest", 2025, PredictionMarket.Gender.GIRL, proof, amounts);

        vm.expectRevert(PredictionMarket.DuplicateMarketKey.selector);
        pm.createNameMarket("uniquetest", 2025, PredictionMarket.Gender.GIRL, proof, amounts);
    }

    // ========== 2. FEE INVARIANT ==========

    function test_feeInvariant_solventAtCreation() public {
        bytes32 marketId = _createMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        uint256 totalFee = info.totalUsdcIn;
        uint256 s = info.initialSharesPerOutcome;
        uint256 vig = pm.targetVig();

        uint256 minFee = (vig * s) / ONE;
        assertTrue(totalFee >= minFee, "fee covers minFee");
    }

    // ========== 3. TRADING ==========

    function test_trade_buyYes_priceMovesUp() public {
        bytes32 marketId = _createMarket(100e6, 100e6);
        uint256[] memory pricesBefore = pm.getPrices(marketId);

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
        assertTrue(pricesAfter[0] > pricesBefore[0], "YES price went up");
        assertTrue(pricesAfter[1] < pricesBefore[1], "NO price went down");
    }

    function test_trade_sellBack_roundTrip() public {
        bytes32 marketId = _createMarket(100e6, 100e6);
        uint256 balStart = usdc.balanceOf(address(this));

        int256[] memory buyDelta = new int256[](2);
        buyDelta[0] = int256(5e6);
        buyDelta[1] = int256(0);
        _doTrade(marketId, buyDelta, 50e6, 0);

        int256[] memory sellDelta = new int256[](2);
        sellDelta[0] = -int256(5e6);
        sellDelta[1] = int256(0);
        _doTrade(marketId, sellDelta, 0, 0);

        uint256 balEnd = usdc.balanceOf(address(this));
        uint256 loss = balStart - balEnd;
        assertTrue(loss > 0, "round-trip has non-zero loss from fees");
        assertTrue(loss < 1e6, "round-trip loss is bounded");
    }

    function test_trade_expired() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(1e6);

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
        bytes32 marketId = _createMarket(100e6, 100e6);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(100e6);

        PredictionMarket.Trade memory t = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: delta,
            maxCost: 1,
            minPayout: 0,
            deadline: block.timestamp + 1
        });

        vm.expectRevert(PredictionMarket.InsufficientInputAmount.selector);
        pm.trade(t);
    }

    function test_trade_tinyBuyCannotMintForFree() public {
        bytes32 marketId = _createMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(1);

        int256 quotedCost = pm.quoteTrade(info.outcomeQs, info.alpha, delta);
        assertEq(quotedCost, 1, "tiny buy must cost at least one unit");

        uint256 balanceBefore = usdc.balanceOf(address(this));
        uint256 tokenBefore = OutcomeToken(info.outcomeTokens[0]).balanceOf(address(this));

        _doTrade(marketId, delta, 1, 0);

        uint256 balanceAfter = usdc.balanceOf(address(this));
        uint256 tokenAfter = OutcomeToken(info.outcomeTokens[0]).balanceOf(address(this));

        assertEq(balanceBefore - balanceAfter, 1, "tiny buy charged one unit");
        assertEq(tokenAfter - tokenBefore, 1, "tiny buy still mints one token unit");
    }

    // ========== 4. TRADING FEES ==========

    function test_tradingFee_buyChargesFee() public {
        bytes32 marketId = _createMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(10e6);
        delta[1] = int256(0);
        int256 lmsrCost = pm.quoteTrade(info.outcomeQs, info.alpha, delta);
        assertTrue(lmsrCost > 0, "buy has positive cost");

        uint256 expectedFee = FixedPointMathLib.mulDiv(uint256(lmsrCost), 300, 10000 - 300);
        uint256 expectedUserPays = uint256(lmsrCost) + expectedFee;

        uint256 balBefore = usdc.balanceOf(address(this));
        uint256 surplusBefore = pm.surplus(TREASURY);

        _doTrade(marketId, delta, expectedUserPays + 1, 0);

        uint256 balAfter = usdc.balanceOf(address(this));
        uint256 surplusAfter = pm.surplus(TREASURY);

        assertEq(balBefore - balAfter, expectedUserPays, "user pays lmsr + fee");
        assertEq(surplusAfter - surplusBefore, expectedFee, "fee goes to surplus");

        PredictionMarket.MarketInfo memory infoAfter = pm.getMarketInfo(marketId);
        assertEq(infoAfter.totalUsdcIn, info.totalUsdcIn + uint256(lmsrCost), "totalUsdcIn excludes fee");
    }

    function test_tradingFee_sellChargesFee() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        int256[] memory buyDelta = new int256[](2);
        buyDelta[0] = int256(10e6);
        _doTrade(marketId, buyDelta, 100e6, 0);

        PredictionMarket.MarketInfo memory infoBeforeSell = pm.getMarketInfo(marketId);

        int256[] memory sellDelta = new int256[](2);
        sellDelta[0] = -int256(10e6);
        int256 lmsrCostDelta = pm.quoteTrade(infoBeforeSell.outcomeQs, infoBeforeSell.alpha, sellDelta);
        assertTrue(lmsrCostDelta < 0, "sell has negative cost (payout)");

        uint256 lmsrPayout = uint256(-lmsrCostDelta);
        uint256 expectedFee = lmsrPayout * 300 / 10000;
        uint256 expectedUserReceives = lmsrPayout - expectedFee;

        uint256 balBefore = usdc.balanceOf(address(this));
        uint256 surplusBefore = pm.surplus(TREASURY);

        _doTrade(marketId, sellDelta, 0, 0);

        uint256 balAfter = usdc.balanceOf(address(this));
        uint256 surplusAfter = pm.surplus(TREASURY);

        assertEq(balAfter - balBefore, expectedUserReceives, "user receives lmsr payout minus fee");
        assertEq(surplusAfter - surplusBefore, expectedFee, "sell fee goes to surplus");
    }

    function test_tradingFee_adminCanChange() public {
        assertEq(pm.tradingFeeBps(), 300, "default fee is 300 bps");

        bytes32 marketId = _createMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        pm.setTradingFee(500);
        assertEq(pm.tradingFeeBps(), 500, "fee updated to 500 bps");

        int256[] memory delta = new int256[](2);
        delta[0] = int256(10e6);
        int256 lmsrCost = pm.quoteTrade(info.outcomeQs, info.alpha, delta);
        uint256 expectedFee = FixedPointMathLib.mulDiv(uint256(lmsrCost), 500, 10000 - 500);
        uint256 expectedUserPays = uint256(lmsrCost) + expectedFee;

        uint256 balBefore = usdc.balanceOf(address(this));
        _doTrade(marketId, delta, expectedUserPays + 1, 0);
        uint256 balAfter = usdc.balanceOf(address(this));

        assertEq(balBefore - balAfter, expectedUserPays, "5% fee applied after change");
    }

    function test_tradingFee_perMarketOverride() public {
        bytes32 marketId = _createMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        pm.setMarketTradingFee(marketId, 100);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(10e6);
        int256 lmsrCost = pm.quoteTrade(info.outcomeQs, info.alpha, delta);
        uint256 expectedFee = FixedPointMathLib.mulDiv(uint256(lmsrCost), 100, 10000 - 100);
        uint256 expectedUserPays = uint256(lmsrCost) + expectedFee;

        uint256 balBefore = usdc.balanceOf(address(this));
        _doTrade(marketId, delta, expectedUserPays + 1, 0);
        uint256 balAfter = usdc.balanceOf(address(this));

        assertEq(balBefore - balAfter, expectedUserPays, "1% per-market fee applied");
    }

    function test_tradingFee_maxCapEnforced() public {
        pm.setTradingFee(1000);
        assertEq(pm.tradingFeeBps(), 1000, "10% max allowed");

        vm.expectRevert(PredictionMarket.InvalidTradingFee.selector);
        pm.setTradingFee(1001);

        bytes32 marketId = _createMarket(100e6, 100e6);
        vm.expectRevert(PredictionMarket.InvalidTradingFee.selector);
        pm.setMarketTradingFee(marketId, 1001);
    }

    function test_tradingFee_zeroFeeAllowed() public {
        pm.setTradingFee(0);

        bytes32 marketId = _createMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(5e6);
        int256 lmsrCost = pm.quoteTrade(info.outcomeQs, info.alpha, delta);

        uint256 balBefore = usdc.balanceOf(address(this));
        _doTrade(marketId, delta, uint256(lmsrCost) + 1, 0);
        uint256 balAfter = usdc.balanceOf(address(this));

        assertEq(balBefore - balAfter, uint256(lmsrCost), "zero-fee: user pays exactly lmsr cost");
    }

    function test_tradingFee_perMarketZeroOverrideAllowed() public {
        bytes32 marketId = _createMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        pm.setTradingFee(300);
        pm.setMarketTradingFee(marketId, 0);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(5e6);
        int256 lmsrCost = pm.quoteTrade(info.outcomeQs, info.alpha, delta);

        uint256 balBefore = usdc.balanceOf(address(this));
        _doTrade(marketId, delta, uint256(lmsrCost) + 1, 0);
        uint256 balAfter = usdc.balanceOf(address(this));

        assertEq(balBefore - balAfter, uint256(lmsrCost), "market override to zero fee should bypass global fee");
        assertEq(pm.marketTradingFeeBps(marketId), 0, "explicit zero override stored");
        assertTrue(pm.marketTradingFeeOverrideSet(marketId), "override flag set");
    }

    function test_buyExactIn_spendsUpToGrossAndChargesFeeInsideBudget() public {
        bytes32 marketId = _createMarket(100e6, 0);
        (uint256 quotedShares,, uint256 quotedFee, uint256 totalCharge) = pm.quoteBuyExactIn(marketId, 0, 100e6);

        uint256 balBefore = usdc.balanceOf(address(this));
        uint256 surplusBefore = pm.surplus(TREASURY);

        uint256 sharesBought = pm.buyExactIn(marketId, 0, 100e6, quotedShares, block.timestamp + 1);

        uint256 balAfter = usdc.balanceOf(address(this));
        uint256 surplusAfter = pm.surplus(TREASURY);

        assertEq(sharesBought, quotedShares, "shares match quote");
        assertEq(balBefore - balAfter, totalCharge, "charged quoted total only");
        assertEq(surplusAfter - surplusBefore, quotedFee, "fee credited to surplus");
        assertLe(totalCharge, 100e6, "never charges more than requested gross input");
    }

    function test_buyOrCreateExactIn_createsMarketWhenMissing() public {
        bytes32[] memory proof = new bytes32[](0);
        uint256 balanceBefore = usdc.balanceOf(address(this));

        vm.recordLogs();
        (bytes32 marketId, uint256 sharesBought) = pm.buyOrCreateExactIn(
            "unifiedbuy", 2025, PredictionMarket.Gender.GIRL, "", proof, 0, 100e6, 1, block.timestamp + 1
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertTrue(pm.marketExists(marketId), "market should exist");

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 tokenBalance = OutcomeToken(info.outcomeTokens[0]).balanceOf(address(this));

        assertEq(sharesBought, tokenBalance, "returned shares should match minted YES balance");
        assertEq(balanceBefore - usdc.balanceOf(address(this)), 100e6, "creation path should charge exact gross amount");

        bytes32 marketCreatedSig =
            keccak256("MarketCreated(bytes32,address,bytes32,address,address,bytes,uint256,uint256,address[],string[],uint256[])");
        bytes32 nameMarketCreatedSig =
            keccak256("NameMarketCreated(bytes32,bytes32,string,uint8,uint16,string,address,uint256)");
        bytes32 marketTradedSig = keccak256("MarketTraded(bytes32,address,uint256,int256,uint256,int256[],uint256[])");

        uint256 marketCreatedIndex = type(uint256).max;
        uint256 nameMarketCreatedIndex = type(uint256).max;
        uint256 marketTradedIndex = type(uint256).max;

        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == marketCreatedSig) marketCreatedIndex = i;
            if (entries[i].topics[0] == nameMarketCreatedSig) nameMarketCreatedIndex = i;
            if (entries[i].topics[0] == marketTradedSig) marketTradedIndex = i;
        }

        assertLt(marketCreatedIndex, nameMarketCreatedIndex, "MarketCreated should precede NameMarketCreated");
        assertLt(nameMarketCreatedIndex, marketTradedIndex, "initial buy MarketTraded should be last");

        Vm.Log memory tradedLog = entries[marketTradedIndex];
        assertEq(tradedLog.topics[1], marketId, "trade event marketId");
        assertEq(address(uint160(uint256(tradedLog.topics[2]))), address(this), "trade event trader");

        (uint256 alpha, int256 usdcFlow, uint256 fee, int256[] memory deltaShares, uint256[] memory outcomeQs) =
            abi.decode(tradedLog.data, (uint256, int256, uint256, int256[], uint256[]));

        assertEq(alpha, info.alpha, "trade event alpha");
        assertEq(usdcFlow, int256(100e6), "trade event flow matches gross input");
        assertEq(fee, 0, "creation path charges no trading fee");
        assertEq(deltaShares.length, 2, "trade delta length");
        assertEq(deltaShares[0], int256(sharesBought), "trade delta on bought outcome");
        assertEq(deltaShares[1], 0, "trade delta on untouched outcome");
        assertEq(outcomeQs.length, info.outcomeQs.length, "trade q length");
        assertEq(outcomeQs[0], info.outcomeQs[0], "trade q[0]");
        assertEq(outcomeQs[1], info.outcomeQs[1], "trade q[1]");
    }

    function test_buyOrCreateExactIn_buysExistingMarket() public {
        bytes32[] memory proof = new bytes32[](0);
        (bytes32 marketId,) = pm.buyOrCreateExactIn(
            "existingbuy", 2025, PredictionMarket.Gender.GIRL, "", proof, 0, 100e6, 1, block.timestamp + 1
        );

        PredictionMarket.MarketInfo memory infoBefore = pm.getMarketInfo(marketId);
        uint256 tokenBalanceBefore = OutcomeToken(infoBefore.outcomeTokens[0]).balanceOf(address(this));
        (uint256 quotedShares,,,) = pm.quoteBuyExactIn(marketId, 0, 25e6);

        vm.recordLogs();
        (bytes32 returnedMarketId, uint256 sharesBought) = pm.buyOrCreateExactIn(
            "existingbuy", 2025, PredictionMarket.Gender.GIRL, "", proof, 0, 25e6, quotedShares, block.timestamp + 1
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(returnedMarketId, marketId, "should target existing market");
        assertEq(sharesBought, quotedShares, "existing-market branch should match quote");

        PredictionMarket.MarketInfo memory infoAfter = pm.getMarketInfo(marketId);
        uint256 tokenBalanceAfter = OutcomeToken(infoAfter.outcomeTokens[0]).balanceOf(address(this));
        assertEq(tokenBalanceAfter - tokenBalanceBefore, quotedShares, "should mint quoted shares on existing market");

        bytes32 marketTradedSig = keccak256("MarketTraded(bytes32,address,uint256,int256,uint256,int256[],uint256[])");
        uint256 tradedCount;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == marketTradedSig) tradedCount++;
        }
        assertEq(tradedCount, 1, "existing-market branch should emit one MarketTraded");
    }

    // ========== 5. RESOLUTION ==========

    function test_resolve_surplusAndRedeem() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        int256[] memory buyDelta = new int256[](2);
        buyDelta[0] = int256(20e6);
        _doTrade(marketId, buyDelta, 100e6, 0);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE;
        payouts[1] = 0;

        uint256 surplusBeforeResolve = pm.surplus(TREASURY);

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        uint256 surplusAfterResolve = pm.surplus(TREASURY);
        assertTrue(surplusAfterResolve > surplusBeforeResolve, "resolution added surplus");

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        address yesToken = info.outcomeTokens[0];
        uint256 yesBalance = OutcomeToken(yesToken).balanceOf(address(this));
        assertTrue(yesBalance > 0, "have YES tokens");

        uint256 usdcBefore = usdc.balanceOf(address(this));
        pm.redeem(yesToken, yesBalance);
        uint256 usdcAfter = usdc.balanceOf(address(this));
        assertEq(usdcAfter - usdcBefore, yesBalance, "redeemed full value");
    }

    function test_resolve_onlyOracle() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE;
        payouts[1] = 0;

        vm.expectRevert(PredictionMarket.CallerNotOracle.selector);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);
    }

    function test_resolve_payoutsMustSumToOne() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 500_000;
        payouts[1] = 500_001;

        vm.prank(ORACLE);
        vm.expectRevert(PredictionMarket.InvalidPayout.selector);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);
    }

    function test_resolve_cannotRedeemBeforeResolution() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(5e6);
        _doTrade(marketId, delta, 50e6, 0);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        vm.expectRevert(PredictionMarket.InvalidMarketState.selector);
        pm.redeem(info.outcomeTokens[0], 1e6);
    }

    function test_resolve_withdrawSurplus() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(20e6);
        _doTrade(marketId, delta, 100e6, 0);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 0;
        payouts[1] = ONE;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        uint256 surplusAmount = pm.surplus(TREASURY);
        assertTrue(surplusAmount > 0, "surplus exists");

        uint256 balBefore = usdc.balanceOf(TREASURY);
        vm.prank(TREASURY);
        pm.withdrawSurplus();
        uint256 balAfter = usdc.balanceOf(TREASURY);

        assertEq(balAfter - balBefore, surplusAmount, "surplus withdrawn");
        assertEq(pm.surplus(TREASURY), 0, "surplus zeroed");
    }

    // ========== 6. SOLVENCY ==========

    function test_solvency_oneSidedBuyThenResolve() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(50e6);
        _doTrade(marketId, delta, 500e6, 0);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE;
        payouts[1] = 0;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        address yesToken = info.outcomeTokens[0];
        uint256 yesBalance = OutcomeToken(yesToken).balanceOf(address(this));

        uint256 usdcBefore = usdc.balanceOf(address(this));
        pm.redeem(yesToken, yesBalance);
        uint256 usdcAfter = usdc.balanceOf(address(this));
        assertEq(usdcAfter - usdcBefore, yesBalance, "full redemption succeeded");
    }

    function test_solvency_feesDoNotAffectSolvency() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        for (uint256 i = 0; i < 5; i++) {
            int256[] memory buyDelta = new int256[](2);
            buyDelta[0] = int256(5e6);
            _doTrade(marketId, buyDelta, 100e6, 0);

            int256[] memory sellDelta = new int256[](2);
            sellDelta[0] = -int256(5e6);
            _doTrade(marketId, sellDelta, 0, 0);
        }

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE / 2;
        payouts[1] = ONE / 2;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        PredictionMarket.MarketInfo memory resolved = pm.getMarketInfo(marketId);
        assertTrue(resolved.resolved, "market resolved without insolvency");
    }

    // ========== 7. ADMIN ==========

    function test_admin_setTargetVig() public {
        uint256 newVig = 100_000;
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
        pm.setTargetVig(100_000);

        vm.expectRevert();
        pm.setTradingFee(500);

        vm.expectRevert();
        pm.setGlobalPaused(true);

        vm.stopPrank();
    }

    function test_admin_setTargetVig_affectsDerivedShares() public {
        uint256 newVig = 60_000;
        pm.setTargetVig(newVig);

        bytes32 marketId = _createMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        // With newVig, derivedShares should be larger (deeper market)
        uint256 gross = 200e6;
        uint256 fee = FixedPointMathLib.mulDiv(gross, pm.creationFeeBps(), 10000);
        uint256 creationFeePerOutcome = fee / 2;
        uint256 totalFee = creationFeePerOutcome * 2;
        uint256 expectedS = (totalFee * ONE) / newVig;

        assertEq(info.initialSharesPerOutcome, expectedS, "shares derived with new vig");
    }

    // ========== 8. GLOBAL PAUSE ==========

    function test_globalPause_blocksCreateMarket() public {
        pm.setGlobalPaused(true);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert(PredictionMarket.GlobalPaused.selector);
        pm.createNameMarket("pausedtest", 2025, PredictionMarket.Gender.GIRL, proof, amounts);
    }

    function test_globalPause_blocksTrade() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        pm.setGlobalPaused(true);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(5e6);

        vm.expectRevert(PredictionMarket.GlobalPaused.selector);
        _doTrade(marketId, delta, 50e6, 0);
    }

    function test_globalPause_doesNotBlockRedeem() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(5e6);
        _doTrade(marketId, delta, 50e6, 0);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE;
        payouts[1] = 0;
        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        pm.setGlobalPaused(true);

        // Redeem should still work even when globally paused
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 yesBalance = OutcomeToken(info.outcomeTokens[0]).balanceOf(address(this));
        assertTrue(yesBalance > 0, "have tokens to redeem");

        uint256 usdcBefore = usdc.balanceOf(address(this));
        pm.redeem(info.outcomeTokens[0], yesBalance);
        uint256 usdcAfter = usdc.balanceOf(address(this));
        assertTrue(usdcAfter > usdcBefore, "redeemed during pause");
    }

    function test_globalPause_unpauseRestoresFunction() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        pm.setGlobalPaused(true);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(5e6);
        vm.expectRevert(PredictionMarket.GlobalPaused.selector);
        _doTrade(marketId, delta, 50e6, 0);

        pm.setGlobalPaused(false);
        _doTrade(marketId, delta, 50e6, 0);
    }

    function test_globalPause_resolutionStillWorks() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(5e6);
        _doTrade(marketId, delta, 50e6, 0);

        pm.setGlobalPaused(true);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE;
        payouts[1] = 0;
        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        assertTrue(info.resolved);
    }

    function test_globalPause_nonAdminCannotSet() public {
        address alice = address(0xA11CE);
        vm.prank(alice);
        vm.expectRevert();
        pm.setGlobalPaused(true);
    }

    // ========== 9. PROTOCOL_MANAGER CAN PAUSE MARKETS ==========

    function test_protocolManager_canPauseMarket() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        pm.pauseMarket(marketId);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        assertTrue(info.paused);
    }

    function test_protocolManager_canUnpauseMarket() public {
        bytes32 marketId = _createMarket(100e6, 100e6);

        pm.pauseMarket(marketId);
        pm.unpauseMarket(marketId);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        assertFalse(info.paused);
    }

    // ========== 10. UUPS UPGRADE ==========

    function test_uups_proxyDeploy() public {
        PredictionMarket impl = new PredictionMarket();
        address proxy = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(PredictionMarket.initialize, (address(usdc), address(0), address(this)))
            )
        );
        PredictionMarket pmProxy = PredictionMarket(proxy);
        MarketValidation validation = new MarketValidation(address(pmProxy));
        pmProxy.setValidation(address(validation));
        pmProxy.grantRoles(address(this), pmProxy.PROTOCOL_MANAGER_ROLE());
        pmProxy.setDefaultOracle(ORACLE);
        pmProxy.setDefaultSurplusRecipient(TREASURY);
        pmProxy.openYear(2025);

        usdc.approve(proxy, type(uint256).max);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        bytes32 marketId = pmProxy.createNameMarket("proxytest", 2025, PredictionMarket.Gender.GIRL, proof, amounts);
        assertTrue(pmProxy.marketExists(marketId));
    }

    function test_uups_upgradeToNewImpl() public {
        PredictionMarket impl = new PredictionMarket();
        address proxy = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(PredictionMarket.initialize, (address(usdc), address(0), address(this)))
            )
        );
        PredictionMarket pmProxy = PredictionMarket(proxy);
        MarketValidation validation = new MarketValidation(address(pmProxy));
        pmProxy.setValidation(address(validation));
        pmProxy.grantRoles(address(this), pmProxy.PROTOCOL_MANAGER_ROLE());
        pmProxy.setDefaultOracle(ORACLE);
        pmProxy.setDefaultSurplusRecipient(TREASURY);
        pmProxy.openYear(2025);

        usdc.approve(proxy, type(uint256).max);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        bytes32 marketId = pmProxy.createNameMarket("upgradetest", 2025, PredictionMarket.Gender.GIRL, proof, amounts);

        PredictionMarket impl2 = new PredictionMarket();
        pmProxy.upgradeToAndCall(address(impl2), "");

        assertTrue(pmProxy.marketExists(marketId), "market still exists after upgrade");
        assertEq(address(pmProxy.usdc()), address(usdc), "usdc preserved");
    }

    function test_uups_nonOwnerCannotUpgrade() public {
        PredictionMarket impl = new PredictionMarket();
        address proxy = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(PredictionMarket.initialize, (address(usdc), address(0), address(this)))
            )
        );
        PredictionMarket pmProxy = PredictionMarket(proxy);
        MarketValidation validation = new MarketValidation(address(pmProxy));
        pmProxy.setValidation(address(validation));

        PredictionMarket impl2 = new PredictionMarket();

        address alice = address(0xA11CE);
        vm.prank(alice);
        vm.expectRevert();
        pmProxy.upgradeToAndCall(address(impl2), "");
    }

    function test_initialize_invalidUsdcReverts() public {
        PredictionMarket impl = new PredictionMarket();
        vm.expectRevert(PredictionMarket.InvalidUsdc.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(PredictionMarket.initialize, (address(0), address(1), address(this))));
    }

    function test_initialize_invalidValidationReverts() public {
        PredictionMarket impl = new PredictionMarket();
        address proxy = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(PredictionMarket.initialize, (address(usdc), address(0), address(this)))
            )
        );
        PredictionMarket pmProxy = PredictionMarket(proxy);
        vm.expectRevert(PredictionMarket.InvalidValidation.selector);
        pmProxy.setValidation(address(0));
    }

    function test_initialize_constructorLocksImplementation() public {
        PredictionMarket bad = new PredictionMarket();
        vm.expectRevert();
        bad.initialize(address(usdc), address(0), address(this));
    }

    function test_validation_canOnlyBeSetOnce() public {
        MarketValidation validation = new MarketValidation(address(pm));
        vm.expectRevert(PredictionMarket.ValidationAlreadySet.selector);
        pm.setValidation(address(validation));
    }

    function test_createMarket_invalidCharactersRevert() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert(PredictionMarket.InvalidName.selector);
        pm.createNameMarket("anna-marie", 2025, PredictionMarket.Gender.GIRL, proof, amounts);
    }

    function test_regionValidation_enforcesStateListAndRemoval() public {
        assertTrue(_validation().isValidRegion("CA"));
        assertFalse(_validation().isValidRegion("ZZ"));

        pm.removeRegion("CA");
        assertFalse(_validation().isValidRegion("CA"));

        pm.addRegion("CA");
        assertTrue(_validation().isValidRegion("CA"));
    }
}
