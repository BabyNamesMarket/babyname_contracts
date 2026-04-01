// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

contract TestUSDC is ERC20 {
    function name() public pure override returns (string memory) { return "Test USDC"; }
    function symbol() public pure override returns (string memory) { return "tUSDC"; }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract LaunchpadTest is Test {
    using stdJson for string;

    TestUSDC usdc;
    PredictionMarket pm;
    Launchpad launchpad;

    address oracle = address(0xBEEF);
    address treasury = address(0xCAFE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        usdc = new TestUSDC();

        vm.startPrank(address(this), address(this));
        pm = new PredictionMarket();
        pm.initialize(address(usdc));
        pm.grantRoles(address(this), pm.PROTOCOL_MANAGER_ROLE());
        vm.stopPrank();

        launchpad = new Launchpad(
            address(pm),
            treasury,         // surplusRecipient
            oracle,           // defaultOracle
            7 days,           // defaultDeadlineDuration
            address(this)     // owner
        );

        pm.grantMarketCreatorRole(address(launchpad));

        launchpad.seedDefaultRegions();
        launchpad.openYear(2025);

        // Fund users
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(launchpad), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(launchpad), type(uint256).max);
    }

    // ========== HELPERS ==========

    function _proposeAsAlice(string memory _name, uint16 year, uint256 yesAmt, uint256 noAmt)
        internal
        returns (bytes32 proposalId)
    {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = yesAmt;
        amounts[1] = noAmt;
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(alice);
        proposalId = launchpad.propose(_name, year, Launchpad.Gender.GIRL, proof, amounts);
    }

    function _commitAsBob(bytes32 proposalId, uint256 yesAmt, uint256 noAmt) internal {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = yesAmt;
        amounts[1] = noAmt;
        vm.prank(bob);
        launchpad.commit(proposalId, amounts);
    }

    function _warpToLaunch(bytes32 proposalId) internal {
        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        vm.warp(info.launchTs);
    }

    // ========== 1. PROPOSE ==========

    function test_propose_createsProposalAndCommits() public {
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 launchpadBefore = usdc.balanceOf(address(launchpad));

        bytes32 proposalId = _proposeAsAlice("Olivia", 2025, 5e6, 5e6);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(info.outcomeNames.length, 2);
        assertEq(info.outcomeNames[0], "YES");
        assertEq(info.outcomeNames[1], "NO");
        assertEq(uint256(info.state), uint256(Launchpad.ProposalState.OPEN));
        assertEq(info.totalCommitted, 10e6); // GROSS amount stored
        // totalPerOutcome stores NET amounts (after 5% fee)
        // 5e6 * 500 / 10000 = 250000 fee per outcome, net = 4750000
        assertEq(info.totalPerOutcome[0], 4750000); // NET per outcome
        assertEq(info.totalPerOutcome[1], 4750000);
        assertEq(info.totalFeesCollected, 500000); // 10e6 * 500 / 10000 = 500000
        assertEq(info.oracle, oracle);
        assertEq(info.name, "olivia"); // lowercased
        assertEq(info.year, 2025);
        assertEq(info.committers.length, 1);
        assertEq(info.committers[0], alice);

        // Check committed amounts for alice (NET per outcome)
        uint256[] memory committed = launchpad.getCommitted(proposalId, alice);
        assertEq(committed[0], 4750000); // NET: 5e6 - 250000
        assertEq(committed[1], 4750000);

        // USDC transferred from alice to launchpad (GROSS amount)
        assertEq(usdc.balanceOf(alice), aliceBefore - 10e6);
        assertEq(usdc.balanceOf(address(launchpad)), launchpadBefore + 10e6);
    }

    // ========== 2. COMMIT ==========

    function test_commit_multipleUsersAccumulate() public {
        bytes32 proposalId = _proposeAsAlice("Emma", 2025, 5e6, 5e6);

        // Bob commits
        _commitAsBob(proposalId, 3e6, 7e6);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(info.totalCommitted, 20e6); // 10 alice + 10 bob (GROSS)
        // totalPerOutcome is NET: (5e6 + 3e6) * 9500/10000, (5e6 + 7e6) * 9500/10000
        // Each amount has 5% fee removed: net = amount * 9500 / 10000
        // Alice: 5e6 -> 4750000, Bob: 3e6 -> 2850000, total YES = 7600000
        // Alice: 5e6 -> 4750000, Bob: 7e6 -> 6650000, total NO = 11400000
        assertEq(info.totalPerOutcome[0], 7600000); // NET: 4750000 + 2850000
        assertEq(info.totalPerOutcome[1], 11400000); // NET: 4750000 + 6650000
        assertEq(info.committers.length, 2);

        // Alice commits again
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2e6;
        amounts[1] = 0;
        vm.prank(alice);
        launchpad.commit(proposalId, amounts);

        info = launchpad.getProposal(proposalId);
        assertEq(info.totalCommitted, 22e6);
        // NET YES: 7600000 + 1900000 (2e6 * 9500/10000) = 9500000
        assertEq(info.totalPerOutcome[0], 9500000);
        assertEq(info.committers.length, 2); // alice not duplicated
    }

    // ========== 3. LAUNCH MARKET — FEE MATH ==========

    function test_launchMarket_feeMath() public {
        // Total $200 committed
        // 5% fee = $10 total fees
        // maxCreationFee = $10, so all goes to phantom shares, $0 excess
        bytes32 proposalId = _proposeAsAlice("Liam", 2025, 100e6, 0);
        _commitAsBob(proposalId, 0, 100e6);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        _warpToLaunch(proposalId);
        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(uint256(info.state), uint256(Launchpad.ProposalState.LAUNCHED));
        assertTrue(info.marketId != bytes32(0));

        // Fee math: $200 * 5% = $10. maxCreationFee = $10.
        // creationFeePerOutcome = $10 / 2 = $5
        // excessFees = $10 - $10 = $0
        uint256 treasuryAfter = usdc.balanceOf(treasury);
        assertEq(treasuryAfter - treasuryBefore, 0, "No excess fees should go to treasury");

        // Market should exist on PM
        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(info.marketId);
        assertEq(mInfo.oracle, oracle);
        assertEq(mInfo.outcomeTokens.length, 2);
        assertFalse(mInfo.resolved);
    }

    // ========== 4. LAUNCH — POST-BATCH THRESHOLD TRIGGER ==========

    function test_launchMarket_postBatchUsesScheduledLaunchTime() public {
        bytes32 proposalId = _proposeAsAlice("Noah", 2025, 6e6, 5e6);

        vm.expectRevert(Launchpad.NotEligibleForLaunch.selector);
        launchpad.launchMarket(proposalId);

        _warpToLaunch(proposalId);
        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(uint256(info.state), uint256(Launchpad.ProposalState.LAUNCHED));
    }

    // ========== 5. LAUNCH — POST-BATCH TIMEOUT TRIGGER ==========

    function test_launchMarket_postBatchTimeoutTrigger() public {
        bytes32 proposalId = _proposeAsAlice("Ava", 2025, 1e6, 0);

        vm.expectRevert(Launchpad.NotEligibleForLaunch.selector);
        launchpad.launchMarket(proposalId);

        _warpToLaunch(proposalId);
        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(uint256(info.state), uint256(Launchpad.ProposalState.LAUNCHED));
    }

    // ========== 6. LAUNCH — PRE-BATCH DATE ==========

    function test_launchMarket_preBatchDate() public {
        // Set batch launch date to 10 days from now
        uint256 batchDate = block.timestamp + 10 days;
        launchpad.setYearLaunchDate(2025, batchDate);

        bytes32 proposalId = _proposeAsAlice("Mia", 2025, 100e6, 100e6);

        // Can't launch before batch date (even though net > threshold)
        vm.expectRevert(Launchpad.NotEligibleForLaunch.selector);
        launchpad.launchMarket(proposalId);

        // Warp to batch date
        vm.warp(batchDate);

        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(uint256(info.state), uint256(Launchpad.ProposalState.LAUNCHED));
    }

    // ========== 7. CLAIM SHARES ==========

    function test_claimShares_proportionalToGrossCommitted() public {
        // Alice: 60 YES, 40 NO = 100 gross
        // Bob: 40 YES, 60 NO = 100 gross
        bytes32 proposalId = _proposeAsAlice("Harper", 2025, 60e6, 40e6);
        _commitAsBob(proposalId, 40e6, 60e6);

        // Total: YES=100e6, NO=100e6, gross=200e6
        // net = 200 * 0.95 = 190
        _warpToLaunch(proposalId);
        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(info.marketId);

        vm.prank(alice);
        launchpad.claimShares(proposalId);
        vm.prank(bob);
        launchpad.claimShares(proposalId);

        uint256 aliceYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice);
        uint256 bobYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(bob);
        uint256 aliceNo = IERC20(mInfo.outcomeTokens[1]).balanceOf(alice);
        uint256 bobNo = IERC20(mInfo.outcomeTokens[1]).balanceOf(bob);

        // Alice committed 60% of YES, Bob committed 40% of YES
        // So aliceYes / bobYes should be ~3:2
        if (bobYes > 0) {
            assertApproxEqAbs(aliceYes * 2, bobYes * 3, 1, "YES share ratio should be 3:2");
        }

        // Alice committed 40% of NO, Bob committed 60% of NO
        if (aliceNo > 0) {
            assertApproxEqAbs(aliceNo * 3, bobNo * 2, 1, "NO share ratio should be 2:3");
        }
    }

    // ========== 8. CLAIM REFUND ==========

    function test_claimRefund_afterLaunchUnspentRefundable() public {
        bytes32 proposalId = _proposeAsAlice("Evelyn", 2025, 50e6, 50e6);
        _commitAsBob(proposalId, 50e6, 50e6);

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 bobBefore = usdc.balanceOf(bob);

        _warpToLaunch(proposalId);
        launchpad.launchMarket(proposalId);

        vm.prank(alice);
        launchpad.claimShares(proposalId);
        vm.prank(bob);
        launchpad.claimShares(proposalId);

        uint256 aliceRefund = launchpad.pendingRefunds(alice);
        uint256 bobRefund = launchpad.pendingRefunds(bob);

        // Both committed equally, so refunds should be equal
        assertEq(aliceRefund, bobRefund);

        if (aliceRefund > 0) {
            vm.prank(alice);
            launchpad.claimRefund();
            assertEq(usdc.balanceOf(alice), aliceBefore + aliceRefund);
            assertEq(launchpad.pendingRefunds(alice), 0);
        }

        if (bobRefund > 0) {
            vm.prank(bob);
            launchpad.claimRefund();
            assertEq(usdc.balanceOf(bob), bobBefore + bobRefund);
            assertEq(launchpad.pendingRefunds(bob), 0);
        }
    }

    function test_claimRefund_nothingToClaimReverts() public {
        vm.prank(alice);
        vm.expectRevert(Launchpad.NothingToClaim.selector);
        launchpad.claimRefund();
    }

    // ========== 9. COMMITMENTS FINAL ==========

    function test_withdrawCommitment_reverts_commitmentsFinal() public {
        bytes32 proposalId = _proposeAsAlice("Charlotte", 2025, 5e6, 5e6);

        vm.prank(alice);
        vm.expectRevert(Launchpad.CommitmentsFinal.selector);
        launchpad.withdrawCommitment(proposalId);
    }

    // ========== 10. CANCEL DISABLED ==========

    function test_cancelProposal_reverts_commitmentsFinal() public {
        bytes32 proposalId = _proposeAsAlice("Amelia", 2025, 5e6, 5e6);
        vm.expectRevert(Launchpad.CommitmentsFinal.selector);
        launchpad.cancelProposal(proposalId);
    }

    // ========== 12. SAME-PRICE GUARANTEE ==========

    function test_samePriceGuarantee_shareRatioMatchesUsdcRatio() public {
        // Alice: 8 YES, 2 NO
        // Bob: 4 YES, 6 NO
        bytes32 proposalId = _proposeAsAlice("Sophia", 2025, 8e6, 2e6);
        _commitAsBob(proposalId, 4e6, 6e6);

        _warpToLaunch(proposalId);
        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(info.marketId);

        vm.prank(alice);
        launchpad.claimShares(proposalId);
        vm.prank(bob);
        launchpad.claimShares(proposalId);

        uint256 aliceYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice);
        uint256 aliceNo = IERC20(mInfo.outcomeTokens[1]).balanceOf(alice);
        uint256 bobYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(bob);
        uint256 bobNo = IERC20(mInfo.outcomeTokens[1]).balanceOf(bob);

        // For YES: alice committed 8e6, bob committed 4e6 (ratio 2:1)
        if (bobYes > 0) {
            assertApproxEqAbs(aliceYes * 1, bobYes * 2, 1);
        }

        // For NO: alice committed 2e6, bob committed 6e6 (ratio 1:3)
        if (aliceNo > 0) {
            assertApproxEqAbs(aliceNo * 3, bobNo * 1, 1);
        }
    }

    // ========== 13. YEAR/REGION SCOPING ==========

    function test_propose_yearNotOpenReverts() public {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(Launchpad.YearNotOpen.selector);
        launchpad.propose("Olivia", 2030, Launchpad.Gender.GIRL, proof, amounts);
    }

    function test_closeYear_blocksNewProposals() public {
        launchpad.closeYear(2025);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(Launchpad.YearNotOpen.selector);
        launchpad.propose("Olivia", 2025, Launchpad.Gender.GIRL, proof, amounts);
    }

    function test_sameNameDifferentYear_succeeds() public {
        launchpad.openYear(2026);

        _proposeAsAlice("Olivia", 2025, 5e6, 5e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        bytes32 proposalId = launchpad.propose("Olivia", 2026, Launchpad.Gender.GIRL, proof, amounts);
        assertTrue(proposalId != bytes32(0));
    }

    function test_sameNameDifferentRegion_succeeds() public {
        _proposeAsAlice("Olivia", 2025, 5e6, 5e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        bytes32 proposalId = launchpad.proposeRegional("Olivia", 2025, Launchpad.Gender.GIRL, "CA", proof, amounts);
        assertTrue(proposalId != bytes32(0));
    }

    function test_sameNameDifferentGender_succeeds() public {
        _proposeAsAlice("Olivia", 2025, 5e6, 5e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        bytes32 proposalId = launchpad.propose("Olivia", 2025, Launchpad.Gender.BOY, proof, amounts);
        assertTrue(proposalId != bytes32(0));
    }

    // ========== 14. ADMIN PROPOSE ==========

    function test_adminPropose_createsCustomProposal() public {
        string[] memory outcomeNames = new string[](3);
        outcomeNames[0] = "Olivia";
        outcomeNames[1] = "Emma";
        outcomeNames[2] = "Other";

        bytes32 proposalId = launchpad.adminPropose(
            outcomeNames,
            oracle,
            abi.encode("Top girl name 2026"),
            Launchpad.Gender.GIRL,
            2025,
            "",
            block.timestamp + 30 days
        );

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(info.outcomeNames.length, 3);
        assertEq(info.outcomeNames[0], "Olivia");
        assertEq(info.outcomeNames[1], "Emma");
        assertEq(info.outcomeNames[2], "Other");
        assertEq(info.oracle, oracle);
        assertEq(uint256(info.state), uint256(Launchpad.ProposalState.OPEN));
        assertEq(info.year, 2025);
    }

    function test_adminPropose_nonOwnerReverts() public {
        string[] memory outcomeNames = new string[](2);
        outcomeNames[0] = "YES";
        outcomeNames[1] = "NO";

        vm.prank(alice);
        vm.expectRevert();
        launchpad.adminPropose(
            outcomeNames,
            oracle,
            abi.encode("test"),
            Launchpad.Gender.GIRL,
            2025,
            "",
            block.timestamp + 7 days
        );
    }

    function test_adminPropose_usesDefaultLaunchTimeWhenZero() public {
        string[] memory outcomeNames = new string[](2);
        outcomeNames[0] = "YES";
        outcomeNames[1] = "NO";

        bytes32 proposalId = launchpad.adminPropose(
            outcomeNames,
            oracle,
            abi.encode("test"),
            Launchpad.Gender.GIRL,
            2025,
            "",
            0 // use default launch time
        );

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(info.launchTs, block.timestamp + 24 hours);
    }

    // ========== 15. COMMITMENT FEE MATH ==========

    function test_commitmentFeeMath() public {
        // $20 committed -> $1 fee total -> $0.50/outcome
        // maxCreationFee = $10, so $1 all goes to phantom shares, $0 to treasury
        bytes32 proposalId = _proposeAsAlice("Iris", 2025, 10e6, 10e6);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        // Wait for timeout so we can launch with < threshold net
        _warpToLaunch(proposalId);
        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);

        // Fee math:
        // gross = 20e6
        // totalFees = 20e6 * 500 / 10000 = 1e6
        // net = 20e6 - 1e6 = 19e6
        // creationFeeTotal = min(1e6, 10e6) = 1e6
        // creationFeePerOutcome = 1e6 / 2 = 500000 = $0.50
        // excessFees = 1e6 - 1e6 = 0

        uint256 treasuryAfter = usdc.balanceOf(treasury);
        assertEq(treasuryAfter - treasuryBefore, 0, "No excess for $20 committed");

        // Verify market has derived shares based on creation fee
        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(info.marketId);
        // s = totalFee * ONE / targetVig = 1e6 * 1e6 / 70000 = ~14.285e6
        uint256 expectedS = (uint256(1e6) * 1e6) / 70000;
        assertEq(mInfo.initialSharesPerOutcome, expectedS);
    }

    // ========== 16. DUPLICATE MARKET KEY ==========

    function test_duplicateMarketKey_revertsWhileActive() public {
        _proposeAsAlice("Olivia", 2025, 5e6, 5e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        vm.expectRevert(Launchpad.DuplicateMarketKey.selector);
        launchpad.propose("Olivia", 2025, Launchpad.Gender.GIRL, proof, amounts);
    }

    function test_duplicateMarketKey_caseInsensitive() public {
        _proposeAsAlice("Olivia", 2025, 5e6, 5e6);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        vm.expectRevert(Launchpad.DuplicateMarketKey.selector);
        launchpad.propose("olivia", 2025, Launchpad.Gender.GIRL, proof, amounts);
    }

    function test_duplicateMarketKey_stillBlockedAfterLaunchTimeIfNotLaunched() public {
        bytes32 firstProposalId = _proposeAsAlice("Olivia", 2025, 5e6, 5e6);

        _warpToLaunch(firstProposalId);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        vm.expectRevert(Launchpad.DuplicateMarketKey.selector);
        launchpad.propose("Olivia", 2025, Launchpad.Gender.GIRL, proof, amounts);
    }

    function test_duplicateMarketKey_revertsWhileLaunched() public {
        bytes32 proposalId = _proposeAsAlice("Olivia", 2025, 100e6, 100e6);
        _warpToLaunch(proposalId);
        launchpad.launchMarket(proposalId);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        vm.expectRevert(Launchpad.DuplicateMarketKey.selector);
        launchpad.propose("Olivia", 2025, Launchpad.Gender.GIRL, proof, amounts);
    }

    // ========== 17. GET MARKET KEY ==========

    function test_getMarketKey() public view {
        bytes32 key1 = launchpad.getMarketKey("Olivia", Launchpad.Gender.GIRL, 2025, "");
        bytes32 key2 = launchpad.getMarketKey("olivia", Launchpad.Gender.GIRL, 2025, "");
        assertEq(key1, key2, "case insensitive market key");

        bytes32 key3 = launchpad.getMarketKey("Olivia", Launchpad.Gender.GIRL, 2026, "");
        assertTrue(key1 != key3, "different year = different key");

        bytes32 key4 = launchpad.getMarketKey("Olivia", Launchpad.Gender.GIRL, 2025, "CA");
        assertTrue(key1 != key4, "different region = different key");

        bytes32 key5 = launchpad.getMarketKey("Olivia", Launchpad.Gender.BOY, 2025, "");
        assertTrue(key1 != key5, "different gender = different key");
    }

    // ========== 18. GET PROPOSAL BY MARKET KEY ==========

    function test_getProposalByMarketKey() public {
        bytes32 proposalId = _proposeAsAlice("Olivia", 2025, 5e6, 5e6);

        bytes32 found = launchpad.getProposalByMarketKey("Olivia", Launchpad.Gender.GIRL, 2025, "");
        assertEq(found, proposalId);

        bytes32 found2 = launchpad.getProposalByMarketKey("olivia", Launchpad.Gender.GIRL, 2025, "");
        assertEq(found2, proposalId);
    }

    // ========== 19. CLAIM SHARES THEN REDEEM ==========

    function test_claimShares_afterLaunchThenRedeem() public {
        bytes32 proposalId = _proposeAsAlice("Evelyn", 2025, 50e6, 50e6);
        _commitAsBob(proposalId, 50e6, 50e6);

        _warpToLaunch(proposalId);
        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        bytes32 marketId = info.marketId;
        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(marketId);

        vm.prank(alice);
        launchpad.claimShares(proposalId);

        uint256 aliceYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice);
        assertTrue(aliceYes > 0, "alice should have YES tokens");

        assertTrue(launchpad.hasClaimed(proposalId, alice));
        assertFalse(launchpad.hasClaimed(proposalId, bob));

        // Resolve: YES wins
        uint256[] memory payoutPcts = new uint256[](2);
        payoutPcts[0] = 1e6;
        payoutPcts[1] = 0;
        vm.prank(oracle);
        pm.resolveMarketWithPayoutSplit(marketId, payoutPcts);

        // Redeem
        if (aliceYes > 0) {
            vm.prank(alice);
            pm.redeem(mInfo.outcomeTokens[0], aliceYes);
        }
    }

    function test_claimShares_beforeLaunchReverts() public {
        bytes32 proposalId = _proposeAsAlice("Mia", 2025, 50e6, 50e6);

        vm.prank(alice);
        vm.expectRevert(Launchpad.NotLaunched.selector);
        launchpad.claimShares(proposalId);
    }

    function test_claimShares_doubleClaimReverts() public {
        bytes32 proposalId = _proposeAsAlice("Luna", 2025, 100e6, 100e6);

        _warpToLaunch(proposalId);
        launchpad.launchMarket(proposalId);

        vm.prank(alice);
        launchpad.claimShares(proposalId);

        vm.prank(alice);
        vm.expectRevert(Launchpad.AlreadyClaimed.selector);
        launchpad.claimShares(proposalId);
    }

    // ========== 20. WITHDRAW DISABLED ==========

    function test_withdrawCommitment_revertsEvenBeforeLaunchTime() public {
        bytes32 proposalId = _proposeAsAlice("Charlotte", 2025, 5e6, 5e6);

        vm.prank(alice);
        vm.expectRevert(Launchpad.CommitmentsFinal.selector);
        launchpad.withdrawCommitment(proposalId);
    }

    // ========== 21. PROPOSE WITH INVALID NAME ==========

    function test_propose_invalidNameReverts() public {
        bytes32 fakeRoot = keccak256("some merkle root");
        launchpad.setNamesMerkleRoot(Launchpad.Gender.GIRL, fakeRoot);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(Launchpad.InvalidName.selector);
        launchpad.propose("Olivia", 2025, Launchpad.Gender.GIRL, emptyProof, amounts);
    }

    function test_approveName_isGenderSpecific() public {
        bytes32 fakeRoot = keccak256("some merkle root");
        launchpad.setNamesMerkleRoot(Launchpad.Gender.GIRL, fakeRoot);
        launchpad.setNamesMerkleRoot(Launchpad.Gender.BOY, fakeRoot);
        launchpad.approveName("Olivia", Launchpad.Gender.GIRL);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(alice);
        bytes32 proposalId = launchpad.propose("Olivia", 2025, Launchpad.Gender.GIRL, emptyProof, amounts);
        assertTrue(proposalId != bytes32(0));

        vm.prank(bob);
        vm.expectRevert(Launchpad.InvalidName.selector);
        launchpad.propose("Olivia", 2025, Launchpad.Gender.BOY, emptyProof, amounts);
    }

    function test_genderSpecificMerkleRoots_acceptValidProofs() public {
        string memory json = vm.readFile("data/name-merkle-roots.json");
        bytes32 boysRoot = json.readBytes32(".boys.root");
        bytes32 girlsRoot = json.readBytes32(".girls.root");
        string memory boyName = json.readString(".boys.sampleName");
        string memory girlName = json.readString(".girls.sampleName");
        bytes32[] memory boyProof = json.readBytes32Array(".boys.sampleProof");
        bytes32[] memory girlProof = json.readBytes32Array(".girls.sampleProof");

        launchpad.setNamesMerkleRoot(Launchpad.Gender.BOY, boysRoot);
        launchpad.setNamesMerkleRoot(Launchpad.Gender.GIRL, girlsRoot);

        assertTrue(launchpad.isValidName(boyName, Launchpad.Gender.BOY, boyProof));
        assertTrue(launchpad.isValidName(girlName, Launchpad.Gender.GIRL, girlProof));
        assertFalse(launchpad.isValidName(girlName, Launchpad.Gender.BOY, girlProof));
        assertFalse(launchpad.isValidName(boyName, Launchpad.Gender.GIRL, boyProof));
    }
}
