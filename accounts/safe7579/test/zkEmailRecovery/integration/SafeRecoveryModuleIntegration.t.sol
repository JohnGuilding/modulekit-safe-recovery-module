// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/console2.sol";

import {MODULE_TYPE_EXECUTOR} from "erc7579/interfaces/IERC7579Module.sol";
import {IERC7579Account} from "erc7579/interfaces/IERC7579Account.sol";
import {ECDSAOwnedDKIMRegistry} from "ether-email-auth/packages/contracts/src/utils/ECDSAOwnedDKIMRegistry.sol";
import {EmailAuth, EmailAuthMsg, EmailProof} from "ether-email-auth/packages/contracts/src/EmailAuth.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {Safe} from "@safe-global/safe-contracts/contracts/Safe.sol";

import {ZkEmailRecovery} from "src/ZkEmailRecovery/ZkEmailRecovery.sol";
import {IEmailAccountRecovery} from "src/ZkEmailRecovery/EmailAccountRecoveryRouter.sol";
import {IZkEmailRecovery} from "src/ZkEmailRecovery/interfaces/IZkEmailRecovery.sol";

import {ZkEmailRecoveryBase} from "../ZkEmailRecoveryBase.t.sol";
import {MockGroth16Verifier} from "../../mocks/MockGroth16Verifier.sol";

contract SafeRecoveryModule_Integration_Test is ZkEmailRecoveryBase {
    function setUp() public override {
        super.setUp();
    }

    function testRecover() public {
        address accountAddress = address(safe);
        IERC7579Account account = IERC7579Account(accountAddress);

        // Install recovery module - configureRecovery is called on `onInstall`
        vm.prank(accountAddress);
        account.installModule(
            MODULE_TYPE_EXECUTOR,
            address(recoveryModule),
            abi.encode(guardians, guardianWeights, threshold, delay, expiry)
        );
        vm.stopPrank();

        bool isModuleInstalled = account.isModuleInstalled(
            MODULE_TYPE_EXECUTOR,
            address(recoveryModule),
            ""
        );
        assertTrue(isModuleInstalled);

        // Retrieve router now module has been installed
        address router = zkEmailRecovery.getRouterForAccount(accountAddress);

        // Accept guardian
        acceptGuardian(
            accountAddress,
            zkEmailRecovery,
            router,
            "Accept guardian request for 0x4DBa14a50681F152EE0b74fB00e7b2b0B8e3949a",
            keccak256(abi.encode("nullifier 1")),
            accountSalt1,
            templateIdx
        );
        IZkEmailRecovery.GuardianStorage
            memory guardianStorage1 = zkEmailRecovery.getGuardian(
                accountAddress,
                guardian1
            );
        assertEq(
            uint256(guardianStorage1.status),
            uint256(IZkEmailRecovery.GuardianStatus.ACCEPTED)
        );
        assertEq(guardianStorage1.weight, uint256(1));

        // Accept guardian
        acceptGuardian(
            accountAddress,
            zkEmailRecovery,
            router,
            "Accept guardian request for 0x4DBa14a50681F152EE0b74fB00e7b2b0B8e3949a",
            keccak256(abi.encode("nullifier 1")),
            accountSalt2,
            templateIdx
        );
        IZkEmailRecovery.GuardianStorage
            memory guardianStorage2 = zkEmailRecovery.getGuardian(
                accountAddress,
                guardian2
            );
        assertEq(
            uint256(guardianStorage2.status),
            uint256(IZkEmailRecovery.GuardianStatus.ACCEPTED)
        );
        assertEq(guardianStorage2.weight, uint256(1));

        // Time travel so that EmailAuth timestamp is valid
        vm.warp(12 seconds);

        // Compute create2Owner to use in email subject
        address create2Owner = recoveryModule.computeOwnerAddress(
            accountAddress,
            owner,
            newOwner
        );

        // handle recovery request for guardian 1
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
        IZkEmailRecovery.RecoveryRequest
            memory recoveryRequest = zkEmailRecovery.getRecoveryRequest(
                accountAddress
            );
        assertEq(recoveryRequest.totalWeight, 1);

        // handle recovery request for guardian 2
        uint256 executeAfter = block.timestamp + delay;
        uint256 executeBefore = block.timestamp + expiry;
        handleRecovery(
            accountAddress,
            create2Owner,
            address(recoveryModule),
            router,
            zkEmailRecovery,
            "Recover account 0x4DBa14a50681F152EE0b74fB00e7b2b0B8e3949a to new owner 0x02e61FdCBeBC01f21FbaA538F41F90D6Abb726AC using recovery module 0x1fC14F21b27579f4F23578731cD361CCa8aa39f7",
            keccak256(abi.encode("nullifier 2")),
            accountSalt2,
            templateIdx
        );
        recoveryRequest = zkEmailRecovery.getRecoveryRequest(accountAddress);
        assertEq(recoveryRequest.executeAfter, executeAfter);
        assertEq(recoveryRequest.executeBefore, executeBefore);
        assertEq(recoveryRequest.newOwner, create2Owner);
        assertEq(recoveryRequest.recoveryModule, address(recoveryModule));
        assertEq(recoveryRequest.totalWeight, 2);

        vm.warp(block.timestamp + delay);

        // Try and store invalid values
        recoveryModule.storeOwner(accountAddress, owner, address(1));
        recoveryModule.storeOwner(accountAddress, address(1), newOwner);
        recoveryModule.storeOwner(address(1), owner, newOwner);

        // Store old owner on recovery module
        recoveryModule.storeOwner(accountAddress, owner, newOwner);

        // Complete recovery
        IEmailAccountRecovery(router).completeRecovery();

        recoveryRequest = zkEmailRecovery.getRecoveryRequest(accountAddress);
        assertEq(recoveryRequest.executeAfter, 0);
        assertEq(recoveryRequest.executeBefore, 0);
        assertEq(recoveryRequest.newOwner, address(0));
        assertEq(recoveryRequest.recoveryModule, address(0));
        assertEq(recoveryRequest.totalWeight, 0);

        vm.prank(accountAddress);
        bool isOwner = Safe(payable(accountAddress)).isOwner(newOwner);
        assertTrue(isOwner);

        bool oldOwnerIsOwner = Safe(payable(accountAddress)).isOwner(owner);
        assertFalse(oldOwnerIsOwner);
    }
}
