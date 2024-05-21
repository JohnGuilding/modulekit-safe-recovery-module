// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/console2.sol";
import {ZkEmailRecoveryBase} from "../ZkEmailRecoveryBase.t.sol";

contract ZkEmailRecovery_isGuardian_Test is ZkEmailRecoveryBase {
    function setUp() public override {
        super.setUp();
    }

    function test_ReturnsFalseWhen_AccountIsNotGuardian() public {}
    function test_ReturnsTrueWhen_AccountIsGuardian() public {}
}
