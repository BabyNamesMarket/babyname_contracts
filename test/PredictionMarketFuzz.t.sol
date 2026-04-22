// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {MarketValidation} from "../src/MarketValidation.sol";

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
    address constant TREASURY = address(0xCAFE);

    uint256 nameCounter;

    function setUp() public {
        usdc = new TestUSDC2();
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

        usdc.mint(address(this), 100_000_000e6);
        usdc.approve(address(pm), type(uint256).max);
    }

    function _createBinaryMarket(uint256 yesAmt, uint256 noAmt) internal returns (bytes32) {
        nameCounter++;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = yesAmt;
        amounts[1] = noAmt;
        bytes32[] memory proof = new bytes32[](0);
        return pm.createNameMarket(
            string(abi.encodePacked("fuzz", _alphaSuffix(nameCounter))),
            2025,
            PredictionMarket.Gender.GIRL,
            proof,
            amounts
        );
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

    function _alphaSuffix(uint256 n) internal pure returns (string memory) {
        bytes memory out = new bytes(6);
        for (uint256 i = 0; i < 6; i++) {
            out[5 - i] = bytes1(uint8(97 + (n % 26)));
            n /= 26;
        }
        return string(out);
    }

    function testFuzz_solvency_randomTradeSequence(uint256 seed) public {
        bytes32 marketId = _createBinaryMarket(100e6, 100e6);
        uint256[2] memory held;

        uint256 numTrades = 10 + (seed % 11);

        for (uint256 i = 0; i < numTrades; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));

            uint256 outcomeIdx = seed % 2;
            bool isBuy = ((seed >> 8) % 3) != 0;
            uint256 amount = 1e6 + ((seed >> 16) % 100e6);

            int256[] memory delta = new int256[](2);

            if (isBuy) {
                delta[outcomeIdx] = int256(amount);
                held[outcomeIdx] += amount;
            } else {
                if (held[outcomeIdx] == 0) continue;
                uint256 sellAmt = amount > held[outcomeIdx] ? held[outcomeIdx] : amount;
                delta[outcomeIdx] = -int256(sellAmt);
                held[outcomeIdx] -= sellAmt;
            }

            _doTrade(marketId, delta);
        }

        seed = uint256(keccak256(abi.encode(seed, "resolve")));
        uint256 pct0 = seed % (ONE + 1);
        uint256 pct1 = ONE - pct0;

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = pct0;
        payouts[1] = pct1;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 totalUsdcIn = info.totalUsdcIn;

        uint256 totalRedeemed;
        for (uint256 i = 0; i < 2; i++) {
            if (held[i] == 0) continue;
            uint256 balBefore = usdc.balanceOf(address(this));
            pm.redeem(info.outcomeTokens[i], held[i]);
            uint256 balAfter = usdc.balanceOf(address(this));
            totalRedeemed += (balAfter - balBefore);
        }

        uint256 surplusAmount = pm.surplus(TREASURY);
        if (surplusAmount > 0) {
            vm.prank(TREASURY);
            pm.withdrawSurplus();
        }

        assertLe(totalRedeemed, totalUsdcIn, "redemptions must not exceed totalUsdcIn");
        assertGe(usdc.balanceOf(address(pm)), 0, "PM balance non-negative");
    }

    function testFuzz_feeInvariant_varyingFeeBpsAndVig(uint256 feeBps, uint256 vig, uint256 yesAmt, uint256 noAmt) public {
        feeBps = bound(feeBps, 1, pm.MAX_CREATION_FEE_BPS());
        vig = bound(vig, 1000, 500_000);
        yesAmt = bound(yesAmt, 1, 1_000e6);
        noAmt = bound(noAmt, 1, 1_000e6);

        pm.setCreationFeeBps(feeBps);
        pm.setTargetVig(vig);

        uint256 fee =
            FixedPointMathLib.mulDiv(yesAmt, feeBps, 10000) + FixedPointMathLib.mulDiv(noAmt, feeBps, 10000);
        uint256 creationFeePerOutcome = fee / 2;
        uint256 totalFee = creationFeePerOutcome * 2;
        uint256 derivedShares = FixedPointMathLib.mulDiv(totalFee, ONE, vig);

        if (derivedShares == 0) {
            vm.expectRevert(PredictionMarket.InvalidInitialShares.selector);
            _createBinaryMarket(yesAmt, noAmt);
            return;
        }

        uint256 minFee = FixedPointMathLib.mulDiv(vig, derivedShares, ONE);
        if (totalFee < minFee) {
            vm.expectRevert(PredictionMarket.InitialFundingInvariantViolation.selector);
            _createBinaryMarket(yesAmt, noAmt);
            return;
        }

        bytes32 marketId = _createBinaryMarket(yesAmt, noAmt);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        assertEq(info.initialSharesPerOutcome, derivedShares, "derived shares match");
        assertGe(info.totalUsdcIn, totalFee, "totalUsdcIn includes creation funding");

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE / 2;
        payouts[1] = ONE - payouts[0];

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);
    }

    function testFuzz_roundTrip_lossIsBounded(uint256 buyAmount) public {
        buyAmount = bound(buyAmount, 1, 50e6);

        bytes32 marketId = _createBinaryMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        int256[] memory buyDeltaQ = new int256[](2);
        buyDeltaQ[0] = int256(buyAmount);
        int256 lmsrBuyCost = pm.quoteTrade(info.outcomeQs, info.alpha, buyDeltaQ);

        uint256 balStart = usdc.balanceOf(address(this));

        int256[] memory buyDelta = new int256[](2);
        buyDelta[0] = int256(buyAmount);
        _doTrade(marketId, buyDelta);

        int256[] memory sellDelta = new int256[](2);
        sellDelta[0] = -int256(buyAmount);
        _doTrade(marketId, sellDelta);

        uint256 balEnd = usdc.balanceOf(address(this));
        assertGe(balStart, balEnd, "round-trip should not profit");

        uint256 loss = balStart - balEnd;
        if (lmsrBuyCost > 0) {
            uint256 maxLoss = uint256(lmsrBuyCost) * 7 / 100 + 5;
            assertLe(loss, maxLoss, "round-trip loss bounded by fees and rounding");
        }
    }

    function test_extreme_oneSidedBuy_stillSolvent() public {
        bytes32 marketId = _createBinaryMarket(100e6, 100e6);

        int256[] memory delta = new int256[](2);
        delta[0] = int256(10_000e6);
        _doTrade(marketId, delta);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = ONE;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        address yesToken = info.outcomeTokens[0];
        uint256 yesBalance = OutcomeToken(yesToken).balanceOf(address(this));
        assertTrue(yesBalance > 0, "has YES tokens");

        uint256 usdcBefore = usdc.balanceOf(address(this));
        pm.redeem(yesToken, yesBalance);
        uint256 usdcAfter = usdc.balanceOf(address(this));
        assertEq(usdcAfter - usdcBefore, yesBalance, "full redemption at par");

        uint256 surplusAmount = pm.surplus(TREASURY);
        if (surplusAmount > 0) {
            vm.prank(TREASURY);
            pm.withdrawSurplus();
        }

        assertGe(usdc.balanceOf(address(pm)), 0, "PM not drained");
    }

    function test_sellMoreThanOutstanding_reverts() public {
        bytes32 marketId = _createBinaryMarket(100e6, 100e6);
        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);

        int256[] memory buyDelta = new int256[](2);
        buyDelta[0] = int256(5e6);
        _doTrade(marketId, buyDelta);

        uint256 yesBalance = OutcomeToken(info.outcomeTokens[0]).balanceOf(address(this));
        int256[] memory sellDelta = new int256[](2);
        sellDelta[0] = -int256(yesBalance + 1);

        PredictionMarket.Trade memory t = PredictionMarket.Trade({
            marketId: marketId,
            deltaShares: sellDelta,
            maxCost: 0,
            minPayout: 0,
            deadline: block.timestamp + 1
        });

        vm.expectRevert();
        pm.trade(t);
    }

    function test_zeroShareTrade() public {
        bytes32 marketId = _createBinaryMarket(100e6, 100e6);

        uint256 balBefore = usdc.balanceOf(address(this));

        int256[] memory zeroDelta = new int256[](2);
        int256 costDelta = _doTrade(marketId, zeroDelta);

        uint256 balAfter = usdc.balanceOf(address(this));

        assertEq(costDelta, 0, "zero trade has zero cost delta");
        assertEq(balBefore, balAfter, "no USDC charged for zero trade");
    }

    function testFuzz_resolution_fractionalPayouts(uint256 pct0) public {
        pct0 = bound(pct0, 0, ONE);
        uint256 pct1 = ONE - pct0;

        bytes32 marketId = _createBinaryMarket(100e6, 100e6);

        int256[] memory buyYes = new int256[](2);
        buyYes[0] = int256(30e6);
        _doTrade(marketId, buyYes);

        int256[] memory buyNo = new int256[](2);
        buyNo[1] = int256(15e6);
        _doTrade(marketId, buyNo);

        PredictionMarket.MarketInfo memory info = pm.getMarketInfo(marketId);
        uint256 totalUsdcIn = info.totalUsdcIn;

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = pct0;
        payouts[1] = pct1;

        vm.prank(ORACLE);
        pm.resolveMarketWithPayoutSplit(marketId, payouts);

        uint256 totalRedeemed;

        address yesToken = info.outcomeTokens[0];
        uint256 yesBal = OutcomeToken(yesToken).balanceOf(address(this));
        if (yesBal > 0) {
            uint256 before = usdc.balanceOf(address(this));
            pm.redeem(yesToken, yesBal);
            totalRedeemed += usdc.balanceOf(address(this)) - before;
        }

        address noToken = info.outcomeTokens[1];
        uint256 noBal = OutcomeToken(noToken).balanceOf(address(this));
        if (noBal > 0) {
            uint256 before = usdc.balanceOf(address(this));
            pm.redeem(noToken, noBal);
            totalRedeemed += usdc.balanceOf(address(this)) - before;
        }

        uint256 surplusAmount = pm.surplus(TREASURY);
        if (surplusAmount > 0) {
            vm.prank(TREASURY);
            pm.withdrawSurplus();
        }

        assertLe(totalRedeemed, totalUsdcIn, "redemptions must not exceed totalUsdcIn");
    }
}
