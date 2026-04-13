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
    enum Gender {
        BOY,
        GIRL
    }

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

    /// @notice Merkle root of valid SSA names by gender (0 = no whitelist enforced for that gender)
    mapping(uint8 => bytes32) public namesMerkleRoot;

    /// @notice Names manually approved by owner (keccak256(lowercased, gender) => true)
    mapping(bytes32 => bool) public approvedNames;
    mapping(bytes32 => bool) public proposedNames;

    // ========== YEAR LIFECYCLE ==========

    /// @notice Whether a year is open for new proposals. Years are locked by default.
    mapping(uint16 => bool) public yearOpen;
    mapping(uint16 => uint256) public yearLaunchDate;

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
    uint256 public constant MIN_TOTAL_COMMITMENT = 1e6;

    /// @notice Maximum total creation fee for phantom shares (in USDC, 6 decimals)
    uint256 public maxCreationFee = 10e6;

    // ========== LAUNCH TRIGGERS ==========

    /// @notice For post-batch proposals: time after proposal creation when it auto-qualifies for launch
    uint256 public postBatchTimeout = 24 hours;
    uint256 public postBatchMinThreshold = 10e6;

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
        Gender gender;
        uint256 launchTs;
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
        bool requiresApproval;
    }

    struct ProposalStorage {
        bytes32 questionId;
        address oracle;
        bytes metadata;
        string[] outcomeNames;
        Gender gender;
        uint256 customLaunchTs;
        bool useYearLaunchSchedule;
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
        bool requiresApproval;
    }

    mapping(bytes32 => ProposalStorage) internal proposals;
    mapping(bytes32 => bytes32) public questionIdToProposal;

    /// @notice Maps market key hash(name, year, region) to proposalId.
    ///         Prevents duplicate proposals for the same (name, year, region) combination.
    mapping(bytes32 => bytes32) public marketKeyToProposal;

    mapping(address => uint256) public pendingRefunds;

    // ========== BUY PROXY ==========

    /// @notice Trading fee for buy() proxy, in bps (3% = 300, matching PM default)
    uint256 public proxyTradingFeeBps = 300;
    uint256 public constant MAX_PROXY_TRADING_FEE_BPS = 1000;

    // ========== REENTRANCY ==========

    uint256 private _locked;

    // ========== EVENTS ==========

    event ProposalCreated(
        bytes32 indexed proposalId,
        bytes32 indexed questionId,
        string name,
        Gender gender,
        uint16 year,
        string region,
        address proposer,
        uint256 launchTs
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
    event NamesMerkleRootUpdated(Gender indexed gender, bytes32 oldRoot, bytes32 newRoot);
    event NameApproved(string name, Gender indexed gender);
    event NameProposed(string name, Gender indexed gender, address indexed proposer);
    event DefaultOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event DefaultDeadlineDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event DefaultRegionsSeeded();
    event YearOpened(uint16 indexed year);
    event YearClosed(uint16 indexed year);
    event RegionAdded(string region);
    event RegionRemoved(string region);
    event CommitmentFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event MaxCreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event YearLaunchDateUpdated(uint16 indexed year, uint256 oldDate, uint256 newDate);
    event PostBatchMinThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event PostBatchTimeoutUpdated(uint256 oldTimeout, uint256 newTimeout);
    event ProposalApproved(bytes32 indexed proposalId);
    event ProxyBuy(
        bytes32 indexed proposalId,
        bytes32 indexed marketId,
        address indexed trader,
        int256 costDelta,
        uint256 fee
    );
    event ProxyTradingFeeBpsUpdated(uint256 oldBps, uint256 newBps);

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
    error InvalidFee();
    error CommitmentsFinal();
    error DuplicateQuestionId();
    error InvalidGender();
    error NameNotApproved();
    error BuyOnly();
    error NotCancelled();
    error Reentrancy();
    error AlreadyApproved();

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

    function setNamesMerkleRoot(Gender gender, bytes32 _root) external onlyOwner {
        uint8 g = uint8(gender);
        emit NamesMerkleRootUpdated(gender, namesMerkleRoot[g], _root);
        namesMerkleRoot[g] = _root;
    }

    function approveName(string calldata name, Gender gender) external onlyOwner {
        bytes32 nameHash = _nameKey(_toLowerCase(name), gender);
        approvedNames[nameHash] = true;
        proposedNames[nameHash] = false;
        emit NameApproved(name, gender);
    }

    function proposeName(string calldata name, Gender gender) external {
        bytes32 nameHash = _nameKey(_toLowerCase(name), gender);
        proposedNames[nameHash] = true;
        emit NameProposed(name, gender, msg.sender);
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
        if (_bps == 0) revert InvalidFee();
        if (_bps > MAX_COMMITMENT_FEE_BPS) revert FeeTooHigh();
        emit CommitmentFeeBpsUpdated(commitmentFeeBps, _bps);
        commitmentFeeBps = _bps;
    }

    function setMaxCreationFee(uint256 _maxFee) external onlyOwner {
        emit MaxCreationFeeUpdated(maxCreationFee, _maxFee);
        maxCreationFee = _maxFee;
    }

    function setYearLaunchDate(uint16 year, uint256 _date) external onlyOwner {
        if (year == 0) revert InvalidYear();
        emit YearLaunchDateUpdated(year, yearLaunchDate[year], _date);
        yearLaunchDate[year] = _date;
    }

    function setPostBatchMinThreshold(uint256 _threshold) external onlyOwner {
        emit PostBatchMinThresholdUpdated(postBatchMinThreshold, _threshold);
        postBatchMinThreshold = _threshold;
    }

    function setPostBatchTimeout(uint256 _timeout) external onlyOwner {
        emit PostBatchTimeoutUpdated(postBatchTimeout, _timeout);
        postBatchTimeout = _timeout;
    }

    function setProxyTradingFeeBps(uint256 _bps) external onlyOwner {
        if (_bps > MAX_PROXY_TRADING_FEE_BPS) revert FeeTooHigh();
        emit ProxyTradingFeeBpsUpdated(proxyTradingFeeBps, _bps);
        proxyTradingFeeBps = _bps;
    }

    function setUsdcAllowance(uint256 amount) external onlyOwner {
        usdc.approve(address(predictionMarket), amount);
    }

    function withdrawUsdc(uint256 amount, address to) external onlyOwner {
        if (!usdc.transfer(to, amount)) revert TransferFailed();
    }

    function _nameKey(string memory loweredName, Gender gender) internal pure returns (bytes32) {
        return keccak256(abi.encode(loweredName, gender));
    }

    function _launchTimestamp(ProposalStorage storage prop) internal view returns (uint256) {
        if (prop.customLaunchTs != 0) return prop.customLaunchTs;
        if (prop.useYearLaunchSchedule) {
            uint256 scheduled = yearLaunchDate[prop.year];
            if (scheduled != 0) return scheduled;
        }
        return prop.createdAt + postBatchTimeout;
    }

    // ========== NAME VALIDATION ==========

    function isValidName(string memory name, Gender gender, bytes32[] calldata proof) public view returns (bool) {
        bytes32 root = namesMerkleRoot[uint8(gender)];
        if (root == bytes32(0)) return true;

        string memory lowered = _toLowerCase(name);
        bytes32 nameHash = _nameKey(lowered, gender);

        if (approvedNames[nameHash]) return true;

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(lowered, gender))));
        return MerkleProofLib.verify(proof, root, leaf);
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
    function propose(
        string calldata name,
        uint16 year,
        Gender gender,
        bytes32[] calldata proof,
        uint256[] calldata amounts
    )
        external
        returns (bytes32)
    {
        return _propose(name, year, gender, "", proof, amounts);
    }

    function proposeWithPermit(
        string calldata name,
        uint16 year,
        Gender gender,
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
        return _propose(name, year, gender, "", proof, amounts);
    }

    /**
     * @notice Proposes a market for a name in a specific region.
     *         Region is a state abbreviation (e.g. "CA") or "" for national.
     */
    function proposeRegional(
        string calldata name,
        uint16 year,
        Gender gender,
        string calldata region,
        bytes32[] calldata proof,
        uint256[] calldata amounts
    ) external returns (bytes32) {
        return _propose(name, year, gender, region, proof, amounts);
    }

    function _propose(
        string calldata name,
        uint16 year,
        Gender gender,
        string memory region,
        bytes32[] calldata proof,
        uint256[] calldata amounts
    ) internal returns (bytes32) {
        bool nameValid = isValidName(name, gender, proof);
        if (!yearOpen[year]) revert YearNotOpen();
        if (!isValidRegion(region)) revert InvalidRegion();
        if (defaultOracle == address(0)) revert DefaultsNotSet();
        string memory lowered = _toLowerCase(name);
        // Store region as uppercase abbreviation (or "" for national)
        string memory upperRegion = bytes(region).length > 0 ? _toUpperCase(region) : region;

        // Unique key per (name, gender, year, region)
        bytes32 marketKey = keccak256(abi.encode(lowered, gender, year, upperRegion));

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

        // questionId: launchpad address (20 bytes) + hash(name, gender, year, region) truncated (12 bytes)
        bytes32 questionId = bytes32(
            (uint256(uint160(address(this))) << 96) | uint256(uint96(bytes12(marketKey)))
        );
        if (questionIdToProposal[questionId] != bytes32(0)) revert DuplicateQuestionId();

        bytes32 proposalId =
            keccak256(abi.encodePacked(address(this), block.chainid, questionId, block.timestamp));
        if (proposals[proposalId].createdAt != 0) revert ProposalExists();

        string[] memory outcomeNames = new string[](2);
        outcomeNames[0] = "YES";
        outcomeNames[1] = "NO";

        uint256 launchTs = yearLaunchDate[year] > block.timestamp
            ? yearLaunchDate[year]
            : block.timestamp + postBatchTimeout;

        ProposalStorage storage prop = proposals[proposalId];
        prop.questionId = questionId;
        prop.oracle = defaultOracle;
        prop.metadata = abi.encode(lowered, gender, year, upperRegion);
        prop.outcomeNames = outcomeNames;
        prop.gender = gender;
        prop.useYearLaunchSchedule = yearLaunchDate[year] > block.timestamp;
        prop.createdAt = block.timestamp;
        prop.state = ProposalState.OPEN;
        prop.totalPerOutcome = new uint256[](2);
        prop.name = lowered;
        prop.year = year;
        prop.region = upperRegion;
        prop.requiresApproval = !nameValid;

        marketKeyToProposal[marketKey] = proposalId;
        questionIdToProposal[questionId] = proposalId;

        emit ProposalCreated(
            proposalId, questionId, lowered, gender, year, upperRegion, msg.sender, launchTs
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
        Gender gender,
        uint16 year,
        string calldata region,
        uint256 launchTs
    ) external onlyOwner returns (bytes32) {
        if (outcomeNames.length < 2) revert InvalidOutcomes();
        if (oracle == address(0)) revert InvalidOracle();
        if (year == 0) revert InvalidYear();
        if (uint8(gender) > uint8(Gender.GIRL)) revert InvalidGender();

        uint256 _launchTs = launchTs > 0
            ? launchTs
            : (yearLaunchDate[year] > block.timestamp)
                ? yearLaunchDate[year]
                : block.timestamp + postBatchTimeout;
        if (_launchTs <= block.timestamp) revert InvalidDeadline();

        bytes32 metaHash = keccak256(abi.encode(metadata, gender, year, region));
        bytes32 questionId = bytes32(
            (uint256(uint160(address(this))) << 96) | uint256(uint96(bytes12(metaHash)))
        );
        if (questionIdToProposal[questionId] != bytes32(0)) revert DuplicateQuestionId();

        bytes32 proposalId =
            keccak256(abi.encodePacked(address(this), block.chainid, questionId, block.timestamp));
        if (proposals[proposalId].createdAt != 0) revert ProposalExists();

        ProposalStorage storage prop = proposals[proposalId];
        prop.questionId = questionId;
        prop.oracle = oracle;
        prop.metadata = metadata;
        prop.outcomeNames = outcomeNames;
        prop.gender = gender;
        prop.customLaunchTs = launchTs;
        prop.useYearLaunchSchedule = launchTs == 0 && yearLaunchDate[year] > block.timestamp;
        prop.createdAt = block.timestamp;
        prop.state = ProposalState.OPEN;
        prop.totalPerOutcome = new uint256[](outcomeNames.length);
        prop.year = year;
        prop.region = bytes(region).length > 0 ? _toUpperCase(region) : region;
        questionIdToProposal[questionId] = proposalId;

        emit ProposalCreated(proposalId, questionId, "", gender, year, prop.region, msg.sender, _launchTs);

        return proposalId;
    }

    // ========== COMMITMENT ==========

    function commit(bytes32 proposalId, uint256[] calldata amounts) external {
        ProposalStorage storage prop = proposals[proposalId];
        if (prop.state != ProposalState.OPEN) revert NotOpen();
        if (block.timestamp >= _launchTimestamp(prop)) revert DeadlinePassed();
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
        if (block.timestamp >= _launchTimestamp(prop)) revert DeadlinePassed();
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
     *         Idempotent — no-op if already launched.
     */
    function launchMarket(bytes32 proposalId) external {
        _ensureLaunched(proposalId);
    }

    function _ensureLaunched(bytes32 proposalId) internal {
        ProposalStorage storage prop = proposals[proposalId];
        if (prop.state == ProposalState.LAUNCHED) return;
        if (prop.state != ProposalState.OPEN) revert NotOpen();
        if (prop.requiresApproval) revert NameNotApproved();
        if (block.timestamp < _launchTimestamp(prop)) revert NotEligibleForLaunch();
        _launchCore(proposalId);
    }

    /**
     * @dev Core launch logic: fee math, market creation, binary search, aggregate trade.
     *      Caller must have already validated state, approval, and timing.
     */
    function _launchCore(bytes32 proposalId) internal {
        ProposalStorage storage prop = proposals[proposalId];

        if (prop.totalCommitted < MIN_TOTAL_COMMITMENT) revert BelowThreshold();

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

        uint256 balanceBeforeCreate = usdc.balanceOf(address(this));
        bytes32 marketId = predictionMarket.createMarket(params);
        uint256 balanceAfterCreate = usdc.balanceOf(address(this));
        prop.marketId = marketId;

        // 2. Binary search for aggregate trade using only this proposal's remaining budget.
        PredictionMarket.MarketInfo memory info = predictionMarket.getMarketInfo(marketId);
        uint256 creationCostCharged = balanceBeforeCreate - balanceAfterCreate;
        uint256 tradingBudget = prop.totalCommitted - excessFees - creationCostCharged;
        int256[] memory deltaShares = _computeAggregateShares(info, prop.totalPerOutcome, tradingBudget);

        // 3. Execute aggregate trade
        uint256 balBeforeTrade = usdc.balanceOf(address(this));
        {
            bool hasNonZero;
            for (uint256 i; i < n; i++) {
                if (deltaShares[i] != 0) {
                    hasNonZero = true;
                    break;
                }
            }

            if (hasNonZero) {
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

        // 4. Store results for claimShares()
        prop.tradingBudget = tradingBudget;
        uint256 balAfterTrade = usdc.balanceOf(address(this));
        prop.actualCost = balBeforeTrade > balAfterTrade ? balBeforeTrade - balAfterTrade : 0;
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
        if (_locked != 0) revert Reentrancy();
        _locked = 1;

        _ensureLaunched(proposalId);

        ProposalStorage storage prop = proposals[proposalId];
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

        _locked = 0;
    }

    // ========== BUY PROXY ==========

    /**
     * @notice Buy outcome tokens with lazy launch. If the market hasn't launched yet
     *         (but is past the commit window), this triggers the launch first.
     *         Buy-only — sells go directly through PredictionMarket.
     * @param proposalId The proposal to buy into
     * @param deltaShares Per-outcome share amounts to buy (must all be >= 0)
     * @param maxCost Maximum USDC to spend (including proxy fee)
     * @param deadline Block timestamp deadline for the trade
     */
    function buy(
        bytes32 proposalId,
        int256[] calldata deltaShares,
        uint256 maxCost,
        uint256 deadline
    ) external returns (int256) {
        if (_locked != 0) revert Reentrancy();
        _locked = 1;

        _ensureLaunched(proposalId);

        ProposalStorage storage prop = proposals[proposalId];
        bytes32 marketId = prop.marketId;
        uint256 n = deltaShares.length;

        // Buy-only: all deltas must be non-negative
        for (uint256 i; i < n; i++) {
            if (deltaShares[i] < 0) revert BuyOnly();
        }

        // Pull maxCost USDC from user
        if (!usdc.transferFrom(msg.sender, address(this), maxCost)) revert TransferFailed();

        // Execute fee-exempt trade via tradeRaw
        int256 costDelta = predictionMarket.tradeRaw(
            PredictionMarket.Trade({
                marketId: marketId,
                deltaShares: deltaShares,
                maxCost: maxCost, // tradeRaw will revert if LMSR cost exceeds this
                minPayout: 0,
                deadline: deadline
            })
        );

        uint256 lmsrCost = uint256(costDelta);

        // Compute fee on top of LMSR cost (matching PM formula)
        uint256 fee;
        if (proxyTradingFeeBps > 0) {
            fee = FixedPointMathLib.mulDiv(lmsrCost, proxyTradingFeeBps, 10000 - proxyTradingFeeBps);
        }

        // Send fee to surplus recipient
        if (fee > 0) {
            if (!usdc.transfer(surplusRecipient, fee)) revert TransferFailed();
        }

        // Transfer outcome tokens to user
        PredictionMarket.MarketInfo memory mInfo = predictionMarket.getMarketInfo(marketId);
        for (uint256 i; i < n; i++) {
            if (deltaShares[i] > 0) {
                if (!IERC20(mInfo.outcomeTokens[i]).transfer(msg.sender, uint256(deltaShares[i]))) {
                    revert TransferFailed();
                }
            }
        }

        // Refund unused USDC
        uint256 totalSpent = lmsrCost + fee;
        if (totalSpent < maxCost) {
            if (!usdc.transfer(msg.sender, maxCost - totalSpent)) revert TransferFailed();
        }

        emit ProxyBuy(proposalId, marketId, msg.sender, costDelta, fee);

        _locked = 0;
        return costDelta;
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

    // ========== APPROVAL / CANCEL ==========

    function approveProposal(bytes32 proposalId) external onlyOwner {
        ProposalStorage storage prop = proposals[proposalId];
        if (prop.state != ProposalState.OPEN) revert NotOpen();
        if (!prop.requiresApproval) revert AlreadyApproved();
        prop.requiresApproval = false;
        bytes32 nameHash = _nameKey(prop.name, prop.gender);
        approvedNames[nameHash] = true;
        emit NameApproved(prop.name, prop.gender);
        emit ProposalApproved(proposalId);
    }

    function cancelProposal(bytes32 proposalId) external onlyOwner {
        ProposalStorage storage prop = proposals[proposalId];
        if (prop.state != ProposalState.OPEN) revert NotOpen();
        if (!prop.requiresApproval) revert CommitmentsFinal();
        prop.state = ProposalState.CANCELLED;
        // Clear mappings so the same name can be re-proposed
        questionIdToProposal[prop.questionId] = bytes32(0);
        emit ProposalCancelled(proposalId);
    }

    // ========== WITHDRAWALS ==========

    function withdrawCommitment(bytes32 proposalId) external {
        ProposalStorage storage prop = proposals[proposalId];
        if (prop.state != ProposalState.CANCELLED) revert NotCancelled();
        uint256 gross = prop.committedGross[msg.sender];
        if (gross == 0) revert NothingToClaim();
        prop.committedGross[msg.sender] = 0;
        pendingRefunds[msg.sender] += gross;
        emit CommitmentWithdrawn(proposalId, msg.sender, gross);
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
            gender: prop.gender,
            launchTs: _launchTimestamp(prop),
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
            totalSharesPerOutcome: prop.totalSharesPerOutcome,
            requiresApproval: prop.requiresApproval
        });
    }

    function getCommitted(bytes32 proposalId, address user) external view returns (uint256[] memory) {
        return proposals[proposalId].committed[user];
    }

    function hasClaimed(bytes32 proposalId, address user) external view returns (bool) {
        return proposals[proposalId].claimed[user];
    }

    function getMarketKey(string calldata name, Gender gender, uint16 year, string calldata region)
        external
        pure
        returns (bytes32)
    {
        string memory upperRegion = bytes(region).length > 0 ? _toUpperCase(region) : region;
        return keccak256(abi.encode(_toLowerCase(name), gender, year, upperRegion));
    }

    function getProposalByMarketKey(string calldata name, Gender gender, uint16 year, string calldata region)
        external
        view
        returns (bytes32)
    {
        string memory upperRegion = bytes(region).length > 0 ? _toUpperCase(region) : region;
        bytes32 key = keccak256(abi.encode(_toLowerCase(name), gender, year, upperRegion));
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
