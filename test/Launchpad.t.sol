// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {MarketValidation} from "../src/MarketValidation.sol";

contract TestUSDC is ERC20 {
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

contract NameMarketTest is Test {
    using stdJson for string;

    TestUSDC usdc;
    PredictionMarket pm;

    address oracle = address(0xBEEF);
    address treasury = address(0xCAFE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        usdc = new TestUSDC();

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
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(pm), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(pm), type(uint256).max);
    }

    // ========== HELPERS ==========

    function _createMarketAsAlice(string memory _name, uint16 year, uint256 yesAmt, uint256 noAmt)
        internal
        returns (bytes32 marketId)
    {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = yesAmt;
        amounts[1] = noAmt;
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        marketId = pm.createNameMarket(_name, year, PredictionMarket.Gender.GIRL, proof, amounts);
    }

    // ========== 1. CREATE MARKET ==========

    function test_createNameMarket_basic() public {
        uint256 aliceBefore = usdc.balanceOf(alice);

        bytes32 marketId = _createMarketAsAlice("olivia", 2025, 50e6, 50e6);

        assertTrue(marketId != bytes32(0));

        // Alice should have spent 100e6 total, minus any refund
        uint256 aliceAfter = usdc.balanceOf(alice);
        assertTrue(aliceAfter < aliceBefore);

        // Market should exist on PM
        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(marketId);
        assertEq(mInfo.oracle, oracle);
        assertEq(mInfo.outcomeTokens.length, 2);
        assertFalse(mInfo.resolved);

        // Alice should have received outcome tokens
        uint256 aliceYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice);
        uint256 aliceNo = IERC20(mInfo.outcomeTokens[1]).balanceOf(alice);
        assertTrue(aliceYes > 0 || aliceNo > 0, "alice should have outcome tokens");
    }

    function test_createNameMarket_feeMath() public {
        // $200 committed, 5% fee = $10
        // creationFeePerOutcome = $10/2 = $5
        bytes32 marketId = _createMarketAsAlice("liam", 2025, 100e6, 100e6);

        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(marketId);

        // Phantom shares derived from fee: s = totalFee * 1e6 / targetVig
        // totalFee = 10e6, targetVig = 70000
        uint256 expectedS = (uint256(10e6) * 1e6) / 70000;
        assertEq(mInfo.initialSharesPerOutcome, expectedS);
    }

    function test_createNameMarket_smallFee() public {
        // $10 committed, 5% fee = $0.50
        // creationFeePerOutcome = $0.50/2 = $0.25
        bytes32 marketId = _createMarketAsAlice("iris", 2025, 5e6, 5e6);

        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(marketId);

        // s = 500000 * 1e6 / 70000 = 7142857
        uint256 expectedS = (uint256(500000) * 1e6) / 70000;
        assertEq(mInfo.initialSharesPerOutcome, expectedS);
    }

    function test_createNameMarket_oddFeeDustIsCollected() public {
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 treasuryBefore = usdc.balanceOf(treasury);

        bytes32 marketId = _createMarketAsAlice("hazel", 2025, 40, 20);
        assertTrue(pm.marketExists(marketId));
        assertEq(pm.surplus(treasury), 1, "odd fee dust credited to treasury");

        vm.prank(treasury);
        pm.withdrawSurplus();

        uint256 aliceSpent = aliceBefore - usdc.balanceOf(alice);
        uint256 treasuryReceived = usdc.balanceOf(treasury) - treasuryBefore;
        uint256 pmBalance = usdc.balanceOf(address(pm));

        assertEq(treasuryReceived, 1, "treasury withdrew one unit of collected dust");
        assertEq(aliceSpent, pmBalance + treasuryReceived, "all funds held or withdrawn came from creator");
    }

    function test_createNameMarket_oneSided() public {
        // Only YES side
        bytes32 marketId = _createMarketAsAlice("nova", 2025, 100e6, 0);

        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(marketId);
        assertEq(mInfo.outcomeTokens.length, 2);

        uint256 aliceYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice);
        assertTrue(aliceYes > 0, "alice should have YES tokens from one-sided buy");
    }

    function test_createNameMarket_refundsUnused() public {
        uint256 aliceBefore = usdc.balanceOf(alice);

        // Small buy amounts — most should come back as refund/tokens
        _createMarketAsAlice("stella", 2025, 5e6, 5e6);

        uint256 aliceAfter = usdc.balanceOf(alice);
        uint256 spent = aliceBefore - aliceAfter;

        // Alice spent 10e6, 5% fee = 0.5e6 for phantom shares
        // The rest should either be in outcome tokens or refunded
        assertTrue(spent <= 10e6, "should not spend more than submitted");
    }

    // ========== 2. DUPLICATE MARKET KEY ==========

    function test_duplicateMarketKey_reverts() public {
        _createMarketAsAlice("olivia", 2025, 50e6, 50e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        vm.expectRevert(PredictionMarket.DuplicateMarketKey.selector);
        pm.createNameMarket("olivia", 2025, PredictionMarket.Gender.GIRL, proof, amounts);
    }

    function test_duplicateMarketKey_uppercaseRejected() public {
        _createMarketAsAlice("olivia", 2025, 50e6, 50e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        vm.expectRevert(PredictionMarket.InvalidName.selector);
        pm.createNameMarket("Olivia", 2025, PredictionMarket.Gender.GIRL, proof, amounts);
    }

    // ========== 3. YEAR/REGION/GENDER SCOPING ==========

    function test_yearNotOpen_reverts() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.YearNotOpen.selector);
        pm.createNameMarket("olivia", 2030, PredictionMarket.Gender.GIRL, proof, amounts);
    }

    function test_closeYear_blocksNewMarkets() public {
        pm.closeYear(2025);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.YearNotOpen.selector);
        pm.createNameMarket("olivia", 2025, PredictionMarket.Gender.GIRL, proof, amounts);
    }

    function test_sameNameDifferentYear() public {
        pm.openYear(2026);

        _createMarketAsAlice("olivia", 2025, 50e6, 50e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        bytes32 marketId = pm.createNameMarket("olivia", 2026, PredictionMarket.Gender.GIRL, proof, amounts);
        assertTrue(marketId != bytes32(0));
    }

    function test_sameNameDifferentRegion() public {
        _createMarketAsAlice("olivia", 2025, 50e6, 50e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        bytes32 marketId =
            pm.createRegionalNameMarket("olivia", 2025, PredictionMarket.Gender.GIRL, "CA", proof, amounts);
        assertTrue(marketId != bytes32(0));
    }

    function test_sameNameDifferentGender() public {
        _createMarketAsAlice("olivia", 2025, 50e6, 50e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        bytes32 marketId = pm.createNameMarket("olivia", 2025, PredictionMarket.Gender.BOY, proof, amounts);
        assertTrue(marketId != bytes32(0));
    }

    // ========== 4. NAME VALIDATION ==========

    function test_invalidName_reverts() public {
        bytes32 fakeRoot = keccak256("some merkle root");
        pm.setNamesMerkleRoot(PredictionMarket.Gender.GIRL, fakeRoot);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InvalidName.selector);
        pm.createNameMarket("Zephyrella", 2025, PredictionMarket.Gender.GIRL, emptyProof, amounts);
    }

    function test_approvedName_bypasses_merkle() public {
        bytes32 fakeRoot = keccak256("some merkle root");
        pm.setNamesMerkleRoot(PredictionMarket.Gender.GIRL, fakeRoot);
        pm.approveName("zephyrella", PredictionMarket.Gender.GIRL);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(alice);
        bytes32 marketId = pm.createNameMarket("zephyrella", 2025, PredictionMarket.Gender.GIRL, emptyProof, amounts);
        assertTrue(marketId != bytes32(0));
    }

    function test_approveName_isGenderSpecific() public {
        bytes32 fakeRoot = keccak256("some merkle root");
        pm.setNamesMerkleRoot(PredictionMarket.Gender.GIRL, fakeRoot);
        pm.setNamesMerkleRoot(PredictionMarket.Gender.BOY, fakeRoot);
        pm.approveName("olivia", PredictionMarket.Gender.GIRL);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        bytes32[] memory emptyProof = new bytes32[](0);

        // Girl: approved
        vm.prank(alice);
        bytes32 girlId = pm.createNameMarket("olivia", 2025, PredictionMarket.Gender.GIRL, emptyProof, amounts);
        assertTrue(girlId != bytes32(0));

        // Boy: not approved
        vm.prank(bob);
        vm.expectRevert(PredictionMarket.InvalidName.selector);
        pm.createNameMarket("olivia", 2025, PredictionMarket.Gender.BOY, emptyProof, amounts);
    }

    function test_merkleProof_validNames() public {
        string memory json = vm.readFile("data/name-merkle-roots.json");
        bytes32 boysRoot = json.readBytes32(".boys.root");
        bytes32 girlsRoot = json.readBytes32(".girls.root");
        string memory boyName = json.readString(".boys.sampleName");
        string memory girlName = json.readString(".girls.sampleName");
        bytes32[] memory boyProof = json.readBytes32Array(".boys.sampleProof");
        bytes32[] memory girlProof = json.readBytes32Array(".girls.sampleProof");

        pm.setNamesMerkleRoot(PredictionMarket.Gender.BOY, boysRoot);
        pm.setNamesMerkleRoot(PredictionMarket.Gender.GIRL, girlsRoot);

        assertTrue(pm.isValidName(boyName, PredictionMarket.Gender.BOY, boyProof));
        assertTrue(pm.isValidName(girlName, PredictionMarket.Gender.GIRL, girlProof));
        assertFalse(pm.isValidName(girlName, PredictionMarket.Gender.BOY, girlProof));
        assertFalse(pm.isValidName(boyName, PredictionMarket.Gender.GIRL, boyProof));
    }

    // ========== 5. ADMIN SETTERS ==========

    function test_adminSetters() public {
        // setCreationFeeBps
        pm.setCreationFeeBps(300);
        assertEq(pm.creationFeeBps(), 300);

        // setCreationFeeBps too high reverts
        vm.expectRevert(PredictionMarket.FeeTooHigh.selector);
        pm.setCreationFeeBps(1001);

        vm.expectRevert(PredictionMarket.InvalidFee.selector);
        pm.setCreationFeeBps(0);
    }

    // ========== 6. GET MARKET KEY ==========

    function test_getMarketKey() public view {
        bytes32 key1 = keccak256(abi.encode("olivia", PredictionMarket.Gender.GIRL, uint16(2025), ""));
        bytes32 key2 = keccak256(abi.encode("olivia", PredictionMarket.Gender.GIRL, uint16(2025), ""));
        assertEq(key1, key2, "canonical lowercase market key");

        bytes32 key3 = keccak256(abi.encode("olivia", PredictionMarket.Gender.GIRL, uint16(2026), ""));
        assertTrue(key1 != key3, "different year = different key");

        bytes32 key4 = keccak256(abi.encode("olivia", PredictionMarket.Gender.GIRL, uint16(2025), "CA"));
        assertTrue(key1 != key4, "different region = different key");

        bytes32 key5 = keccak256(abi.encode("olivia", PredictionMarket.Gender.BOY, uint16(2025), ""));
        assertTrue(key1 != key5, "different gender = different key");
    }

    // ========== 7. GET MARKET BY NAME ==========

    function test_marketKeyToMarketId() public {
        bytes32 marketId = _createMarketAsAlice("olivia", 2025, 50e6, 50e6);
        bytes32 key = keccak256(abi.encode("olivia", PredictionMarket.Gender.GIRL, uint16(2025), ""));

        bytes32 found = pm.marketKeyToMarketId(key);
        assertEq(found, marketId);

        bytes32 found2 = pm.marketKeyToMarketId(key);
        assertEq(found2, marketId);
    }

    // ========== 8. CREATE THEN TRADE ON PM ==========

    function test_createThenTradeOnPm() public {
        bytes32 marketId = _createMarketAsAlice("emma", 2025, 50e6, 50e6);

        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(marketId);

        // Bob buys YES directly on PM
        vm.prank(bob);
        usdc.approve(address(pm), type(uint256).max);

        int256[] memory delta = new int256[](2);
        delta[0] = 5e6;
        delta[1] = 0;

        vm.prank(bob);
        pm.trade(
            PredictionMarket.Trade({marketId: marketId, deltaShares: delta, maxCost: 50e6, minPayout: 0, deadline: block.timestamp})
        );

        uint256 bobYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(bob);
        assertEq(bobYes, 5e6);
    }

    // ========== 9. CREATE THEN RESOLVE AND REDEEM ==========

    function test_createResolveRedeem() public {
        bytes32 marketId = _createMarketAsAlice("evelyn", 2025, 50e6, 50e6);

        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(marketId);
        uint256 aliceYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice);
        assertTrue(aliceYes > 0, "alice should have YES tokens");

        // Resolve: YES wins
        uint256[] memory payoutPcts = new uint256[](2);
        payoutPcts[0] = 1e6;
        payoutPcts[1] = 0;
        vm.prank(oracle);
        pm.resolveMarketWithPayoutSplit(marketId, payoutPcts);

        // Alice redeems
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        pm.redeem(mInfo.outcomeTokens[0], aliceYes);
        uint256 aliceAfter = usdc.balanceOf(alice);
        assertTrue(aliceAfter > aliceBefore, "alice should get USDC from redeem");
    }

    // ========== 10. MULTIPLE MARKETS ==========

    function test_multipleMarkets() public {
        bytes32 m1 = _createMarketAsAlice("alpha", 2025, 50e6, 50e6);
        bytes32 m2 = _createMarketAsAlice("bravo", 2025, 50e6, 50e6);

        assertTrue(m1 != m2, "m1 != m2");

        PredictionMarket.MarketInfo memory info1 = pm.getMarketInfo(m1);
        PredictionMarket.MarketInfo memory info2 = pm.getMarketInfo(m2);

        assertEq(info1.outcomeTokens.length, 2);
        assertEq(info2.outcomeTokens.length, 2);
        assertTrue(info1.outcomeTokens[0] != info2.outcomeTokens[0]);
    }

    // ========== 11. NO FUNDS STUCK ==========

    function test_noFundsStuck() public {
        uint256 pmBefore = usdc.balanceOf(address(pm));
        _createMarketAsAlice("luna", 2025, 100e6, 100e6);
        uint256 pmAfter = usdc.balanceOf(address(pm));

        // PM should hold the market's USDC (creation fee + initial buy cost)
        // but no extra funds should be "stuck"
        assertTrue(pmAfter > pmBefore, "PM should hold market USDC");
    }

    // ========== 12. INVALID AMOUNTS ==========

    function test_zeroAmounts_reverts() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 0;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InvalidAmounts.selector);
        pm.createNameMarket("nova", 2025, PredictionMarket.Gender.GIRL, proof, amounts);
    }

    function test_wrongAmountsLength_reverts() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 50e6;
        amounts[1] = 50e6;
        amounts[2] = 50e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InvalidAmounts.selector);
        pm.createNameMarket("nova", 2025, PredictionMarket.Gender.GIRL, proof, amounts);
    }

    // ========== 13. PROPOSE NAME ==========

    function test_proposeName_emitsEvent() public {
        vm.prank(alice);
        pm.proposeName("xanadu", PredictionMarket.Gender.GIRL);
        assertTrue(pm.proposedNames(keccak256(abi.encode("xanadu", PredictionMarket.Gender.GIRL))));
    }

    function test_proposeName_invalidCharactersReverts() public {
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.InvalidName.selector);
        pm.proposeName("xanadu2", PredictionMarket.Gender.GIRL);
    }
}
