// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DictionaryRegistry} from "../src/DictionaryRegistry.sol";
import {TimelockGovernor} from "../src/TimelockGovernor.sol";

interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function expectRevert(bytes4) external;
    function deal(address, uint256) external;
}

contract TimelockGovernorTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    TimelockGovernor internal timelock;
    DictionaryRegistry internal registry;
    address internal owner = address(0x0DD);
    address internal arbiter = address(0xA4B);
    address internal guardian = address(0x6A4D);

    function setUp() public {
        timelock = new TimelockGovernor(owner, 1 hours, 14 days);
        registry = new DictionaryRegistry(
            address(timelock), arbiter, guardian, 0.1 ether, 1 hours, 1 hours
        );
    }

    function test_setConfigOnlyAfterDelay() public {
        bytes memory data = abi.encodeCall(DictionaryRegistry.setConfig, (0.2 ether, 2 hours, 2 hours));
        vm.prank(owner);
        timelock.queue(address(registry), 0, data);
        vm.expectRevert(TimelockGovernor.NotReady.selector);
        timelock.execute(address(registry), 0, data);
        vm.warp(block.timestamp + 1 hours);
        timelock.execute(address(registry), 0, data);
        (uint128 minBond, uint64 challengePeriod, uint64 resolvePeriod) = registry.config();
        require(minBond == 0.2 ether, "bond");
        require(challengePeriod == 2 hours && resolvePeriod == 2 hours, "periods");
    }

    function test_ownerCannotBypassQueue() public {
        vm.prank(owner);
        vm.expectRevert(DictionaryRegistry.NotGovernor.selector);
        registry.setConfig(0.2 ether, 2 hours, 2 hours);
    }

    function test_cancelPreventsExecute() public {
        bytes memory data = abi.encodeCall(DictionaryRegistry.setArbiter, (address(0xBEEF)));
        vm.prank(owner);
        timelock.queue(address(registry), 0, data);
        vm.prank(owner);
        timelock.cancel(address(registry), 0, data);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(TimelockGovernor.NotQueued.selector);
        timelock.execute(address(registry), 0, data);
    }

    function test_expiredCallCannotExecute() public {
        bytes memory data = abi.encodeCall(DictionaryRegistry.setGuardian, (address(0x1111)));
        vm.prank(owner);
        timelock.queue(address(registry), 0, data);
        vm.warp(block.timestamp + 1 hours + 14 days + 1);
        vm.expectRevert(TimelockGovernor.Expired.selector);
        timelock.execute(address(registry), 0, data);
    }
}
