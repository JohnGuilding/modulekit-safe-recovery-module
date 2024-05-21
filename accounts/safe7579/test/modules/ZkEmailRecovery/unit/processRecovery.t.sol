// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/console2.sol";
import {ZkEmailRecoveryBase} from "../ZkEmailRecoveryBase.t.sol";

contract ZkEmailRecovery_processRecovery_Test is ZkEmailRecoveryBase {
    function setUp() public override {
        super.setUp();
    }

    function test_RevertWhen_AlreadyRecovering() public {}
    function test_RevertWhen_InvalidGuardianAddress() public {}
    function test_RevertWhen_InvalidTemplateIndex() public {}
    function test_RevertWhen_InvalidSubjectParams() public {}
    function test_RevertWhen_InvalidGuardianStatus() public {}
    function test_RevertWhen_InvalidNewOwner() public {}
    function test_RevertWhen_InvalidRecoveryModule() public {}
    function test_ProcessRecovery_IncreasesTotalWeight() public {}
    function test_ProcessRecovery_InitiatesRecovery() public {}
    function test_ProcessRecovery_CompletesRecovery() public {}
}
