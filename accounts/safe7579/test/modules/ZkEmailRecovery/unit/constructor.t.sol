// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/console2.sol";
import {ZkEmailRecoveryBase} from "../ZkEmailRecoveryBase.t.sol";
import {ZkEmailRecovery} from "src/modules/ZkEmailRecovery/ZkEmailRecovery.sol";

contract ZkEmailRecovery_constructor_Test is ZkEmailRecoveryBase {
    function setUp() public override {
        super.setUp();
    }

    function test_Constructor() public {
        ZkEmailRecovery zkEmailRecovery = new ZkEmailRecovery(
            address(verifier),
            address(ecdsaOwnedDkimRegistry),
            address(emailAuthImpl)
        );

        assertEq(address(verifier), zkEmailRecovery.verifier());
        assertEq(address(ecdsaOwnedDkimRegistry), zkEmailRecovery.dkim());
        assertEq(
            address(emailAuthImpl),
            zkEmailRecovery.emailAuthImplementation()
        );
    }
}
