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
import {IEmailAccountRecovery} from "src/ZkEmailRecovery/interfaces/IEmailAccountRecovery.sol";
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
            recoveryModuleAddress,
            abi.encode(guardians, guardianWeights, threshold, delay, expiry)
        );
        vm.stopPrank();

        bool isModuleInstalled = account.isModuleInstalled(
            MODULE_TYPE_EXECUTOR,
            recoveryModuleAddress,
            ""
        );
        assertTrue(isModuleInstalled);

        // Retrieve router now module has been installed
        address router = safeZkEmailRecovery.getRouterForAccount(
            accountAddress
        );

        // Accept guardian
        acceptGuardian(
            accountAddress,
            safeZkEmailRecovery,
            router,
            "Accept guardian request for 0x4DBa14a50681F152EE0b74fB00e7b2b0B8e3949a",
            keccak256(abi.encode("nullifier 1")),
            accountSalt1,
            templateIdx
        );
        IZkEmailRecovery.GuardianStorage
            memory guardianStorage1 = safeZkEmailRecovery.getGuardian(
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
            safeZkEmailRecovery,
            router,
            "Accept guardian request for 0x4DBa14a50681F152EE0b74fB00e7b2b0B8e3949a",
            keccak256(abi.encode("nullifier 1")),
            accountSalt2,
            templateIdx
        );
        IZkEmailRecovery.GuardianStorage
            memory guardianStorage2 = safeZkEmailRecovery.getGuardian(
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

        // handle recovery request for guardian 1
        handleRecovery(
            accountAddress,
            owner,
            newOwner,
            recoveryModuleAddress,
            router,
            safeZkEmailRecovery,
            "Recover account 0x4DBa14a50681F152EE0b74fB00e7b2b0B8e3949a from old owner 0x7C8913d493892928d19F932FB1893404b6f1cE73 to new owner 0x11A5669986B1fCBfcE54be4c543975b33D89856D using recovery module 0x1fC14F21b27579f4F23578731cD361CCa8aa39f7",
            keccak256(abi.encode("nullifier 2")),
            accountSalt1,
            templateIdx
        );
        IZkEmailRecovery.RecoveryRequest
            memory recoveryRequest = safeZkEmailRecovery.getRecoveryRequest(
                accountAddress
            );
        assertEq(recoveryRequest.currentWeight, 1);

        // handle recovery request for guardian 2
        uint256 executeAfter = block.timestamp + delay;
        uint256 executeBefore = block.timestamp + expiry;
        handleRecovery(
            accountAddress,
            owner,
            newOwner,
            recoveryModuleAddress,
            router,
            safeZkEmailRecovery,
            "Recover account 0x4DBa14a50681F152EE0b74fB00e7b2b0B8e3949a from old owner 0x7C8913d493892928d19F932FB1893404b6f1cE73 to new owner 0x11A5669986B1fCBfcE54be4c543975b33D89856D using recovery module 0x1fC14F21b27579f4F23578731cD361CCa8aa39f7",
            keccak256(abi.encode("nullifier 2")),
            accountSalt2,
            templateIdx
        );
        recoveryRequest = safeZkEmailRecovery.getRecoveryRequest(
            accountAddress
        );
        assertEq(recoveryRequest.executeAfter, executeAfter);
        assertEq(recoveryRequest.executeBefore, executeBefore);
        assertEq(
            recoveryRequest.subjectParams,
            subjectParamsForRecovery(
                accountAddress,
                owner,
                newOwner,
                recoveryModuleAddress
            )
        );
        assertEq(recoveryRequest.currentWeight, 2);

        vm.warp(block.timestamp + delay);

        // Complete recovery
        IEmailAccountRecovery(router).completeRecovery();

        recoveryRequest = safeZkEmailRecovery.getRecoveryRequest(
            accountAddress
        );
        assertEq(recoveryRequest.executeAfter, 0);
        assertEq(recoveryRequest.executeBefore, 0);
        assertEq(recoveryRequest.subjectParams, new bytes[](0));
        assertEq(recoveryRequest.currentWeight, 0);

        vm.prank(accountAddress);
        bool isOwner = Safe(payable(accountAddress)).isOwner(newOwner);
        assertTrue(isOwner);

        bool oldOwnerIsOwner = Safe(payable(accountAddress)).isOwner(owner);
        assertFalse(oldOwnerIsOwner);

        // FIXME: This is reverting and I'm not sure why - even when all logic is commented out inside `onUninstall`
        // Uninstall and clear up state
        // vm.prank(accountAddress);
        // account.uninstallModule(
        //     MODULE_TYPE_EXECUTOR,
        //     recoveryModuleAddress,
        //     ""
        // );
        // vm.stopPrank();

        // isModuleInstalled = account.isModuleInstalled(
        //     MODULE_TYPE_EXECUTOR,
        //     recoveryModuleAddress,
        //     ""
        // );
        // assertFalse(isModuleInstalled);
    }
}
