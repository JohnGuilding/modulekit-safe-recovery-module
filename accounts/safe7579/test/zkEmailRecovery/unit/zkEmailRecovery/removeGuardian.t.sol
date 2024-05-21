// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/console2.sol";
import {ZkEmailRecoveryBase} from "../../ZkEmailRecoveryBase.t.sol";

contract ZkEmailRecovery_removeGuardian_Test is ZkEmailRecoveryBase {
    function setUp() public override {
        super.setUp();
    }

    function test_RevertWhen_MsgSenderNotConfigured() public {}
    function test_RevertWhen_AlreadyRecovering() public {}
    function test_RevertWhen_ThresholdExceedsGuardianCount() public {}
    function test_RevertWhen_InvalidGuardianAddress() public {}
    function test_RemoveGuardian_SameThreshold() public {}
    function test_RemoveGuardian_DifferentThreshold() public {}
}
