// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.19;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

contract TestUSDC2 is ERC20 {
    function name() public pure override returns (string memory) { return "Test USDC"; }
    function symbol() public pure override returns (string memory) { return "tUSDC"; }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract LaunchpadEdgeTest is Test {
    TestUSDC2 usdc;
    PredictionMarket pm;
    Launchpad launchpad;

    address oracle = address(0xBEEF);
    address treasury = address(0xCAFE);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address charlie = address(0xC4A7);
    address dave = address(0xDA7E);

    function setUp() public {
        usdc = new TestUSDC2();

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
        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(charlie, 100_000e6);
        usdc.mint(dave, 100_000e6);

        // Approve launchpad from users
        vm.prank(alice);
        usdc.approve(address(launchpad), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(launchpad), type(uint256).max);
        vm.prank(charlie);
        usdc.approve(address(launchpad), type(uint256).max);
        vm.prank(dave);
        usdc.approve(address(launchpad), type(uint256).max);
    }

    // ========== HELPERS ==========

    function _proposeAs(address user, string memory _name, uint16 year, uint256 yesAmt, uint256 noAmt)
        internal
        returns (bytes32 proposalId)
    {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = yesAmt;
        amounts[1] = noAmt;
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(user);
        proposalId = launchpad.propose(_name, year, proof, amounts);
    }

    function _commitAs(address user, bytes32 proposalId, uint256 yesAmt, uint256 noAmt) internal {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = yesAmt;
        amounts[1] = noAmt;
        vm.prank(user);
        launchpad.commit(proposalId, amounts);
    }

    // ========== 1. FEE CAP — EXCESS TO TREASURY ==========

    function test_feeCap_excessToTreasury() public {
        // $400 committed = $20 fee total
        // maxCreationFee = $10, so $10 for phantom shares, $10 to treasury
        bytes32 proposalId = _proposeAs(alice, "BigFee", 2025, 200e6, 200e6);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        launchpad.launchMarket(proposalId);

        uint256 treasuryAfter = usdc.balanceOf(treasury);

        // Fee math:
        // gross = 400e6
        // totalFees = 400e6 * 500 / 10000 = 20e6
        // creationFeeTotal = min(20e6, 10e6) = 10e6
        // creationFeePerOutcome = 10e6 / 2 = 5e6
        // excessFees = 20e6 - 10e6 = 10e6
        assertEq(treasuryAfter - treasuryBefore, 10e6, "Excess $10 should go to treasury");

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(uint256(info.state), uint256(Launchpad.ProposalState.LAUNCHED));
    }

    // ========== 2. TINY COMMITMENT — LAUNCH VIA TIMEOUT ==========

    function test_tinyCommitment_launchViaTimeout() public {
        // $1 committed, net = $0.95, fee = $0.05
        bytes32 proposalId = _proposeAs(alice, "Tiny", 2025, 1e6, 0);

        // Below threshold, wait for timeout
        vm.warp(block.timestamp + 24 hours);

        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(uint256(info.state), uint256(Launchpad.ProposalState.LAUNCHED));

        // Fee math:
        // gross = 1e6
        // totalFees = 1e6 * 500 / 10000 = 50000 ($0.05)
        // net = 1e6 - 50000 = 950000 ($0.95)
        // creationFeeTotal = min(50000, 10e6) = 50000
        // creationFeePerOutcome = 50000 / 2 = 25000

        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(info.marketId);
        assertTrue(mInfo.outcomeTokens.length == 2);

        // Claim shares
        vm.prank(alice);
        launchpad.claimShares(proposalId);

        uint256 aliceYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice);
        console2.log("Tiny commitment - Alice YES shares:", aliceYes);
    }

    // ========== 3. LAUNCH BEFORE BATCH DATE REVERTS ==========

    function test_launchBeforeBatchDate_reverts() public {
        uint256 batchDate = block.timestamp + 10 days;
        launchpad.setBatchLaunchDate(batchDate);

        // Create pre-batch proposal (deadline 7 days < batchDate 10 days)
        bytes32 proposalId = _proposeAs(alice, "PreBatch", 2025, 100e6, 100e6);

        vm.expectRevert(Launchpad.NotEligibleForLaunch.selector);
        launchpad.launchMarket(proposalId);
    }

    // ========== 4. LAUNCH AFTER BATCH DATE ==========

    function test_launchAfterBatchDate_postBatchRulesApply() public {
        uint256 batchDate = block.timestamp + 1 days;
        launchpad.setBatchLaunchDate(batchDate);

        // Warp past batch date
        vm.warp(batchDate + 1);

        // Create post-batch proposal (deadline > batchDate since batchDate already passed)
        bytes32 proposalId = _proposeAs(alice, "PostBatch", 2025, 100e6, 100e6);

        // Post-batch: net = $200 * 0.95 = $190 >= $10 threshold, should succeed immediately
        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(uint256(info.state), uint256(Launchpad.ProposalState.LAUNCHED));
    }

    // ========== 5. DOUBLE CLAIM REVERTS ==========

    function test_doubleClaim_reverts() public {
        bytes32 proposalId = _proposeAs(alice, "DoubleClaim", 2025, 100e6, 100e6);
        launchpad.launchMarket(proposalId);

        vm.prank(alice);
        launchpad.claimShares(proposalId);

        vm.prank(alice);
        vm.expectRevert(Launchpad.AlreadyClaimed.selector);
        launchpad.claimShares(proposalId);
    }

    // ========== 6. WITHDRAW BEFORE EXPIRY REVERTS ==========

    function test_withdrawBeforeExpiry_reverts() public {
        bytes32 proposalId = _proposeAs(alice, "Early", 2025, 5e6, 5e6);

        vm.prank(alice);
        vm.expectRevert(Launchpad.NotWithdrawable.selector);
        launchpad.withdrawCommitment(proposalId);
    }

    // ========== 7. ADMIN SETTERS ==========

    function test_adminSetters() public {
        // setCommitmentFeeBps
        launchpad.setCommitmentFeeBps(300);
        assertEq(launchpad.commitmentFeeBps(), 300);

        // setMaxCreationFee
        launchpad.setMaxCreationFee(20e6);
        assertEq(launchpad.maxCreationFee(), 20e6);

        // setBatchLaunchDate
        uint256 newDate = block.timestamp + 30 days;
        launchpad.setBatchLaunchDate(newDate);
        assertEq(launchpad.batchLaunchDate(), newDate);

        // setPostBatchMinThreshold
        launchpad.setPostBatchMinThreshold(50e6);
        assertEq(launchpad.postBatchMinThreshold(), 50e6);

        // setPostBatchTimeout
        launchpad.setPostBatchTimeout(48 hours);
        assertEq(launchpad.postBatchTimeout(), 48 hours);

        // setCommitmentFeeBps too high reverts
        vm.expectRevert(Launchpad.FeeTooHigh.selector);
        launchpad.setCommitmentFeeBps(1001);
    }

    // ========== 8. ZERO FEE — LAUNCH WITH 0% COMMITMENT FEE ==========

    /// @notice With 0% commitment fee, creationFeePerOutcome = 0 is passed to PM.
    ///         PM then uses its default marketCreationFee ($5/outcome = $10 total),
    ///         which is deducted from Launchpad's USDC balance before the trade.
    ///         This means the net budget for trading is reduced by the PM's default fee.
    function test_zeroFee_launchStillUsesDefaultPMCreationFee() public {
        launchpad.setCommitmentFeeBps(0);

        bytes32 proposalId = _proposeAs(alice, "NoFee", 2025, 100e6, 100e6);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        assertEq(uint256(info.state), uint256(Launchpad.ProposalState.LAUNCHED));

        // No commitment fees collected, no excess to treasury from commitment fees
        uint256 treasuryAfter = usdc.balanceOf(treasury);
        assertEq(treasuryAfter - treasuryBefore, 0, "No commitment fee excess");

        // Market exists — PM charged its default creation fee from Launchpad's balance
        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(info.marketId);
        assertEq(mInfo.outcomeTokens.length, 2);

        // PM default fee: 5e6 * 2 = 10e6 total
        // s = totalFee * ONE / targetVig = 10e6 * 1e6 / 70000
        uint256 expectedS = (uint256(10e6) * 1e6) / 70000;
        assertEq(mInfo.initialSharesPerOutcome, expectedS);
    }

    // ========== 9. DUST ACCOUNTING ==========

    function test_dustAccounting_sumClaimedLeTotalShares() public {
        bytes32 proposalId = _proposeAs(alice, "Dusty", 2025, 7e6, 0);
        _commitAs(bob, proposalId, 13e6, 0);
        _commitAs(charlie, proposalId, 0, 11e6);

        // Total YES = 20e6, NO = 11e6, total = 31e6
        // Wait for timeout
        vm.warp(block.timestamp + 24 hours);
        launchpad.launchMarket(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(info.marketId);

        uint256 launchpadYesBefore = IERC20(mInfo.outcomeTokens[0]).balanceOf(address(launchpad));
        uint256 launchpadNoBefore = IERC20(mInfo.outcomeTokens[1]).balanceOf(address(launchpad));

        vm.prank(alice);
        launchpad.claimShares(proposalId);
        vm.prank(bob);
        launchpad.claimShares(proposalId);
        vm.prank(charlie);
        launchpad.claimShares(proposalId);

        uint256 sumYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice)
            + IERC20(mInfo.outcomeTokens[0]).balanceOf(bob)
            + IERC20(mInfo.outcomeTokens[0]).balanceOf(charlie);
        uint256 sumNo = IERC20(mInfo.outcomeTokens[1]).balanceOf(alice)
            + IERC20(mInfo.outcomeTokens[1]).balanceOf(bob)
            + IERC20(mInfo.outcomeTokens[1]).balanceOf(charlie);

        assertLe(sumYes, launchpadYesBefore, "YES: sum of claimed > launchpad balance");
        assertLe(sumNo, launchpadNoBefore, "NO: sum of claimed > launchpad balance");

        console2.log("=== DUST ACCOUNTING ===");
        console2.log("Dust YES:", launchpadYesBefore - sumYes);
        console2.log("Dust NO: ", launchpadNoBefore - sumNo);
    }

    // ========== 10. BINARY SEARCH EXTREME ASYMMETRY ==========

    function test_binarySearch_extremeAsymmetry() public {
        // 19:1 ratio
        bytes32 proposalId = _proposeAs(alice, "Skewed", 2025, 19e6, 1e6);

        // net = 20 * 0.95 = 19, >= 10 threshold
        launchpad.launchMarket(proposalId);

        vm.prank(alice);
        launchpad.claimShares(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(info.marketId);

        uint256 aliceYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice);
        uint256 aliceNo = IERC20(mInfo.outcomeTokens[1]).balanceOf(alice);

        console2.log("=== EXTREME ASYMMETRY (19:1) ===");
        console2.log("Alice YES shares:", aliceYes);
        console2.log("Alice NO shares: ", aliceNo);

        assertTrue(aliceYes > 0, "YES shares should be > 0");
        assertTrue(aliceNo > 0, "NO shares should be > 0");
    }

    // ========== 11. BINARY SEARCH UPPER BOUND ==========

    function test_binarySearch_upperBoundSufficient() public {
        bytes32 proposalId = _proposeAs(alice, "BigBet", 2025, 500e6, 0);
        _commitAs(bob, proposalId, 0, 1e6);

        // Total = 501e6, net = 501 * 0.95 = 475.95
        launchpad.launchMarket(proposalId);

        vm.prank(alice);
        launchpad.claimShares(proposalId);
        vm.prank(bob);
        launchpad.claimShares(proposalId);

        Launchpad.ProposalInfo memory info = launchpad.getProposal(proposalId);
        PredictionMarket.MarketInfo memory mInfo = pm.getMarketInfo(info.marketId);

        uint256 aliceYes = IERC20(mInfo.outcomeTokens[0]).balanceOf(alice);
        uint256 bobNo = IERC20(mInfo.outcomeTokens[1]).balanceOf(bob);

        console2.log("=== BINARY SEARCH UPPER BOUND (500e6 commitment) ===");
        console2.log("Alice YES shares:", aliceYes);
        console2.log("Bob NO shares:   ", bobNo);

        assertTrue(aliceYes > 0, "Alice should have YES shares");

        uint256 aliceRefund = launchpad.pendingRefunds(alice);
        uint256 bobRefund = launchpad.pendingRefunds(bob);
        uint256 totalRefund = aliceRefund + bobRefund;

        // net = 501e6 * 9500 / 10000 = 475950000
        uint256 netForTrading = 501e6 * 9500 / 10000;
        uint256 actualCost = info.actualCost;

        console2.log("Net for trading:  ", netForTrading);
        console2.log("Actual cost:      ", actualCost);
        console2.log("Total refund:     ", totalRefund);
    }

    // ========== 12. MULTIPLE ACTIVE PROPOSALS ==========

    function test_multipleActiveProposals() public {
        bytes32 p1 = _proposeAs(alice, "Alpha", 2025, 100e6, 100e6);
        bytes32 p2 = _proposeAs(bob, "Bravo", 2025, 100e6, 100e6);
        bytes32 p3 = _proposeAs(charlie, "Cedar", 2025, 100e6, 100e6);

        assertTrue(p1 != p2, "p1 != p2");
        assertTrue(p2 != p3, "p2 != p3");
        assertTrue(p1 != p3, "p1 != p3");

        launchpad.launchMarket(p1);
        launchpad.launchMarket(p2);
        launchpad.launchMarket(p3);

        Launchpad.ProposalInfo memory info1 = launchpad.getProposal(p1);
        Launchpad.ProposalInfo memory info2 = launchpad.getProposal(p2);
        Launchpad.ProposalInfo memory info3 = launchpad.getProposal(p3);

        assertEq(uint256(info1.state), uint256(Launchpad.ProposalState.LAUNCHED));
        assertEq(uint256(info2.state), uint256(Launchpad.ProposalState.LAUNCHED));
        assertEq(uint256(info3.state), uint256(Launchpad.ProposalState.LAUNCHED));

        assertTrue(info1.marketId != info2.marketId, "market1 != market2");
        assertTrue(info2.marketId != info3.marketId, "market2 != market3");
    }

    // ========== 13. REFUND ACCOUNTING ==========

    function test_refundAccounting_sumsCorrectly() public {
        bytes32 proposalId = _proposeAs(alice, "Refundy", 2025, 7e6, 3e6);
        _commitAs(bob, proposalId, 4e6, 8e6);
        _commitAs(charlie, proposalId, 2e6, 6e6);

        // Total = 30e6 gross
        // net = 30 * 0.95 = 28.5
        vm.warp(block.timestamp + 24 hours);
        launchpad.launchMarket(proposalId);

        vm.prank(alice);
        launchpad.claimShares(proposalId);
        vm.prank(bob);
        launchpad.claimShares(proposalId);
        vm.prank(charlie);
        launchpad.claimShares(proposalId);

        uint256 aliceRefund = launchpad.pendingRefunds(alice);
        uint256 bobRefund = launchpad.pendingRefunds(bob);
        uint256 charlieRefund = launchpad.pendingRefunds(charlie);
        uint256 totalRefunds = aliceRefund + bobRefund + charlieRefund;

        uint256 launchpadBal = usdc.balanceOf(address(launchpad));

        console2.log("=== REFUND ACCOUNTING ===");
        console2.log("Total committed:  ", uint256(30e6));
        console2.log("Alice refund:     ", aliceRefund);
        console2.log("Bob refund:       ", bobRefund);
        console2.log("Charlie refund:   ", charlieRefund);
        console2.log("Total refunds:    ", totalRefunds);
        console2.log("Launchpad bal:    ", launchpadBal);

        assertGe(launchpadBal, totalRefunds, "Launchpad cannot pay all pending refunds");
        assertLe(totalRefunds, 30e6, "Refunds exceed total committed");
    }

    // ========== 14. COMMIT AFTER DEADLINE REVERTS ==========

    function test_commitAfterDeadline_reverts() public {
        bytes32 proposalId = _proposeAs(alice, "Tardy", 2025, 5e6, 5e6);

        vm.warp(block.timestamp + 7 days + 1);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 5e6;
        amounts[1] = 5e6;

        vm.prank(bob);
        vm.expectRevert(Launchpad.DeadlinePassed.selector);
        launchpad.commit(proposalId, amounts);
    }

    // ========== 15. DOUBLE WITHDRAW REVERTS ==========

    function test_doubleWithdraw_secondReverts() public {
        bytes32 proposalId = _proposeAs(alice, "DoubleW", 2025, 10e6, 10e6);

        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(alice);
        launchpad.withdrawCommitment(proposalId);

        vm.prank(alice);
        vm.expectRevert(Launchpad.NothingToWithdraw.selector);
        launchpad.withdrawCommitment(proposalId);
    }

    // ========== 16. PROPOSE AFTER LAUNCH BLOCKED ==========

    function test_proposeAfterLaunch_sameNameBlocked() public {
        bytes32 proposalId1 = _proposeAs(alice, "Olivia", 2025, 100e6, 100e6);
        launchpad.launchMarket(proposalId1);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e6;
        amounts[1] = 10e6;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(bob);
        vm.expectRevert(Launchpad.DuplicateMarketKey.selector);
        launchpad.propose("Olivia", 2025, proof, amounts);
    }
}
