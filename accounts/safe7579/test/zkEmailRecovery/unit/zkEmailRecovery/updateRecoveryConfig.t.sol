// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/console2.sol";
import {ZkEmailRecoveryBase} from "../../ZkEmailRecoveryBase.t.sol";

contract ZkEmailRecovery_updateRecoveryConfig_Test is ZkEmailRecoveryBase {
    function setUp() public override {
        super.setUp();
    }

    function test_RevertWhen_AlreadyRecovering() public {}
    function test_UpdateRecoveryConfig_Succeeds() public {}
}
