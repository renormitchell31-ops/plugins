// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title DictionaryRegistry
/// @notice Bonded, challengeable on-chain dictionary. Canonical entries are
///         only written after an optimistic window or an arbiter ruling.
///         Ether never leaves via push; losers/winners pull bonds.
contract DictionaryRegistry {
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private constant _MAX_SENSES = 4;
    uint256 private constant _MAX_TERM = 64;
    uint256 private constant _MAX_DEF = 280;
    uint256 private constant _MAX_PHON = 64;
    uint256 private constant _MAX_EX = 160;
    uint256 private constant _MAX_CID = 128;
    uint64 private constant _MIN_PERIOD = 1 hours;
    uint64 private constant _MAX_PERIOD = 30 days;

    enum Status {
        None,
        Pending,
        Finalized,
        Rejected
    }

    struct Sense {
        bytes12 partOfSpeech;
        string definition;
        string phonetic;
        string example;
        string ipfsCid;
    }

    struct Proposal {
        bytes32 termId;
        address submitter;
        uint64 submittedAt;
        uint64 challengeDeadline;
        uint128 bond;
        uint64 challengeId;
        Status status;
        bytes2 lang;
        string term;
    }

    struct Challenge {
        address challenger;
        uint64 createdAt;
        uint64 resolveDeadline;
        uint128 bond;
        string reason;
    }

    struct Config {
        uint128 minBond;
        uint64 challengePeriod;
        uint64 resolvePeriod;
    }

    error ZeroAddress();
    error NotGovernor();
    error NotPendingGovernor();
    error NotGuardian();
    error NotArbiter();
    error Paused();
    error DirectPayment();
    error Reentrancy();
    error InvalidConfig();
    error InvalidTerm();
    error InvalidLang();
    error InvalidSense();
    error TooManySenses();
    error BondTooSmall();
    error BondMismatch();
    error BondTooLarge();
    error AlreadyPending();
    error NotPending();
    error ChallengeWindowClosed();
    error AlreadyChallenged();
    error NotChallenged();
    error FinalizeTooEarly();
    error ChallengeOpen();
    error ArbiterWindowClosed();
    error ArbiterStillActive();
    error NothingToWithdraw();
    error WithdrawFailed();
    error UnknownProposal();
    error ReasonTooLong();

    event Proposed(
        uint256 indexed proposalId,
        bytes32 indexed termId,
        address indexed submitter,
        bytes2 lang,
        string term,
        uint128 bond,
        uint64 challengeDeadline
    );
    event Challenged(
        uint256 indexed proposalId,
        uint64 indexed challengeId,
        address indexed challenger,
        uint128 bond
    );
    event Finalized(uint256 indexed proposalId, bytes32 indexed termId, uint64 version);
    event Resolved(uint256 indexed proposalId, bool accepted, address indexed arbiter);
    event TimedOut(uint256 indexed proposalId);
    event Withdrawn(address indexed account, uint256 amount);
    event PausedSet(bool paused);
    event ConfigSet(uint128 minBond, uint64 challengePeriod, uint64 resolvePeriod);
    event ArbiterSet(address indexed arbiter);
    event GuardianSet(address indexed guardian);
    event GovernorTransferStarted(address indexed from, address indexed to);
    event GovernorTransferred(address indexed from, address indexed to);

    address public governor;
    address public pendingGovernor;
    address public arbiter;
    address public guardian;
    bool public paused;
    Config public config;

    uint256 public proposalCount;
    uint256 private _reentrancy = _NOT_ENTERED;

    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => Sense[]) private _senses;
    mapping(uint64 => Challenge) private _challenges;
    uint64 public challengeCount;

    mapping(bytes32 => uint256) public pendingProposalId;
    mapping(bytes32 => uint256) public canonicalProposalId;
    mapping(bytes32 => uint64) public versionOf;
    mapping(address => uint256) public pendingWithdrawals;

    modifier nonReentrant() {
        if (_reentrancy == _ENTERED) revert Reentrancy();
        _reentrancy = _ENTERED;
        _;
        _reentrancy = _NOT_ENTERED;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    constructor(
        address governor_,
        address arbiter_,
        address guardian_,
        uint128 minBond_,
        uint64 challengePeriod_,
        uint64 resolvePeriod_
    ) {
        if (governor_ == address(0) || arbiter_ == address(0) || guardian_ == address(0)) {
            revert ZeroAddress();
        }
        _validateConfig(minBond_, challengePeriod_, resolvePeriod_);
        governor = governor_;
        arbiter = arbiter_;
        guardian = guardian_;
        config = Config(minBond_, challengePeriod_, resolvePeriod_);
    }

    receive() external payable {
        revert DirectPayment();
    }

    fallback() external payable {
        revert DirectPayment();
    }

    function propose(string calldata term, bytes2 lang, Sense[] calldata senses)
        external
        payable
        whenNotPaused
        returns (uint256 proposalId)
    {
        _validateTerm(term);
        _validateLang(lang);
        uint256 n = senses.length;
        if (n == 0 || n > _MAX_SENSES) revert TooManySenses();
        if (msg.value > type(uint128).max) revert BondTooLarge();
        if (msg.value < config.minBond) revert BondTooSmall();

        bytes32 termId = idOf(term, lang);
        if (pendingProposalId[termId] != 0) revert AlreadyPending();

        proposalId = ++proposalCount;
        uint64 deadline = uint64(block.timestamp) + config.challengePeriod;
        pendingProposalId[termId] = proposalId;
        _proposals[proposalId] = Proposal({
            termId: termId,
            submitter: msg.sender,
            submittedAt: uint64(block.timestamp),
            challengeDeadline: deadline,
            bond: uint128(msg.value),
            challengeId: 0,
            status: Status.Pending,
            lang: lang,
            term: term
        });
        for (uint256 i; i < n; ++i) {
            _validateSense(senses[i]);
            _senses[proposalId].push(senses[i]);
        }
        emit Proposed(proposalId, termId, msg.sender, lang, term, uint128(msg.value), deadline);
    }

    function challenge(uint256 proposalId, string calldata reason)
        external
        payable
        whenNotPaused
        returns (uint64 id)
    {
        Proposal storage p = _requirePending(proposalId);
        if (block.timestamp > p.challengeDeadline) revert ChallengeWindowClosed();
        if (p.challengeId != 0) revert AlreadyChallenged();
        if (bytes(reason).length == 0 || bytes(reason).length > _MAX_DEF) revert ReasonTooLong();
        if (msg.value != p.bond) revert BondMismatch();

        id = ++challengeCount;
        p.challengeId = id;
        _challenges[id] = Challenge({
            challenger: msg.sender,
            createdAt: uint64(block.timestamp),
            resolveDeadline: uint64(block.timestamp) + config.resolvePeriod,
            bond: uint128(msg.value),
            reason: reason
        });
        emit Challenged(proposalId, id, msg.sender, uint128(msg.value));
    }

    function finalize(uint256 proposalId) external {
        Proposal storage p = _requirePending(proposalId);
        if (p.challengeId != 0) revert ChallengeOpen();
        if (block.timestamp <= p.challengeDeadline) revert FinalizeTooEarly();
        _accept(proposalId, p);
    }

    function resolve(uint256 proposalId, bool accept) external {
        if (msg.sender != arbiter) revert NotArbiter();
        Proposal storage p = _requirePending(proposalId);
        if (p.challengeId == 0) revert NotChallenged();
        Challenge storage c = _challenges[p.challengeId];
        if (block.timestamp > c.resolveDeadline) revert ArbiterWindowClosed();
        if (accept) {
            pendingWithdrawals[p.submitter] += uint256(p.bond) + uint256(c.bond);
            _accept(proposalId, p);
        } else {
            pendingWithdrawals[c.challenger] += uint256(p.bond) + uint256(c.bond);
            _reject(proposalId, p);
        }
        emit Resolved(proposalId, accept, msg.sender);
    }

    function timeout(uint256 proposalId) external {
        Proposal storage p = _requirePending(proposalId);
        if (p.challengeId == 0) revert NotChallenged();
        Challenge storage c = _challenges[p.challengeId];
        if (block.timestamp <= c.resolveDeadline) revert ArbiterStillActive();
        pendingWithdrawals[p.submitter] += p.bond;
        pendingWithdrawals[c.challenger] += c.bond;
        _reject(proposalId, p);
        emit TimedOut(proposalId);
    }

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawn(msg.sender, amount);
    }

    function setPaused(bool value) external {
        if (msg.sender != guardian && msg.sender != governor) revert NotGuardian();
        paused = value;
        emit PausedSet(value);
    }

    function setConfig(uint128 minBond_, uint64 challengePeriod_, uint64 resolvePeriod_)
        external
        onlyGovernor
    {
        _validateConfig(minBond_, challengePeriod_, resolvePeriod_);
        config = Config(minBond_, challengePeriod_, resolvePeriod_);
        emit ConfigSet(minBond_, challengePeriod_, resolvePeriod_);
    }

    function setArbiter(address next) external onlyGovernor {
        if (next == address(0)) revert ZeroAddress();
        arbiter = next;
        emit ArbiterSet(next);
    }

    function setGuardian(address next) external onlyGovernor {
        if (next == address(0)) revert ZeroAddress();
        guardian = next;
        emit GuardianSet(next);
    }

    function transferGovernor(address next) external onlyGovernor {
        if (next == address(0)) revert ZeroAddress();
        pendingGovernor = next;
        emit GovernorTransferStarted(governor, next);
    }

    function acceptGovernor() external {
        if (msg.sender != pendingGovernor) revert NotPendingGovernor();
        address prev = governor;
        governor = msg.sender;
        pendingGovernor = address(0);
        emit GovernorTransferred(prev, msg.sender);
    }

    function idOf(string memory term, bytes2 lang) public pure returns (bytes32) {
        return keccak256(abi.encode(lang, keccak256(bytes(term))));
    }

    function proposal(uint256 proposalId) external view returns (Proposal memory) {
        return _proposals[proposalId];
    }

    function challengeOf(uint64 id) external view returns (Challenge memory) {
        return _challenges[id];
    }

    function sensesOf(uint256 proposalId) external view returns (Sense[] memory) {
        return _senses[proposalId];
    }

    function get(string calldata term, bytes2 lang)
        external
        view
        returns (bool exists, uint64 version, address curator, Sense[] memory senses)
    {
        bytes32 termId = idOf(term, lang);
        uint256 pid = canonicalProposalId[termId];
        if (pid == 0) return (false, 0, address(0), senses);
        Proposal storage p = _proposals[pid];
        return (true, versionOf[termId], p.submitter, _senses[pid]);
    }

    function _accept(uint256 proposalId, Proposal storage p) private {
        p.status = Status.Finalized;
        pendingProposalId[p.termId] = 0;
        canonicalProposalId[p.termId] = proposalId;
        uint64 v = versionOf[p.termId] + 1;
        versionOf[p.termId] = v;
        if (p.challengeId == 0) {
            pendingWithdrawals[p.submitter] += p.bond;
        }
        emit Finalized(proposalId, p.termId, v);
    }

    function _reject(uint256, Proposal storage p) private {
        p.status = Status.Rejected;
        pendingProposalId[p.termId] = 0;
    }

    function _requirePending(uint256 proposalId) private view returns (Proposal storage p) {
        if (proposalId == 0 || proposalId > proposalCount) revert UnknownProposal();
        p = _proposals[proposalId];
        if (p.status != Status.Pending) revert NotPending();
    }

    function _validateConfig(uint128 minBond_, uint64 challengePeriod_, uint64 resolvePeriod_)
        private
        pure
    {
        if (
            minBond_ == 0 || challengePeriod_ < _MIN_PERIOD || challengePeriod_ > _MAX_PERIOD
                || resolvePeriod_ < _MIN_PERIOD || resolvePeriod_ > _MAX_PERIOD
        ) {
            revert InvalidConfig();
        }
    }

    function _validateTerm(string calldata term) private pure {
        bytes memory b = bytes(term);
        uint256 len = b.length;
        if (len == 0 || len > _MAX_TERM) revert InvalidTerm();
        for (uint256 i; i < len; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x27;
            if (!ok) revert InvalidTerm();
        }
    }

    function _validateLang(bytes2 lang) private pure {
        bytes1 a = lang[0];
        bytes1 b = lang[1];
        if (!(a >= 0x61 && a <= 0x7A && b >= 0x61 && b <= 0x7A)) revert InvalidLang();
    }

    function _validateSense(Sense calldata s) private pure {
        uint256 defLen = bytes(s.definition).length;
        if (defLen == 0 || defLen > _MAX_DEF) revert InvalidSense();
        if (bytes(s.phonetic).length > _MAX_PHON) revert InvalidSense();
        if (bytes(s.example).length > _MAX_EX) revert InvalidSense();
        if (bytes(s.ipfsCid).length > _MAX_CID) revert InvalidSense();
        for (uint256 i; i < 12; ++i) {
            bytes1 c = s.partOfSpeech[i];
            if (c == 0) continue;
            if (c < 0x61 || c > 0x7A) revert InvalidSense();
        }
    }
}
