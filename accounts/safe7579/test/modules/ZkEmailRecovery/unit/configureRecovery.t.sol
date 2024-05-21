// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/console2.sol";

import {IZkEmailRecovery} from "src/interfaces/IZkEmailRecovery.sol";
import {ZkEmailRecoveryBase} from "../ZkEmailRecoveryBase.t.sol";

contract ZkEmailRecovery_configureRecovery_Test is ZkEmailRecoveryBase {
    function setUp() public override {
        super.setUp();
    }

    function test_RevertWhen_AlreadyRecovering() public {
        address accountAddress = address(safe);
        vm.startPrank(accountAddress);
        zkEmailRecovery.configureRecovery(
            guardians,
            guardianWeights,
            threshold,
            delay,
            expiry
        );
        vm.stopPrank();

        address router = zkEmailRecovery.getRouterForAccount(accountAddress);

        acceptGuardian(
            accountAddress,
            zkEmailRecovery,
            router,
            "Accept guardian request for 0x4DBa14a50681F152EE0b74fB00e7b2b0B8e3949a",
            keccak256(abi.encode("nullifier 1")),
            accountSalt1,
            templateIdx
        );

        // Time travel so that EmailAuth timestamp is valid
        vm.warp(12 seconds);

        // Compute create2Owner to use in email subject
        address create2Owner = recoveryModule.computeOwnerAddress(
            accountAddress,
            owner,
            newOwner
        );

        // handle recovery request for guardian
        handleRecovery(
            accountAddress,
            create2Owner,
            address(recoveryModule),
            router,
            zkEmailRecovery,
            "Recover account 0x4DBa14a50681F152EE0b74fB00e7b2b0B8e3949a to new owner 0x02e61FdCBeBC01f21FbaA538F41F90D6Abb726AC using recovery module 0x1fC14F21b27579f4F23578731cD361CCa8aa39f7",
            keccak256(abi.encode("nullifier 2")),
            accountSalt1,
            templateIdx
        );

        vm.expectRevert(IZkEmailRecovery.RecoveryInProcess.selector);
        vm.startPrank(accountAddress);
        zkEmailRecovery.configureRecovery(
            guardians,
            guardianWeights,
            threshold,
            delay,
            expiry
        );
        vm.stopPrank();
    }

    function test_ConfigureRecovery_Succeeds() public {
        address accountAddress = address(safe);

        address expectedRouterAddress = zkEmailRecovery.computeRouterAddress(
            keccak256(abi.encode(accountAddress))
        );

        vm.expectEmit();
        emit IZkEmailRecovery.RecoveryConfigured(
            accountAddress,
            delay,
            expiry,
            expectedRouterAddress
        );
        vm.startPrank(accountAddress);
        zkEmailRecovery.configureRecovery(
            guardians,
            guardianWeights,
            threshold,
            delay,
            expiry
        );
        vm.stopPrank();

        IZkEmailRecovery.RecoveryConfig memory recoveryConfig = zkEmailRecovery
            .getRecoveryConfig(accountAddress);
        assertEq(recoveryConfig.delay, delay);
        assertEq(recoveryConfig.expiry, expiry);

        IZkEmailRecovery.GuardianConfig memory guardianConfig = zkEmailRecovery
            .getGuardianConfig(accountAddress);
        assertEq(guardianConfig.guardianCount, guardians.length);
        assertEq(guardianConfig.threshold, threshold);

        IZkEmailRecovery.GuardianStorage memory guardian = zkEmailRecovery
            .getGuardian(accountAddress, guardians[0]);
        assertEq(
            uint256(guardian.status),
            uint256(IZkEmailRecovery.GuardianStatus.REQUESTED)
        );
        assertEq(guardian.weight, guardianWeights[0]);

        address accountForRouter = zkEmailRecovery.getAccountForRouter(
            expectedRouterAddress
        );
        assertEq(accountForRouter, accountAddress);

        address routerForAccount = zkEmailRecovery.getRouterForAccount(
            accountAddress
        );
        assertEq(routerForAccount, expectedRouterAddress);
    }
}
