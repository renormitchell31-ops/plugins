// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DictionaryRegistry} from "../src/DictionaryRegistry.sol";

interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function deal(address, uint256) external;
    function expectRevert(bytes4) external;
}

contract ReentrantWithdrawer {
    DictionaryRegistry public registry;
    uint256 public hits;

    constructor(DictionaryRegistry registry_) {
        registry = registry_;
    }

    receive() external payable {
        ++hits;
        if (hits < 3) {
            try registry.withdraw() {} catch {}
        }
    }

    function propose(uint256 bond) external payable {
        DictionaryRegistry.Sense[] memory senses = new DictionaryRegistry.Sense[](1);
        senses[0] = DictionaryRegistry.Sense(bytes12("noun"), "a term", "", "", "");
        registry.propose{value: bond}("reentry", "en", senses);
    }
}

contract DictionaryRegistryTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    DictionaryRegistry internal registry;
    address internal governor;
    address internal arbiter;
    address internal guardian;
    address internal alice;
    address internal bob;

    uint128 internal constant BOND = 0.1 ether;
    uint64 internal constant PERIOD = 1 hours;

    function setUp() public {
        governor = address(0xA11CE);
        arbiter = address(0xA4B17E4);
        guardian = address(0x6A4D1A4);
        alice = address(0xA11A);
        bob = address(0xB0B);
        registry = new DictionaryRegistry(governor, arbiter, guardian, BOND, PERIOD, PERIOD);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(address(this), 10 ether);
    }

    function _sense(string memory def) internal pure returns (DictionaryRegistry.Sense[] memory senses) {
        senses = new DictionaryRegistry.Sense[](1);
        senses[0] = DictionaryRegistry.Sense(bytes12("noun"), def, "surch", "a search result", "");
    }

    function _propose(address who, string memory term, uint256 bond) internal returns (uint256 id) {
        vm.prank(who);
        id = registry.propose{value: bond}(term, "en", _sense("try to find something by looking"));
    }

    function test_proposeFinalizeLookup() public {
        uint256 id = _propose(alice, "search", BOND);
        vm.warp(block.timestamp + PERIOD + 1);
        registry.finalize(id);
        (bool exists, uint64 version, address curator, DictionaryRegistry.Sense[] memory senses) =
            registry.get("search", "en");
        require(exists, "exists");
        require(version == 1, "version");
        require(curator == alice, "curator");
        require(keccak256(bytes(senses[0].definition)) == keccak256("try to find something by looking"), "def");
        vm.prank(alice);
        registry.withdraw();
        require(alice.balance == 10 ether, "bond returned");
    }

    function test_rejectsNonAsciiTerm() public {
        vm.prank(alice);
        vm.expectRevert(DictionaryRegistry.InvalidTerm.selector);
        registry.propose{value: BOND}("Search", "en", _sense("x"));
    }

    function test_rejectsSmallBond() public {
        vm.prank(alice);
        vm.expectRevert(DictionaryRegistry.BondTooSmall.selector);
        registry.propose{value: BOND - 1}("search", "en", _sense("x"));
    }

    function test_cannotFinalizeEarly() public {
        uint256 id = _propose(alice, "search", BOND);
        vm.expectRevert(DictionaryRegistry.FinalizeTooEarly.selector);
        registry.finalize(id);
    }

    function test_duplicatePendingBlocked() public {
        _propose(alice, "search", BOND);
        vm.prank(bob);
        vm.expectRevert(DictionaryRegistry.AlreadyPending.selector);
        registry.propose{value: BOND}("search", "en", _sense("other"));
    }

    function test_challengeAcceptPaysSubmitterBothBonds() public {
        uint256 id = _propose(alice, "gmail", BOND);
        vm.prank(bob);
        registry.challenge{value: BOND}(id, "inaccurate");
        vm.prank(arbiter);
        registry.resolve(id, true);
        (bool exists,,,) = registry.get("gmail", "en");
        require(exists, "canonical");
        require(registry.pendingWithdrawals(alice) == uint256(BOND) * 2, "reward");
        require(registry.pendingWithdrawals(bob) == 0, "loser");
    }

    function test_challengeRejectPaysChallenger() public {
        uint256 id = _propose(alice, "gmail", BOND);
        vm.prank(bob);
        registry.challenge{value: BOND}(id, "spam");
        vm.prank(arbiter);
        registry.resolve(id, false);
        (bool exists,,,) = registry.get("gmail", "en");
        require(!exists, "rejected");
        require(registry.pendingWithdrawals(bob) == uint256(BOND) * 2, "challenger wins");
    }

    function test_timeoutIsDraw() public {
        uint256 id = _propose(alice, "gmail", BOND);
        vm.prank(bob);
        registry.challenge{value: BOND}(id, "unclear");
        vm.warp(block.timestamp + PERIOD + 1);
        registry.timeout(id);
        require(registry.pendingWithdrawals(alice) == BOND, "alice");
        require(registry.pendingWithdrawals(bob) == BOND, "bob");
        (bool exists,,,) = registry.get("gmail", "en");
        require(!exists, "not canonical");
    }

    function test_onlyArbiterResolves() public {
        uint256 id = _propose(alice, "gmail", BOND);
        vm.prank(bob);
        registry.challenge{value: BOND}(id, "no");
        vm.prank(alice);
        vm.expectRevert(DictionaryRegistry.NotArbiter.selector);
        registry.resolve(id, true);
    }

    function test_pauseBlocksPropose() public {
        vm.prank(guardian);
        registry.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(DictionaryRegistry.Paused.selector);
        registry.propose{value: BOND}("search", "en", _sense("x"));
    }

    function test_supersedeIncrementsVersion() public {
        uint256 id = _propose(alice, "search", BOND);
        vm.warp(block.timestamp + PERIOD + 1);
        registry.finalize(id);
        uint256 id2 = _propose(bob, "search", BOND);
        vm.warp(block.timestamp + PERIOD + 1);
        registry.finalize(id2);
        (bool exists, uint64 version, address curator,) = registry.get("search", "en");
        require(exists && version == 2 && curator == bob, "v2");
    }

    function test_withdrawReentrancyDoesNotDrain() public {
        ReentrantWithdrawer attacker = new ReentrantWithdrawer(registry);
        vm.deal(address(attacker), 1 ether);
        attacker.propose{value: BOND}(BOND);
        vm.warp(block.timestamp + PERIOD + 1);
        registry.finalize(1);
        uint256 before = address(registry).balance;
        vm.prank(address(attacker));
        registry.withdraw();
        require(address(registry).balance == before - BOND, "single payout");
        require(registry.pendingWithdrawals(address(attacker)) == 0, "cleared");
    }

    function test_governorTwoStep() public {
        address next = address(0x60);
        vm.prank(governor);
        registry.transferGovernor(next);
        vm.prank(next);
        registry.acceptGovernor();
        require(registry.governor() == next, "gov");
    }

    function test_rejectsDirectEth() public {
        (bool ok,) = payable(address(registry)).call{value: 1 ether}("");
        require(!ok, "should reject");
    }

    function test_challengeBondMustMatch() public {
        uint256 id = _propose(alice, "search", BOND * 2);
        vm.prank(bob);
        vm.expectRevert(DictionaryRegistry.BondMismatch.selector);
        registry.challenge{value: BOND}(id, "wrong");
    }
}
