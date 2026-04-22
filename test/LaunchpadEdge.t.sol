// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {MarketValidation} from "../src/MarketValidation.sol";

contract TestUSDC2 is ERC20 {
    function name() public pure override returns (string memory) {
        return "Test USDC";
    }

    function symbol() public pure override returns (string memory) {
        return "tUSDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract NameMarketEdgeTest is Test {
    TestUSDC2 usdc;
    PredictionMarket pm;

    address oracle = address(0xBEEF);
    address treasury = address(0xCAFE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        usdc = new TestUSDC2();

        vm.startPrank(address(this), address(this));
        PredictionMarket impl = new PredictionMarket();
        address proxy = address(
            new ERC1967Proxy(
                address(impl), abi.encodeCall(PredictionMarket.initialize, (address(usdc), address(0), address(this)))
            )
        );
        pm = PredictionMarket(proxy);
        MarketValidation validation = new MarketValidation(address(pm));
        pm.setValidation(address(validation));
        pm.grantRoles(address(this), pm.PROTOCOL_MANAGER_ROLE());
        vm.stopPrank();

        pm.seedDefaultRegions();
        pm.openYear(2025);
        pm.setDefaultOracle(oracle);
        pm.setDefaultSurplusRecipient(treasury);

        // Fund users
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);

        vm.prank(alice);
        usdc.approve(address(pm), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(pm), type(uint256).max);
    }

    // ========== HELPERS ==========

    function _createAs(address user, string memory _name, uint16 year, uint256 yesAmt, uint256 noAmt)
        internal
        returns (bytes32 marketId)
    {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = yesAmt;
        amounts[1] = noAmt;
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(user);
        marketId = pm.createNameMarket(_name, year, PredictionMarket.Gender.GIRL, proof, amounts);
    }

    // ========== 1. LARGE MARKET — PHANTOM SHARES ==========

    function test_largeMarket_phantomShares() public {
        bytes32 marketId = _createAs(alice, "bigfee", 2025, 500e6, 500e6);

        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(marketId);

        // $1000 committed, 5% fee = $50
        // creationFeePerOutcome = $50/2 = $25
        // s = 50e6 * 1e6 / 70000
        uint256 expectedS = (uint256(50e6) * 1e6) / 70000;
        assertEq(mInfo.initialSharesPerOutcome, expectedS);
    }

    // ========== 2. SMALL MARKET ==========

    function test_smallMarket_works() public {
        bytes32 marketId = _createAs(alice, "tiny", 2025, 1e6, 0);

        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(marketId);
        assertEq(mInfo.outcomeTokens.length, 2);

        uint256 aliceYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice);
        assertTrue(aliceYes > 0, "small market should still produce tokens");
    }

    // ========== 3. EXTREME ASYMMETRY ==========

    function test_extremeAsymmetry() public {
        // 19:1 ratio YES:NO
        bytes32 marketId = _createAs(alice, "skewed", 2025, 19e6, 1e6);

        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(marketId);

        uint256 aliceYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice);
        uint256 aliceNo = IERC20(mInfo.outcomeTokens[1]).balanceOf(alice);

        console2.log("=== EXTREME ASYMMETRY (19:1) ===");
        console2.log("Alice YES shares:", aliceYes);
        console2.log("Alice NO shares: ", aliceNo);

        assertTrue(aliceYes > 0, "YES shares should be > 0");
    }

    // ========== 4. MULTIPLE MARKETS ISOLATION ==========

    function test_multipleMarkets_noFundLeakage() public {
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        bytes32 m1 = _createAs(alice, "alpha", 2025, 100e6, 100e6);
        bytes32 m2 = _createAs(bob, "bravo", 2025, 100e6, 100e6);

        assertTrue(m1 != m2);

        // Each user spent independently
        uint256 aliceSpent = aliceBefore - usdc.balanceOf(alice);
        uint256 bobSpent = bobBefore - usdc.balanceOf(bob);
        assertTrue(aliceSpent > 0 && aliceSpent <= 200e6);
        assertTrue(bobSpent > 0 && bobSpent <= 200e6);
    }

    // ========== 5. REGION VALIDATION ==========

    function test_invalidRegion_reverts() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InvalidRegion.selector);
        pm.createRegionalNameMarket("olivia", 2025, PredictionMarket.Gender.GIRL, "ZZ", proof, amounts);
    }

    function test_validRegion_succeeds() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        bytes32 marketId =
            pm.createRegionalNameMarket("olivia", 2025, PredictionMarket.Gender.GIRL, "CA", proof, amounts);
        assertTrue(marketId != bytes32(0));
    }

    // ========== 6. NON-OWNER CANNOT SET ADMIN ==========

    function test_nonOwner_cannotSetFee() public {
        vm.prank(alice);
        vm.expectRevert();
        pm.setCreationFeeBps(300);
    }

    function test_nonOwner_cannotOpenYear() public {
        vm.prank(alice);
        vm.expectRevert();
        pm.openYear(2026);
    }

    // ========== 7. TRADE AFTER CREATE ==========

    function test_directPmTrade_afterCreate() public {
        bytes32 marketId = _createAs(alice, "harper", 2025, 50e6, 50e6);

        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(marketId);

        // Bob trades directly on PM
        vm.prank(bob);
        usdc.approve(address(pm), type(uint256).max);

        int256[] memory delta = new int256[](2);
        delta[0] = 10e6;
        delta[1] = 0;

        vm.prank(bob);
        pm.trade(
            PredictionMarket.Trade({
                marketId: marketId,
                deltaShares: delta,
                maxCost: 50e6,
                minPayout: 0,
                deadline: block.timestamp
            })
        );

        assertEq(IERC20(mInfo.outcomeTokens[0]).balanceOf(bob), 10e6);
    }
}
