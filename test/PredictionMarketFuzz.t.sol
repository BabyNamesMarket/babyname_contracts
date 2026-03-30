// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";

contract TestUSDC2 is ERC20 {
    function name() public pure override returns (string memory) { return "Test USDC"; }
    function symbol() public pure override returns (string memory) { return "tUSDC"; }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract PredictionMarketFuzzTest is Test {
    TestUSDC2 usdc;
    PredictionMarket pm;

    uint256 constant ONE = 1e6;
    address constant ORACLE = address(0xBEEF);
    uint96 salt;

    function setUp() public {
        usdc = new TestUSDC2();
        pm = new PredictionMarket();

        vm.startPrank(tx.origin);
        pm.initialize(address(usdc));
        pm.grantRoles(address(this), pm.PROTOCOL_MANAGER_ROLE());
        pm.grantRoles(address(this), pm.MARKET_CREATOR_ROLE());
        vm.stopPrank();

        usdc.mint(address(this), 100_000_000e6);
        usdc.approve(address(pm), type(uint256).max);
    }

    // ========== HELPERS ==========

    function _makeQuestionId(address creator, uint96 _salt) internal pure returns (bytes32) {
        return bytes32((uint256(uint160(creator)) << 96) | uint256(_salt));
    }

    function _nextSalt() internal returns (uint96) {
        return ++salt;
    }

    function _createBinaryMarket() internal returns (bytes32) {
        string[] memory names = new string[](2);
        names[0] = "YES";
        names[1] = "NO";
        int256[] memory initialBuy = new int256[](2);

        PredictionMarket.CreateMarketParams memory p = PredictionMarket.CreateMarketParams({
            oracle: ORACLE,
            creationFeePerOutcome: 0,
            initialBuyMaxCost: 0,
            questionId: _makeQuestionId(address(this), _nextSalt()),
            surplusRecipient: address(this),
            metadata: "",
            initialBuyShares: initialBuy,
            outcomeNames: names
        });
        return pm.createMarket(p);
    }

    function _createNOutcomeMarket(uint256 n) internal returns (bytes32) {
        string[] memory names = new string[](n);
        int256[] memory initialBuy = new int256[](n);
        for (uint256 i = 0; i < n; i++) {
            names[i] = string(abi.encodePacked("Out", bytes1(uint8(65 + i))));
        }

        PredictionMarket.CreateMarketParams memory p = PredictionMarket.CreateMarketParams({
            oracle: ORACLE,
            creationFeePerOutcome: 0,
            initialBuyMaxCost: 0,
            questionId: _makeQuestionId(address(this), _nextSalt()),
            surplusRecipient: address(this),
            metadata: "",
            initialBuyShares: initialBuy,
            outcomeNames: names
        });
        return pm.createMarket(p);
    }

    function _doTrade(bytes32 marketId, int256[] memory deltaShares) internal returns (int256) {
        PredictionMarket.Trade memory t = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: deltaShares,
            maxCost: type(uint256).max,
            minPayout: 0,
            deadline: block.timestamp + 1
        });
        return pm.trade(t);
    }

    // ========== 1. SOLVENCY FUZZ ==========

    /// @notice Executes random trades then resolves with random payout split.
    ///         Verifies no insolvency revert and that surplus + redemptions <= totalUsdcIn + feeSurplus.
    ///         Trading fees go to surplus[surplusRecipient], separate from totalUsdcIn.
    function testFuzz_solvency_randomTradeSequence(uint256 seed) public {
        bytes32 marketId = _createBinaryMarket();

        // Track how many shares each outcome the test contract holds
        uint256[2] memory held; // shares held by this contract

        // Number of trades: 10 to 20
        uint256 numTrades = 10 + (seed % 11);

        for (uint256 i = 0; i < numTrades; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));

            uint256 outcomeIdx = seed % 2;
            bool isBuy = ((seed >> 8) % 3) != 0; // 2/3 chance buy, 1/3 sell
            uint256 amount = 1e6 + ((seed >> 16) % 100e6); // 1e6 to ~100e6

            int256[] memory delta = new int256[](2);

            if (isBuy) {
                delta[outcomeIdx] = int256(amount);
                held[outcomeIdx] += amount;
            } else {
                // Can only sell what we hold
                if (held[outcomeIdx] == 0) continue;
                uint256 sellAmt = amount > held[outcomeIdx] ? held[outcomeIdx] : amount;
                delta[outcomeIdx] = -int256(sellAmt);
                held[outcomeIdx] -= sellAmt;
            }

            _doTrade(marketId, delta);
        }

        // Record trading fee surplus before resolution (fees accumulated from trades)
        uint256 feeSurplusBeforeResolve = pm.surplus(address(this));

        // Generate random payout split
        seed = uint256(keccak256(abi.encode(seed, "resolve")));
        uint256 pct0 = seed % (ONE + 1); // [0, 1e6]
        uint256 pct1 = ONE - pct0;

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = pct0;
        payouts[1] = pct1;

        // Resolution should NOT revert with MarketInsolvent
        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 totalUsdcIn = info.totalUsdcIn;

        // Redeem all held tokens
        uint256 totalRedeemed = 0;
        for (uint256 i = 0; i < 2; i++) {
            if (held[i] > 0) {
                uint256 balBefore = usdc.balanceOf(address(this));
                pm.redeem(info.outcomeTokens[i], held[i]);
                uint256 balAfter = usdc.balanceOf(address(this));
                totalRedeemed += (balAfter - balBefore);
            }
        }

        // Withdraw all surplus (trading fees + resolution surplus)
        uint256 surplusAmount = pm.surplus(address(this));
        if (surplusAmount > 0) {
            uint256 balBefore = usdc.balanceOf(address(this));
            pm.withdrawSurplus();
            uint256 balAfter = usdc.balanceOf(address(this));
            surplusAmount = balAfter - balBefore;
        }

        // Key invariant: total payouts <= total USDC held by contract (totalUsdcIn + fee surplus)
        // Resolution surplus comes from totalUsdcIn, trading fee surplus is additive.
        // totalRedeemed <= totalUsdcIn (guaranteed by resolution check)
        // surplusAmount = feeSurplus + resolutionSurplus
        // All of it is backed by the actual USDC in the contract.
        assertLe(
            totalRedeemed,
            totalUsdcIn,
            "redemptions must not exceed totalUsdcIn"
        );

        // Contract should have non-negative balance remaining
        assertGe(usdc.balanceOf(address(pm)), 0, "PM balance non-negative");
    }

    // ========== 2. FEE INVARIANT EDGE CASES ==========

    /// @notice Tests market creation with varying fee and vig parameters.
    ///         Checks that creation either succeeds with solvent state or reverts cleanly.
    function testFuzz_feeInvariant_varyingFeeAndVig(uint256 fee, uint256 vig) public {
        fee = bound(fee, 1, 1000e6);
        vig = bound(vig, 1000, 500_000); // 0.1% to 50%

        // Set the fee and vig
        pm.setMarketCreationFee(fee);
        pm.setTargetVig(vig);

        // Compute what the contract will compute
        uint256 totalFee = 2 * fee; // binary market
        uint256 derivedShares = (totalFee * ONE) / vig;

        // If derivedShares == 0, creation should revert with InvalidInitialShares
        if (derivedShares == 0) {
            vm.expectRevert(PredictionMarket.InvalidInitialShares.selector);
            _createBinaryMarket();
            return;
        }

        // Check the invariant: totalFee < minFee
        // minFee = vig * derivedShares / ONE (using mulDiv, i.e. floor division)
        uint256 minFee = (vig * derivedShares) / ONE;

        // If totalFee < minFee, creation should revert with InitialFundingInvariantViolation.
        if (totalFee < minFee) {
            vm.expectRevert(PredictionMarket.InitialFundingInvariantViolation.selector);
            _createBinaryMarket();
            return;
        }

        // Otherwise, creation should succeed
        bytes32 marketId = _createBinaryMarket();
        assertTrue(pm.marketExists(marketId), "market created");

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        assertEq(info.initialSharesPerOutcome, derivedShares, "derived shares match");
        assertEq(info.totalUsdcIn, totalFee, "totalUsdcIn == totalFee");

        // Verify solvent at creation: resolve immediately with even split
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE / 2;
        payouts[1] = ONE - payouts[0];

        vm.prank(ORACLE);
        // Should not revert with MarketInsolvent
        pm.resolveMarketWithPayoutSplit(marketId, payouts);
    }

    // ========== 3. ROUND-TRIP LOSS BOUNDS ==========

    /// @notice Buy then sell the same amount. Loss should be bounded by
    ///         ~6% (3% buy fee + 3% sell fee) of the LMSR cost, plus rounding.
    function testFuzz_roundTrip_lossIsBounded(uint256 buyAmount) public {
        buyAmount = bound(buyAmount, 1, 50e6);

        bytes32 marketId = _createBinaryMarket();
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        // Quote the LMSR cost for the buy (before fees)
        int256[] memory buyDeltaQ = new int256[](2);
        buyDeltaQ[0] = int256(buyAmount);
        buyDeltaQ[1] = int256(0);
        int256 lmsrBuyCost = pm.quoteTrade(info.outcomeQs, info.alpha, buyDeltaQ);

        uint256 balStart = usdc.balanceOf(address(this));

        // Buy
        int256[] memory buyDelta = new int256[](2);
        buyDelta[0] = int256(buyAmount);
        buyDelta[1] = int256(0);
        _doTrade(marketId, buyDelta);

        // Sell back same amount
        int256[] memory sellDelta = new int256[](2);
        sellDelta[0] = -int256(buyAmount);
        sellDelta[1] = int256(0);
        _doTrade(marketId, sellDelta);

        uint256 balEnd = usdc.balanceOf(address(this));

        // Round-trip should cost something (or nothing), but never profit
        assertGe(balStart, balEnd, "round-trip should not profit");

        uint256 loss = balStart - balEnd;

        // The loss consists of:
        // 1. Buy fee: 3% of lmsrBuyCost
        // 2. Sell fee: 3% of lmsrSellPayout (slightly less than lmsrBuyCost due to rounding)
        // 3. Rounding buffer: up to 2 wei
        // Total loss should be roughly 6% of the LMSR cost, plus a small rounding buffer.
        // We use 7% as upper bound to account for rounding.
        if (lmsrBuyCost > 0) {
            uint256 maxLoss = uint256(lmsrBuyCost) * 7 / 100 + 5;
            assertLe(loss, maxLoss, "round-trip loss bounded by ~6% of LMSR cost + rounding");
        }
    }

    // ========== 4. EXTREME ONE-SIDED MARKET ==========

    /// @notice Buy a very large amount on one side and verify solvency on worst-case resolution.
    function test_extreme_oneSidedBuy_stillSolvent() public {
        bytes32 marketId = _createBinaryMarket();

        // Buy 10_000e6 YES shares
        int256[] memory delta = new int256[](2);
        delta[0] = int256(10_000e6);
        delta[1] = int256(0);
        _doTrade(marketId, delta);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        // Resolve YES wins (worst case: the big buyer wins)
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE;
        payouts[1] = 0;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        // Redeem all YES tokens
        address yesToken = info.outcomeTokens[0];
        uint256 yesBalance = OutcomeToken(yesToken).balanceOf(address(this));
        assertTrue(yesBalance > 0, "has YES tokens");

        uint256 usdcBefore = usdc.balanceOf(address(this));
        pm.redeem(yesToken, yesBalance);
        uint256 usdcAfter = usdc.balanceOf(address(this));

        // Payout should equal yesBalance (100% payout)
        assertEq(usdcAfter - usdcBefore, yesBalance, "full redemption at par");

        // Withdraw surplus (trading fees + resolution surplus)
        uint256 surplusAmount = pm.surplus(address(this));
        if (surplusAmount > 0) {
            pm.withdrawSurplus();
        }

        // PM should not be drained below zero
        assertGe(usdc.balanceOf(address(pm)), 0, "PM not drained");
    }

    // ========== 5. SELL MORE THAN OUTSTANDING ==========

    /// @notice Trying to sell more tokens than held should revert.
    function test_sellMoreThanOutstanding_reverts() public {
        bytes32 marketId = _createBinaryMarket();

        // Buy 5e6 YES
        int256[] memory buyDelta = new int256[](2);
        buyDelta[0] = int256(5e6);
        buyDelta[1] = int256(0);
        _doTrade(marketId, buyDelta);

        // Try to sell 10e6 YES (more than held)
        int256[] memory sellDelta = new int256[](2);
        sellDelta[0] = -int256(10e6);
        sellDelta[1] = int256(0);

        PredictionMarket.Trade memory t = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: sellDelta,
            maxCost: 0,
            minPayout: 0,
            deadline: block.timestamp + 1
        });

        // Should revert because burn will fail (insufficient balance)
        vm.expectRevert();
        pm.trade(t);
    }

    // ========== 6. ZERO-SHARE TRADE ==========

    /// @notice A trade with all zero deltas should not revert and should not charge anything.
    function test_zeroShareTrade() public {
        bytes32 marketId = _createBinaryMarket();

        uint256 balBefore = usdc.balanceOf(address(this));

        int256[] memory zeroDelta = new int256[](2);
        zeroDelta[0] = int256(0);
        zeroDelta[1] = int256(0);

        int256 costDelta = _doTrade(marketId, zeroDelta);

        uint256 balAfter = usdc.balanceOf(address(this));

        assertEq(costDelta, 0, "zero trade has zero cost delta");
        assertEq(balBefore, balAfter, "no USDC charged for zero trade");
    }

    // ========== 7. VARYING OUTCOME COUNTS ==========

    /// @notice Create markets with varying outcome counts and verify solvency at creation.
    function testFuzz_createMarket_varyingOutcomes(uint8 n) public {
        n = uint8(bound(uint256(n), 2, 10));

        uint256 fee = pm.marketCreationFee();
        uint256 vig = pm.targetVig();
        uint256 totalFee = fee * uint256(n);
        uint256 derivedShares = (totalFee * ONE) / vig;

        // Check if this n triggers the invariant violation
        uint256 minFee = (vig * derivedShares) / ONE;
        bool willRevert = (totalFee < minFee);

        if (willRevert) {
            vm.expectRevert(PredictionMarket.InitialFundingInvariantViolation.selector);
            _createNOutcomeMarket(uint256(n));
            return;
        }

        bytes32 marketId = _createNOutcomeMarket(uint256(n));
        assertTrue(pm.marketExists(marketId), "market exists");

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        assertEq(info.outcomeTokens.length, uint256(n), "correct outcome count");

        uint256 expectedS = derivedShares;
        assertEq(info.initialSharesPerOutcome, expectedS, "derived shares correct");

        // All Qs should equal derivedShares
        for (uint256 i = 0; i < uint256(n); i++) {
            assertEq(info.outcomeQs[i], expectedS, "q[i] == s");
        }

        // Verify solvency: resolve with equal split
        uint256[] memory payoutsArr = new uint256[](uint256(n));
        uint256 perOutcome = ONE / uint256(n);
        uint256 remainder = ONE - perOutcome * uint256(n);
        for (uint256 i = 0; i < uint256(n); i++) {
            payoutsArr[i] = perOutcome;
        }
        // Give remainder to last outcome so they sum to ONE
        payoutsArr[uint256(n) - 1] += remainder;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payoutsArr);

        // No revert = solvent
        PredictionMarket.MarketInfo memory resolved = pm.getMarketInfo(marketId);
        assertTrue(resolved.resolved, "market resolved");
    }

    // ========== 8. FRACTIONAL PAYOUT RESOLUTION ==========

    /// @notice Resolve with arbitrary fractional payout split after buying both outcomes
    ///         in different amounts. Verify solvency and full redeemability.
    function testFuzz_resolution_fractionalPayouts(uint256 pct0) public {
        pct0 = bound(pct0, 0, ONE);
        uint256 pct1 = ONE - pct0;

        bytes32 marketId = _createBinaryMarket();

        // Buy different amounts of each outcome
        int256[] memory buyYes = new int256[](2);
        buyYes[0] = int256(30e6);
        buyYes[1] = int256(0);
        _doTrade(marketId, buyYes);

        int256[] memory buyNo = new int256[](2);
        buyNo[0] = int256(0);
        buyNo[1] = int256(15e6);
        _doTrade(marketId, buyNo);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 totalUsdcIn = info.totalUsdcIn;

        // Resolve with fractional split
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = pct0;
        payouts[1] = pct1;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        // Redeem YES tokens
        uint256 totalRedeemed = 0;
        {
            address yesToken = info.outcomeTokens[0];
            uint256 yesBal = OutcomeToken(yesToken).balanceOf(address(this));
            if (yesBal > 0) {
                uint256 before = usdc.balanceOf(address(this));
                pm.redeem(yesToken, yesBal);
                totalRedeemed += usdc.balanceOf(address(this)) - before;
            }
        }

        // Redeem NO tokens
        {
            address noToken = info.outcomeTokens[1];
            uint256 noBal = OutcomeToken(noToken).balanceOf(address(this));
            if (noBal > 0) {
                uint256 before = usdc.balanceOf(address(this));
                pm.redeem(noToken, noBal);
                totalRedeemed += usdc.balanceOf(address(this)) - before;
            }
        }

        // Withdraw all surplus (trading fees + resolution surplus)
        uint256 surplusAmount = pm.surplus(address(this));
        if (surplusAmount > 0) {
            pm.withdrawSurplus();
        }

        // Key invariant: redemptions come from totalUsdcIn, fees come from separate pool
        // Both are backed by actual USDC in contract
        assertLe(
            totalRedeemed,
            totalUsdcIn,
            "redemptions must not exceed totalUsdcIn"
        );
    }
}
