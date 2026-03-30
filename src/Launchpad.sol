// SPDX-License-Identifier: BUSL-1.1
// Based on Context Markets contracts, used under license
pragma solidity ^0.8.19;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {PredictionMarket} from "./PredictionMarket.sol";

/**
 * @title Launchpad
 * @notice Commitment-based market bootstrapping for baby name prediction markets.
 *
 *         Markets are scoped to (name, year, region). Each combination can only have
 *         one active proposal at a time. Years are locked by default and must be opened
 *         by the admin before proposals can be created.
 *
 *         Anyone can propose a market for a name in the Merkle tree and commit capital.
 *         A 5% commitment fee is collected from all commitments. On launch, fees fund
 *         phantom shares (market creation fee) and excess goes to protocol treasury as revenue.
 *
 *         Launch eligibility follows two modes:
 *         - Pre-batch proposals (created before batchLaunchDate): launch on or after batchLaunchDate
 *         - Post-batch proposals: launch when threshold reached OR timeout expires
 *
 *         After launch, users call claimShares() to receive outcome tokens directly
 *         to their wallet. If a proposal expires without launching, users get a full
 *         refund including the fee portion.
 */
contract Launchpad is OwnableRoles {
    struct PermitArgs {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    PredictionMarket public predictionMarket;
    IERC20 public usdc;

    // ========== NAME VALIDATION ==========

    /// @notice Merkle root of valid SSA names (0 = no whitelist enforced, all names allowed)
    bytes32 public namesMerkleRoot;

    /// @notice Names manually approved by owner (keccak256(lowercased) => true)
    mapping(bytes32 => bool) public approvedNames;

    // ========== YEAR LIFECYCLE ==========

    /// @notice Whether a year is open for new proposals. Years are locked by default.
    mapping(uint16 => bool) public yearOpen;

    // ========== REGION VALIDATION ==========

    /// @notice Valid region codes. "" (empty) is always valid (national).
    ///         Prepopulated with all 50 US state abbreviations (uppercased).
    mapping(bytes32 => bool) public validRegions;
    bool public defaultRegionsSeeded;

    // ========== DEFAULT MARKET PARAMS ==========

    address public defaultOracle;
    uint256 public defaultDeadlineDuration;
    address public surplusRecipient;

    // ========== COMMITMENT FEE ==========

    /// @notice Commitment fee in basis points (5% = 500 bps)
    uint256 public commitmentFeeBps = 500;

    /// @notice Maximum allowed commitment fee (10% = 1000 bps)
    uint256 public constant MAX_COMMITMENT_FEE_BPS = 1000;

    /// @notice Maximum total creation fee for phantom shares (in USDC, 6 decimals)
    uint256 public maxCreationFee = 10e6;

    // ========== LAUNCH TRIGGERS ==========

    /// @notice Batch launch date. Proposals created before this date launch ON this date.
    ///         After this date, proposals use threshold + time rules. 0 = disabled.
    uint256 public batchLaunchDate;

    /// @notice For post-batch proposals: minimum net commitment to trigger immediate launch
    uint256 public postBatchMinThreshold = 10e6;

    /// @notice For post-batch proposals: time after proposal creation when it auto-qualifies for launch
    uint256 public postBatchTimeout = 24 hours;

    // ========== PROPOSAL STATE ==========

    enum ProposalState {
        OPEN,
        LAUNCHED,
        EXPIRED,
        CANCELLED
    }

    struct ProposalInfo {
        bytes32 questionId;
        address oracle;
        bytes metadata;
        string[] outcomeNames;
        uint256 deadline;
        uint256 createdAt;
        ProposalState state;
        bytes32 marketId;
        uint256[] totalPerOutcome;
        uint256 totalCommitted;
        uint256 totalFeesCollected;
        address[] committers;
        string name;
        uint16 year;
        string region;
        uint256 actualCost;
        uint256 tradingBudget;
        uint256[] totalSharesPerOutcome;
    }

    struct ProposalStorage {
        bytes32 questionId;
        address oracle;
        bytes metadata;
        string[] outcomeNames;
        uint256 deadline;
        uint256 createdAt;
        ProposalState state;
        bytes32 marketId;
        uint256[] totalPerOutcome;  // NET per outcome (after fee)
        uint256 totalCommitted;     // GROSS total committed
        uint256 totalFeesCollected; // fees separated at commit time
        address[] committers;
        string name;
        uint16 year;
        string region;
        uint256 actualCost;
        uint256 tradingBudget;
        uint256[] totalSharesPerOutcome;
        mapping(address => uint256[]) committed;      // NET per user per outcome
        mapping(address => uint256) committedGross;    // GROSS per user (for full refund)
        mapping(address => bool) hasCommitted;
        mapping(address => bool) claimed;
    }

    mapping(bytes32 => ProposalStorage) internal proposals;

    /// @notice Maps market key hash(name, year, region) to proposalId.
    ///         Prevents duplicate proposals for the same (name, year, region) combination.
    mapping(bytes32 => bytes32) public marketKeyToProposal;

    mapping(address => uint256) public pendingRefunds;

    // ========== EVENTS ==========

    event ProposalCreated(
        bytes32 indexed proposalId,
        bytes32 indexed questionId,
        string name,
        uint16 year,
        string region,
        address proposer,
        uint256 deadline
    );
    event Committed(bytes32 indexed proposalId, address indexed user, uint256[] amounts, uint256 total);
    event CommitmentWithdrawn(bytes32 indexed proposalId, address indexed user, uint256 amount);
    event MarketLaunched(
        bytes32 indexed proposalId,
        bytes32 indexed marketId,
        uint256 actualCost,
        uint256 feesUsedForCreation,
        uint256 excessFees,
        uint256 committerCount
    );
    event SharesClaimed(bytes32 indexed proposalId, address indexed user, uint256[] shares, uint256 refund);
    event ProposalCancelled(bytes32 indexed proposalId);
    event RefundClaimed(address indexed user, uint256 amount);
    event SurplusRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event NamesMerkleRootUpdated(bytes32 oldRoot, bytes32 newRoot);
    event NameApproved(string name);
    event DefaultOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event DefaultDeadlineDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event DefaultRegionsSeeded();
    event YearOpened(uint16 indexed year);
    event YearClosed(uint16 indexed year);
    event RegionAdded(string region);
    event RegionRemoved(string region);
    event CommitmentFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event MaxCreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event BatchLaunchDateUpdated(uint256 oldDate, uint256 newDate);
    event PostBatchMinThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event PostBatchTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);

    // ========== ERRORS ==========

    error NotOpen();
    error NotLaunched();
    error AlreadyClaimed();
    error DeadlinePassed();
    error InvalidAmounts();
    error ProposalExists();
    error DuplicateMarketKey();
    error InvalidDeadline();
    error InvalidOracle();
    error InvalidOutcomes();
    error InvalidName();
    error InvalidYear();
    error YearNotOpen();
    error InvalidRegion();
    error BelowThreshold();
    error NotEligibleForLaunch();
    error NotWithdrawable();
    error NothingToWithdraw();
    error NothingToClaim();
    error TransferFailed();
    error ZeroAddress();
    error DefaultsNotSet();
    error DefaultRegionsAlreadySeeded();
    error FeeTooHigh();

    constructor(
        address _predictionMarket,
        address _surplusRecipient,
        address _defaultOracle,
        uint256 _defaultDeadlineDuration,
        address _owner
    ) {
        _initializeOwner(_owner);
        predictionMarket = PredictionMarket(_predictionMarket);
        usdc = PredictionMarket(_predictionMarket).usdc();

        if (_surplusRecipient == address(0)) revert ZeroAddress();
        surplusRecipient = _surplusRecipient;
        emit SurplusRecipientUpdated(address(0), _surplusRecipient);

        if (_defaultOracle == address(0)) revert InvalidOracle();
        defaultOracle = _defaultOracle;
        emit DefaultOracleUpdated(address(0), _defaultOracle);

        defaultDeadlineDuration = _defaultDeadlineDuration;
        emit DefaultDeadlineDurationUpdated(0, _defaultDeadlineDuration);

        // Approve PredictionMarket to spend our USDC (for createMarket and trade calls)
        usdc.approve(address(predictionMarket), type(uint256).max);
    }

    function _initRegions() internal {
        // All 50 US states by two-letter abbreviation (uppercase)
        validRegions[keccak256("AL")] = true;
        validRegions[keccak256("AK")] = true;
        validRegions[keccak256("AZ")] = true;
        validRegions[keccak256("AR")] = true;
        validRegions[keccak256("CA")] = true;
        validRegions[keccak256("CO")] = true;
        validRegions[keccak256("CT")] = true;
        validRegions[keccak256("DE")] = true;
        validRegions[keccak256("FL")] = true;
        validRegions[keccak256("GA")] = true;
        validRegions[keccak256("HI")] = true;
        validRegions[keccak256("ID")] = true;
        validRegions[keccak256("IL")] = true;
        validRegions[keccak256("IN")] = true;
        validRegions[keccak256("IA")] = true;
        validRegions[keccak256("KS")] = true;
        validRegions[keccak256("KY")] = true;
        validRegions[keccak256("LA")] = true;
        validRegions[keccak256("ME")] = true;
        validRegions[keccak256("MD")] = true;
        validRegions[keccak256("MA")] = true;
        validRegions[keccak256("MI")] = true;
        validRegions[keccak256("MN")] = true;
        validRegions[keccak256("MS")] = true;
        validRegions[keccak256("MO")] = true;
        validRegions[keccak256("MT")] = true;
        validRegions[keccak256("NE")] = true;
        validRegions[keccak256("NV")] = true;
        validRegions[keccak256("NH")] = true;
        validRegions[keccak256("NJ")] = true;
        validRegions[keccak256("NM")] = true;
        validRegions[keccak256("NY")] = true;
        validRegions[keccak256("NC")] = true;
        validRegions[keccak256("ND")] = true;
        validRegions[keccak256("OH")] = true;
        validRegions[keccak256("OK")] = true;
        validRegions[keccak256("OR")] = true;
        validRegions[keccak256("PA")] = true;
        validRegions[keccak256("RI")] = true;
        validRegions[keccak256("SC")] = true;
        validRegions[keccak256("SD")] = true;
        validRegions[keccak256("TN")] = true;
        validRegions[keccak256("TX")] = true;
        validRegions[keccak256("UT")] = true;
        validRegions[keccak256("VT")] = true;
        validRegions[keccak256("VA")] = true;
        validRegions[keccak256("WA")] = true;
        validRegions[keccak256("WV")] = true;
        validRegions[keccak256("WI")] = true;
        validRegions[keccak256("WY")] = true;
    }

    // ========== ADMIN ==========

    function openYear(uint16 year) external onlyOwner {
        if (year == 0) revert InvalidYear();
        yearOpen[year] = true;
        emit YearOpened(year);
    }

    function seedDefaultRegions() external onlyOwner {
        if (defaultRegionsSeeded) revert DefaultRegionsAlreadySeeded();
        _initRegions();
        defaultRegionsSeeded = true;
        emit DefaultRegionsSeeded();
    }

    function closeYear(uint16 year) external onlyOwner {
        yearOpen[year] = false;
        emit YearClosed(year);
    }

    function addRegion(string calldata region) external onlyOwner {
        string memory upper = _toUpperCase(region);
        validRegions[keccak256(bytes(upper))] = true;
        emit RegionAdded(upper);
    }

    function removeRegion(string calldata region) external onlyOwner {
        string memory upper = _toUpperCase(region);
        validRegions[keccak256(bytes(upper))] = false;
        emit RegionRemoved(upper);
    }

    function isValidRegion(string memory region) public view returns (bool) {
        if (bytes(region).length == 0) return true; // "" = national, always valid
        return validRegions[keccak256(bytes(_toUpperCase(region)))];
    }

    function setNamesMerkleRoot(bytes32 _root) external onlyOwner {
        emit NamesMerkleRootUpdated(namesMerkleRoot, _root);
        namesMerkleRoot = _root;
    }

    function approveName(string calldata name) external onlyOwner {
        bytes32 nameHash = keccak256(bytes(_toLowerCase(name)));
        approvedNames[nameHash] = true;
        emit NameApproved(name);
    }

    function setSurplusRecipient(address _surplusRecipient) external onlyOwner {
        if (_surplusRecipient == address(0)) revert ZeroAddress();
        emit SurplusRecipientUpdated(surplusRecipient, _surplusRecipient);
        surplusRecipient = _surplusRecipient;
    }

    function setDefaultOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert InvalidOracle();
        emit DefaultOracleUpdated(defaultOracle, _oracle);
        defaultOracle = _oracle;
    }

    function setDefaultDeadlineDuration(uint256 _duration) external onlyOwner {
        emit DefaultDeadlineDurationUpdated(defaultDeadlineDuration, _duration);
        defaultDeadlineDuration = _duration;
    }

    function setCommitmentFeeBps(uint256 _bps) external onlyOwner {
        if (_bps > MAX_COMMITMENT_FEE_BPS) revert FeeTooHigh();
        emit CommitmentFeeBpsUpdated(commitmentFeeBps, _bps);
        commitmentFeeBps = _bps;
    }

    function setMaxCreationFee(uint256 _maxFee) external onlyOwner {
        emit MaxCreationFeeUpdated(maxCreationFee, _maxFee);
        maxCreationFee = _maxFee;
    }

    function setBatchLaunchDate(uint256 _date) external onlyOwner {
        emit BatchLaunchDateUpdated(batchLaunchDate, _date);
        batchLaunchDate = _date;
    }

    function setPostBatchMinThreshold(uint256 _threshold) external onlyOwner {
        emit PostBatchMinThresholdUpdated(postBatchMinThreshold, _threshold);
        postBatchMinThreshold = _threshold;
    }

    function setPostBatchTimeout(uint256 _timeout) external onlyOwner {
        emit PostBatchTimeoutUpdated(postBatchTimeout, _timeout);
        postBatchTimeout = _timeout;
    }

    function setUsdcAllowance(uint256 amount) external onlyOwner {
        usdc.approve(address(predictionMarket), amount);
    }

    function withdrawUsdc(uint256 amount, address to) external onlyOwner {
        if (!usdc.transfer(to, amount)) revert TransferFailed();
    }

    // ========== NAME VALIDATION ==========

    function isValidName(string memory name, bytes32[] calldata proof) public view returns (bool) {
        if (namesMerkleRoot == bytes32(0)) return true;

        string memory lowered = _toLowerCase(name);
        bytes32 nameHash = keccak256(bytes(lowered));

        if (approvedNames[nameHash]) return true;

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(lowered))));
        return MerkleProofLib.verify(proof, namesMerkleRoot, leaf);
    }

    // ========== PROPOSALS ==========

    /**
     * @notice Proposes a market for a name and commits capital in one call.
     *         Uses the national region by default. Year must be open.
     * @param name The baby name to create a market for
     * @param year The SSA data year (e.g. 2025, 2026)
     * @param proof Merkle proof that the name is in the valid names tree
     * @param amounts Commitment amounts per outcome [YES, NO]
     */
    function propose(string calldata name, uint16 year, bytes32[] calldata proof, uint256[] calldata amounts)
        external
        returns (bytes32)
    {
        return _propose(name, year, "", proof, amounts);
    }

    function proposeWithPermit(
        string calldata name,
        uint16 year,
        bytes32[] calldata proof,
        uint256[] calldata amounts,
        PermitArgs calldata permitData
    ) external returns (bytes32) {
        IERC20Permit(address(usdc)).permit(
            msg.sender,
            address(this),
            permitData.value,
            permitData.deadline,
            permitData.v,
            permitData.r,
            permitData.s
        );
        return _propose(name, year, "", proof, amounts);
    }

    /**
     * @notice Proposes a market for a name in a specific region.
     *         Region is a state abbreviation (e.g. "CA") or "" for national.
     */
    function proposeRegional(
        string calldata name,
        uint16 year,
        string calldata region,
        bytes32[] calldata proof,
        uint256[] calldata amounts
    ) external returns (bytes32) {
        return _propose(name, year, region, proof, amounts);
    }

    function _propose(
        string calldata name,
        uint16 year,
        string memory region,
        bytes32[] calldata proof,
        uint256[] calldata amounts
    ) internal returns (bytes32) {
        if (!isValidName(name, proof)) revert InvalidName();
        if (!yearOpen[year]) revert YearNotOpen();
        if (!isValidRegion(region)) revert InvalidRegion();
        if (defaultOracle == address(0)) revert DefaultsNotSet();
        if (defaultDeadlineDuration == 0) revert DefaultsNotSet();

        string memory lowered = _toLowerCase(name);
        // Store region as uppercase abbreviation (or "" for national)
        string memory upperRegion = bytes(region).length > 0 ? _toUpperCase(region) : region;

        // Unique key per (name, year, region)
        bytes32 marketKey = keccak256(abi.encode(lowered, year, upperRegion));

        // Prevent duplicate active proposals for the same (name, year, region)
        if (marketKeyToProposal[marketKey] != bytes32(0)) {
            bytes32 existingId = marketKeyToProposal[marketKey];
            ProposalStorage storage existing = proposals[existingId];
            if (
                existing.state == ProposalState.OPEN || existing.state == ProposalState.LAUNCHED
            ) {
                revert DuplicateMarketKey();
            }
        }

        // questionId: launchpad address (20 bytes) + hash(name, year, region) truncated (12 bytes)
        bytes32 questionId = bytes32(
            (uint256(uint160(address(this))) << 96) | uint256(uint96(bytes12(marketKey)))
        );

        bytes32 proposalId =
            keccak256(abi.encodePacked(address(this), block.chainid, questionId, block.timestamp));
        if (proposals[proposalId].deadline != 0) revert ProposalExists();

        string[] memory outcomeNames = new string[](2);
        outcomeNames[0] = "YES";
        outcomeNames[1] = "NO";

        uint256 deadline = block.timestamp + defaultDeadlineDuration;

        ProposalStorage storage prop = proposals[proposalId];
        prop.questionId = questionId;
        prop.oracle = defaultOracle;
        prop.metadata = abi.encode(lowered, year, upperRegion);
        prop.outcomeNames = outcomeNames;
        prop.deadline = deadline;
        prop.createdAt = block.timestamp;
        prop.state = ProposalState.OPEN;
        prop.totalPerOutcome = new uint256[](2);
        prop.name = lowered;
        prop.year = year;
        prop.region = upperRegion;

        marketKeyToProposal[marketKey] = proposalId;

        emit ProposalCreated(
            proposalId, questionId, lowered, year, upperRegion, msg.sender, deadline
        );

        if (amounts.length != 2) revert InvalidAmounts();
        _commit(proposalId, amounts);

        return proposalId;
    }

    /**
     * @notice Admin creates a proposal with custom parameters, bypassing name/year validation.
     * @param year The SSA data year
     * @param region Region string ("" for national, or state abbreviation)
     */
    function adminPropose(
        string[] calldata outcomeNames,
        address oracle,
        bytes calldata metadata,
        uint16 year,
        string calldata region,
        uint256 deadline
    ) external onlyOwner returns (bytes32) {
        if (outcomeNames.length < 2) revert InvalidOutcomes();
        if (oracle == address(0)) revert InvalidOracle();
        if (year == 0) revert InvalidYear();

        uint256 _deadline = deadline > 0 ? deadline : block.timestamp + defaultDeadlineDuration;
        if (_deadline <= block.timestamp) revert InvalidDeadline();

        bytes32 metaHash = keccak256(abi.encode(metadata, year, region));
        bytes32 questionId = bytes32(
            (uint256(uint160(address(this))) << 96) | uint256(uint96(bytes12(metaHash)))
        );

        bytes32 proposalId =
            keccak256(abi.encodePacked(address(this), block.chainid, questionId, block.timestamp));
        if (proposals[proposalId].deadline != 0) revert ProposalExists();

        ProposalStorage storage prop = proposals[proposalId];
        prop.questionId = questionId;
        prop.oracle = oracle;
        prop.metadata = metadata;
        prop.outcomeNames = outcomeNames;
        prop.deadline = _deadline;
        prop.createdAt = block.timestamp;
        prop.state = ProposalState.OPEN;
        prop.totalPerOutcome = new uint256[](outcomeNames.length);
        prop.year = year;
        prop.region = bytes(region).length > 0 ? _toUpperCase(region) : region;

        emit ProposalCreated(proposalId, questionId, "", year, prop.region, msg.sender, _deadline);

        return proposalId;
    }

    // ========== COMMITMENT ==========

    function commit(bytes32 proposalId, uint256[] calldata amounts) external {
        ProposalStorage storage prop = proposals[proposalId];
        if (prop.state != ProposalState.OPEN) revert NotOpen();
        if (block.timestamp >= prop.deadline) revert DeadlinePassed();
        if (amounts.length != prop.outcomeNames.length) revert InvalidAmounts();

        _commit(proposalId, amounts);
    }

    function commitWithPermit(bytes32 proposalId, uint256[] calldata amounts, PermitArgs calldata permitData)
        external
    {
        IERC20Permit(address(usdc)).permit(
            msg.sender,
            address(this),
            permitData.value,
            permitData.deadline,
            permitData.v,
            permitData.r,
            permitData.s
        );
        ProposalStorage storage prop = proposals[proposalId];
        if (prop.state != ProposalState.OPEN) revert NotOpen();
        if (block.timestamp >= prop.deadline) revert DeadlinePassed();
        if (amounts.length != prop.outcomeNames.length) revert InvalidAmounts();

        _commit(proposalId, amounts);
    }

    /**
     * @dev Takes gross amounts from user. Fee (5%) is separated immediately:
     *      - Net amounts stored in committed[user] and totalPerOutcome (for share distribution)
     *      - Fee accumulated in totalFeesCollected (for phantom shares at launch)
     *      - Gross stored in committedGross[user] (for full refund on expiry/cancel)
     */
    function _commit(bytes32 proposalId, uint256[] calldata amounts) internal {
        ProposalStorage storage prop = proposals[proposalId];

        uint256 gross;
        if (prop.committed[msg.sender].length == 0) {
            prop.committed[msg.sender] = new uint256[](amounts.length);
        }

        for (uint256 i; i < amounts.length; i++) {
            if (amounts[i] == 0) continue;
            uint256 fee = FixedPointMathLib.mulDiv(amounts[i], commitmentFeeBps, 10000);
            uint256 net = amounts[i] - fee;
            prop.committed[msg.sender][i] += net;
            prop.totalPerOutcome[i] += net;
            prop.totalFeesCollected += fee;
            gross += amounts[i];
        }
        if (gross == 0) revert InvalidAmounts();

        if (!prop.hasCommitted[msg.sender]) {
            prop.committers.push(msg.sender);
            prop.hasCommitted[msg.sender] = true;
        }
        prop.totalCommitted += gross;
        prop.committedGross[msg.sender] += gross;

        // Pull gross amount from user to Launchpad
        if (!usdc.transferFrom(msg.sender, address(this), gross)) revert TransferFailed();

        emit Committed(proposalId, msg.sender, amounts, gross);
    }

    // ========== LAUNCH ==========

    /**
     * @notice Launches a market once launch eligibility is met. Callable by anyone.
     *         A commitment fee is deducted from grossCommitted:
     *         - Up to maxCreationFee funds phantom shares (market creation fee)
     *         - Excess fees are sent to surplusRecipient as protocol revenue
     *         - Remaining net funds are used for the aggregate LMSR trade
     *         Share distribution is deferred to claimShares().
     */
    function launchMarket(bytes32 proposalId) external {
        ProposalStorage storage prop = proposals[proposalId];
        if (prop.state != ProposalState.OPEN) revert NotOpen();

        // Check launch eligibility
        {
            bool eligible;
            uint256 netCommitted = prop.totalCommitted - prop.totalFeesCollected;
            if (batchLaunchDate > 0 && prop.createdAt < batchLaunchDate) {
                // Pre-batch proposal: can only launch on or after batch date
                eligible = block.timestamp >= batchLaunchDate;
            } else {
                // Post-batch proposal (or batch disabled): threshold OR timeout
                eligible = netCommitted >= postBatchMinThreshold
                    || block.timestamp >= prop.createdAt + postBatchTimeout;
            }
            if (!eligible) revert NotEligibleForLaunch();
        }

        // Must have at least SOME commitment
        if (prop.totalCommitted == 0) revert BelowThreshold();

        prop.state = ProposalState.LAUNCHED;

        uint256 n = prop.outcomeNames.length;

        // Fees were already separated at commit time into totalFeesCollected
        uint256 totalFees = prop.totalFeesCollected;

        // Determine creation fee: min(totalFees, maxCreationFee)
        uint256 creationFeeTotal = totalFees > maxCreationFee ? maxCreationFee : totalFees;
        uint256 creationFeePerOutcome = creationFeeTotal / n;
        // Adjust for integer division remainder
        creationFeeTotal = creationFeePerOutcome * n;

        // Excess fees go to protocol treasury as revenue
        uint256 excessFees = totalFees - creationFeeTotal;
        if (excessFees > 0) {
            if (!usdc.transfer(surplusRecipient, excessFees)) revert TransferFailed();
        }

        // 1. Create market with computed fee per outcome
        //    Launchpad has already approved PM in constructor
        int256[] memory zeroDelta = new int256[](n);
        string[] memory outcomeNames = prop.outcomeNames;

        PredictionMarket.CreateMarketParams memory params = PredictionMarket.CreateMarketParams({
            oracle: prop.oracle,
            creationFeePerOutcome: creationFeePerOutcome,
            questionId: prop.questionId,
            surplusRecipient: surplusRecipient,
            metadata: prop.metadata,
            initialBuyShares: zeroDelta,
            initialBuyMaxCost: 0,
            outcomeNames: outcomeNames
        });

        bytes32 marketId = predictionMarket.createMarket(params);
        prop.marketId = marketId;

        // 2. Binary search for aggregate trade
        //    Use actual available USDC as budget (accounts for PM creation fee spent in createMarket)
        PredictionMarket.MarketInfo memory info = predictionMarket.getMarketInfo(marketId);
        uint256 tradingBudget = usdc.balanceOf(address(this));
        int256[] memory deltaShares = _computeAggregateShares(info, prop.totalPerOutcome, tradingBudget);

        // 3. Execute aggregate trade
        {
            bool hasNonZero;
            for (uint256 i; i < n; i++) {
                if (deltaShares[i] != 0) {
                    hasNonZero = true;
                    break;
                }
            }

            if (hasNonZero) {
                // Fee-exempt trade: Launchpad already collected 5% commitment fee
                predictionMarket.tradeRaw(
                    PredictionMarket.Trade({
                        marketId: marketId,
                        deltaShares: deltaShares,
                        maxCost: tradingBudget,
                        minPayout: 0,
                        deadline: block.timestamp
                    })
                );
            }
        }

        // 4. Store results for lazy claimShares()
        //    tradingBudget = USDC available after createMarket (for binary search + trade)
        //    actualCost = USDC spent on the trade (= tradingBudget - remaining balance)
        prop.tradingBudget = tradingBudget;
        {
            uint256 balNow = usdc.balanceOf(address(this));
            prop.actualCost = tradingBudget > balNow ? tradingBudget - balNow : 0;
        }
        prop.totalSharesPerOutcome = new uint256[](n);
        for (uint256 i; i < n; i++) {
            if (deltaShares[i] > 0) {
                prop.totalSharesPerOutcome[i] = uint256(deltaShares[i]);
            }
        }

        emit MarketLaunched(proposalId, marketId, prop.actualCost, creationFeeTotal, excessFees, prop.committers.length);
    }

    // ========== CLAIM SHARES ==========

    /**
     * @notice Claims outcome tokens and any USDC refund after launch.
     *         Tokens go directly to caller's wallet -- no locking, trade freely.
     *         Share distribution uses gross committed proportions (everyone loses the
     *         same fee %, so proportions are preserved).
     *         Refund is proportional share of unspent net trading funds.
     */
    function claimShares(bytes32 proposalId) external {
        ProposalStorage storage prop = proposals[proposalId];
        if (prop.state != ProposalState.LAUNCHED) revert NotLaunched();
        if (prop.claimed[msg.sender]) revert AlreadyClaimed();
        if (prop.committed[msg.sender].length == 0) revert NothingToClaim();

        prop.claimed[msg.sender] = true;

        bytes32 marketId = prop.marketId;
        PredictionMarket.MarketInfo memory mInfo = predictionMarket.getMarketInfo(marketId);
        uint256 n = prop.outcomeNames.length;

        uint256 userTotal;
        uint256[] memory userShares = new uint256[](n);

        for (uint256 i; i < n; i++) {
            uint256 userCommitted = prop.committed[msg.sender][i];
            userTotal += userCommitted;
            if (userCommitted == 0 || prop.totalPerOutcome[i] == 0 || prop.totalSharesPerOutcome[i] == 0) continue;
            userShares[i] = FixedPointMathLib.mulDiv(
                prop.totalSharesPerOutcome[i], userCommitted, prop.totalPerOutcome[i]
            );
        }

        for (uint256 i; i < n; i++) {
            if (userShares[i] > 0) {
                if (!IERC20(mInfo.outcomeTokens[i]).transfer(msg.sender, userShares[i])) revert TransferFailed();
            }
        }

        // Refund is proportional share of unspent NET trading funds
        // committed[user] and totalPerOutcome store NET amounts, so userTotal is NET
        uint256 netCommitted = prop.totalCommitted - prop.totalFeesCollected;
        uint256 refund;
        uint256 unspent = prop.tradingBudget > prop.actualCost ? prop.tradingBudget - prop.actualCost : 0;
        if (unspent > 0 && userTotal > 0 && netCommitted > 0) {
            refund = FixedPointMathLib.mulDiv(unspent, userTotal, netCommitted);
            if (refund > 0) pendingRefunds[msg.sender] += refund;
        }

        emit SharesClaimed(proposalId, msg.sender, userShares, refund);
    }

    // ========== BINARY SEARCH ==========

    /**
     * @dev Binary search for the largest scalar k such that the raw LMSR cost
     *      of buying k*totalPerOutcome shares does not exceed the budget.
     *      Fee-agnostic — uses quoteTrade directly, no fee adjustment needed
     *      because Launchpad calls tradeRaw (fee-exempt).
     */
    function _computeAggregateShares(
        PredictionMarket.MarketInfo memory info,
        uint256[] storage totalPerOutcome,
        uint256 budget
    ) internal view returns (int256[] memory deltaShares) {
        uint256 n = totalPerOutcome.length;
        deltaShares = new int256[](n);

        uint256 lo = 0;
        uint256 hi = 2e6;

        for (uint256 iter; iter < 64; iter++) {
            uint256 mid = (lo + hi) / 2;
            if (mid == lo) break;

            for (uint256 i; i < n; i++) {
                deltaShares[i] = int256(FixedPointMathLib.mulDiv(mid, totalPerOutcome[i], 1e6));
            }

            int256 quotedCost = predictionMarket.quoteTrade(info.outcomeQs, info.alpha, deltaShares);

            if (quotedCost > 0 && uint256(quotedCost) <= budget) {
                lo = mid;
            } else if (quotedCost <= 0) {
                lo = mid;
            } else {
                hi = mid;
            }
        }

        for (uint256 i; i < n; i++) {
            deltaShares[i] = int256(FixedPointMathLib.mulDiv(lo, totalPerOutcome[i], 1e6));
        }
    }

    // ========== WITHDRAWALS ==========

    /**
     * @notice Withdraw committed funds when proposal is expired or cancelled.
     *         Returns the GROSS amount (including the fee portion) since the market never launched.
     */
    function withdrawCommitment(bytes32 proposalId) external {
        ProposalStorage storage prop = proposals[proposalId];
        if (
            prop.state != ProposalState.EXPIRED && prop.state != ProposalState.CANCELLED
                && !(prop.state == ProposalState.OPEN && block.timestamp >= prop.deadline)
        ) {
            revert NotWithdrawable();
        }
        if (prop.state == ProposalState.OPEN) {
            prop.state = ProposalState.EXPIRED;
        }

        // Full refund of GROSS amount (including fee portion) since market never launched
        uint256 gross = prop.committedGross[msg.sender];
        if (gross == 0) revert NothingToWithdraw();

        // Zero out all tracking
        uint256 n = prop.outcomeNames.length;
        for (uint256 i; i < n; i++) {
            prop.committed[msg.sender][i] = 0;
        }
        prop.committedGross[msg.sender] = 0;

        if (!usdc.transfer(msg.sender, gross)) revert TransferFailed();
        emit CommitmentWithdrawn(proposalId, msg.sender, gross);
    }

    function cancelProposal(bytes32 proposalId) external onlyOwner {
        ProposalStorage storage prop = proposals[proposalId];
        if (prop.state != ProposalState.OPEN) revert NotOpen();
        prop.state = ProposalState.CANCELLED;
        emit ProposalCancelled(proposalId);
    }

    function claimRefund() external {
        uint256 amount = pendingRefunds[msg.sender];
        if (amount == 0) revert NothingToClaim();
        pendingRefunds[msg.sender] = 0;
        if (!usdc.transfer(msg.sender, amount)) revert TransferFailed();
        emit RefundClaimed(msg.sender, amount);
    }

    // ========== VIEW ==========

    function getProposal(bytes32 proposalId) external view returns (ProposalInfo memory) {
        ProposalStorage storage prop = proposals[proposalId];
        return ProposalInfo({
            questionId: prop.questionId,
            oracle: prop.oracle,
            metadata: prop.metadata,
            outcomeNames: prop.outcomeNames,
            deadline: prop.deadline,
            createdAt: prop.createdAt,
            state: prop.state,
            marketId: prop.marketId,
            totalPerOutcome: prop.totalPerOutcome,
            totalCommitted: prop.totalCommitted,
            totalFeesCollected: prop.totalFeesCollected,
            committers: prop.committers,
            name: prop.name,
            year: prop.year,
            region: prop.region,
            actualCost: prop.actualCost,
            tradingBudget: prop.tradingBudget,
            totalSharesPerOutcome: prop.totalSharesPerOutcome
        });
    }

    function getCommitted(bytes32 proposalId, address user) external view returns (uint256[] memory) {
        return proposals[proposalId].committed[user];
    }

    function hasClaimed(bytes32 proposalId, address user) external view returns (bool) {
        return proposals[proposalId].claimed[user];
    }

    function getMarketKey(string calldata name, uint16 year, string calldata region) external pure returns (bytes32) {
        string memory upperRegion = bytes(region).length > 0 ? _toUpperCase(region) : region;
        return keccak256(abi.encode(_toLowerCase(name), year, upperRegion));
    }

    function getProposalByMarketKey(string calldata name, uint16 year, string calldata region)
        external
        view
        returns (bytes32)
    {
        string memory upperRegion = bytes(region).length > 0 ? _toUpperCase(region) : region;
        bytes32 key = keccak256(abi.encode(_toLowerCase(name), year, upperRegion));
        return marketKeyToProposal[key];
    }

    // ========== INTERNAL ==========

    function _toLowerCase(string memory str) internal pure returns (string memory) {
        bytes memory bStr = bytes(str);
        bytes memory bLower = new bytes(bStr.length);
        for (uint256 i; i < bStr.length; i++) {
            if (bStr[i] >= 0x41 && bStr[i] <= 0x5A) {
                bLower[i] = bytes1(uint8(bStr[i]) + 32);
            } else {
                bLower[i] = bStr[i];
            }
        }
        return string(bLower);
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
