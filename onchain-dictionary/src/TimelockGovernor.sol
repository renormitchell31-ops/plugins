// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title TimelockGovernor
/// @notice Two-step owner that can only mutate the registry after a delay.
///         Intended as `DictionaryRegistry.governor`.
contract TimelockGovernor {
    uint64 private constant _MIN_DELAY = 1 hours;
    uint64 private constant _MAX_DELAY = 30 days;

    error ZeroAddress();
    error InvalidDelay();
    error NotOwner();
    error NotPendingOwner();
    error AlreadyQueued();
    error NotQueued();
    error NotReady();
    error Expired();
    error CallFailed(bytes data);

    event Queued(bytes32 indexed id, address indexed target, uint256 value, bytes data, uint64 eta);
    event Executed(bytes32 indexed id, address indexed target);
    event Cancelled(bytes32 indexed id);
    event OwnerTransferStarted(address indexed from, address indexed to);
    event OwnerTransferred(address indexed from, address indexed to);

    address public owner;
    address public pendingOwner;
    uint64 public immutable delay;
    uint64 public immutable grace;
    mapping(bytes32 => uint64) public etaOf;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, uint64 delay_, uint64 grace_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (delay_ < _MIN_DELAY || delay_ > _MAX_DELAY || grace_ < _MIN_DELAY || grace_ > _MAX_DELAY)
        {
            revert InvalidDelay();
        }
        owner = owner_;
        delay = delay_;
        grace = grace_;
    }

    function idOf(address target, uint256 value, bytes calldata data)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(target, value, data));
    }

    function queue(address target, uint256 value, bytes calldata data)
        external
        onlyOwner
        returns (bytes32 id)
    {
        if (target == address(0)) revert ZeroAddress();
        id = idOf(target, value, data);
        if (etaOf[id] != 0) revert AlreadyQueued();
        uint64 eta = uint64(block.timestamp) + delay;
        etaOf[id] = eta;
        emit Queued(id, target, value, data, eta);
    }

    function execute(address target, uint256 value, bytes calldata data) external payable {
        bytes32 id = idOf(target, value, data);
        uint64 eta = etaOf[id];
        if (eta == 0) revert NotQueued();
        if (block.timestamp < eta) revert NotReady();
        if (block.timestamp > uint256(eta) + grace) revert Expired();
        etaOf[id] = 0;
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        if (!ok) revert CallFailed(ret);
        emit Executed(id, target);
    }

    function cancel(address target, uint256 value, bytes calldata data) external onlyOwner {
        bytes32 id = idOf(target, value, data);
        if (etaOf[id] == 0) revert NotQueued();
        etaOf[id] = 0;
        emit Cancelled(id);
    }

    function transferOwner(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        pendingOwner = next;
        emit OwnerTransferStarted(owner, next);
    }

    function acceptOwner() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address prev = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerTransferred(prev, msg.sender);
    }
}
