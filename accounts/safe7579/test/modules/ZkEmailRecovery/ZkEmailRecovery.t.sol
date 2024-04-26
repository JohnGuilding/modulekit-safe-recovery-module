// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../Launchpad.t.sol";
import "forge-std/console2.sol";
import {MODULE_TYPE_EXECUTOR} from "erc7579/interfaces/IERC7579Module.sol";
import {ECDSAOwnedDKIMRegistry} from "ether-email-auth/packages/contracts/src/utils/ECDSAOwnedDKIMRegistry.sol";
import {EmailAuth, EmailAuthMsg, EmailProof} from "ether-email-auth/packages/contracts/src/EmailAuth.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

import {ZkEmailRecovery} from "src/modules/ZkEmailRecovery/ZkEmailRecovery.sol";
import {IZkEmailRecovery} from "src/interfaces/IZkEmailRecovery.sol";
import {IGuardianManager} from "src/interfaces/IGuardianManager.sol";
import {IEmailAccountRecovery} from "src/modules/ZkEmailRecovery/EmailAccountRecoveryRouter.sol";
import {MockGroth16Verifier} from "../../mocks/MockGroth16Verifier.sol";

contract ZkEmailRecoveryTest is LaunchpadBase {
    ZkEmailRecovery zkEmailRecovery;

    // ZK Email contracts and variables
    address zkEmailDeployer = vm.addr(1);
    ECDSAOwnedDKIMRegistry ecdsaOwnedDkimRegistry;
    MockGroth16Verifier verifier;
    bytes32 accountSalt;

    address public owner;
    address public newOwner;

    address guardian;
    uint256 recoveryDelay;
    uint256 threshold;

    address[] guardians = new address[](1);
    string selector = "12345";
    string domainName = "gmail.com";
    bytes32 publicKeyHash =
        0x0ea9c777dc7110e5a9e89b13f0cfc540e3845ba120b2b6dc24024d61488d4788;

    function setUp() public override {
        super.setUp();
        target = new MockTarget();

        // Create ZK Email contracts
        vm.startPrank(zkEmailDeployer);
        ecdsaOwnedDkimRegistry = new ECDSAOwnedDKIMRegistry(zkEmailDeployer);
        string memory signedMsg = ecdsaOwnedDkimRegistry.computeSignedMsg(
            ecdsaOwnedDkimRegistry.SET_PREFIX(),
            selector,
            domainName,
            publicKeyHash
        );
        bytes32 digest = ECDSA.toEthSignedMessageHash(bytes(signedMsg));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);
        bytes memory signature = abi.encodePacked(r, s, v);
        ecdsaOwnedDkimRegistry.setDKIMPublicKeyHash(
            selector,
            domainName,
            publicKeyHash,
            signature
        );

        verifier = new MockGroth16Verifier();
        accountSalt = keccak256(abi.encode("account salt"));

        EmailAuth emailAuthImpl = new EmailAuth();
        vm.stopPrank();

        zkEmailRecovery = new ZkEmailRecovery(
            address(verifier),
            address(ecdsaOwnedDkimRegistry),
            address(emailAuthImpl)
        );

        owner = signer1.addr;
        newOwner = signer2.addr;

        guardian = zkEmailRecovery.computeEmailAuthAddress(accountSalt);

        guardians[0] = guardian;
        recoveryDelay = 1 seconds;
        threshold = 1;
    }

    function generateMockEmailProof(
        string memory subject,
        bytes32 nullifier,
        bytes32 accountSalt
    ) public returns (EmailProof memory) {
        EmailProof memory emailProof;
        emailProof.domainName = "gmail.com";
        emailProof.publicKeyHash = bytes32(
            vm.parseUint(
                "6632353713085157925504008443078919716322386156160602218536961028046468237192"
            )
        );
        emailProof.timestamp = block.timestamp;
        emailProof.maskedSubject = subject;
        emailProof.emailNullifier = nullifier;
        emailProof.accountSalt = accountSalt;
        emailProof.isCodeExist = true;
        emailProof.proof = bytes("0");

        return emailProof;
    }

    function acceptGuardian(
        address account,
        ZkEmailRecovery recoveryModule,
        address router,
        string memory subject,
        bytes32 nullifier,
        bytes32 accountSalt,
        uint256 templateIdx
    ) public {
        EmailProof memory emailProof = generateMockEmailProof(
            subject,
            nullifier,
            accountSalt
        );

        bytes[] memory subjectParamsForAcceptance = new bytes[](1);
        subjectParamsForAcceptance[0] = abi.encode(account);
        EmailAuthMsg memory emailAuthMsg = EmailAuthMsg({
            templateId: recoveryModule.computeAcceptanceTemplateId(templateIdx),
            subjectParams: subjectParamsForAcceptance,
            skipedSubjectPrefix: 0,
            proof: emailProof
        });
        IEmailAccountRecovery(router).handleAcceptance(
            emailAuthMsg,
            templateIdx
        );
    }

    function handleRecovery(
        address account,
        ZkEmailRecovery recoveryModule,
        address router,
        address oldOwner,
        address newOwner,
        string memory subject,
        bytes32 nullifier,
        bytes32 accountSalt,
        uint256 templateIdx
    ) public {
        EmailProof memory emailProof = generateMockEmailProof(
            subject,
            nullifier,
            accountSalt
        );

        bytes[] memory subjectParamsForRecovery = new bytes[](3);
        subjectParamsForRecovery[0] = abi.encode(oldOwner);
        subjectParamsForRecovery[1] = abi.encode(newOwner);
        subjectParamsForRecovery[2] = abi.encode(account);

        EmailAuthMsg memory emailAuthMsg = EmailAuthMsg({
            templateId: recoveryModule.computeRecoveryTemplateId(templateIdx),
            subjectParams: subjectParamsForRecovery,
            skipedSubjectPrefix: 0,
            proof: emailProof
        });
        IEmailAccountRecovery(router).handleRecovery(emailAuthMsg, templateIdx);
    }

    function testRecover() public {
        address accountAddress = address(safe);
        IERC7579Account account = IERC7579Account(accountAddress);
        uint templateIdx = 0;

        bool isModuleInstalled = account.isModuleInstalled(
            MODULE_TYPE_EXECUTOR,
            address(zkEmailRecovery),
            ""
        );
        assertFalse(isModuleInstalled);

        // Install recovery module
        vm.prank(accountAddress);
        account.installModule(
            MODULE_TYPE_EXECUTOR,
            address(zkEmailRecovery),
            abi.encode(guardians, recoveryDelay, threshold)
        );
        vm.stopPrank();

        isModuleInstalled = account.isModuleInstalled(
            MODULE_TYPE_EXECUTOR,
            address(zkEmailRecovery),
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
            accountSalt,
            templateIdx
        );
        IGuardianManager.GuardianStatus guardianStatus = zkEmailRecovery
            .getGuardianStatus(accountAddress, guardian);
        assertEq(
            uint256(guardianStatus),
            uint256(IGuardianManager.GuardianStatus.ACCEPTED)
        );

        // Time travel so that EmailAuth timestamp is valid
        vm.warp(12 seconds);

        // handle recovery request for guardian
        uint256 executeAfter = block.timestamp + recoveryDelay;
        handleRecovery(
            accountAddress,
            zkEmailRecovery,
            router,
            owner,
            newOwner,
            "Update owner from 0x7C8913d493892928d19F932FB1893404b6f1cE73 to 0x11A5669986B1fCBfcE54be4c543975b33D89856D on account 0x4DBa14a50681F152EE0b74fB00e7b2b0B8e3949a",
            keccak256(abi.encode("nullifier 2")),
            accountSalt,
            templateIdx
        );
        IZkEmailRecovery.RecoveryRequest
            memory recoveryRequest = zkEmailRecovery.getRecoveryRequest(
                accountAddress
            );
        assertEq(recoveryRequest.executeAfter, executeAfter);
        assertEq(recoveryRequest.approvalCount, 1);
        assertEq(recoveryRequest.recoveryData, abi.encode(newOwner, owner));

        vm.warp(block.timestamp + recoveryDelay);

        // Complete recovery
        IEmailAccountRecovery(router).completeRecovery();

        recoveryRequest = zkEmailRecovery.getRecoveryRequest(accountAddress);
        assertEq(recoveryRequest.executeAfter, 0);
        assertEq(recoveryRequest.recoveryData, new bytes(0));
        assertEq(recoveryRequest.approvalCount, 0);

        vm.prank(accountAddress);
        bool isOwner = Safe(payable(accountAddress)).isOwner(newOwner);
        assertTrue(isOwner);

        bool oldOwnerIsOwner = Safe(payable(accountAddress)).isOwner(owner);
        assertFalse(oldOwnerIsOwner);
    }
}
