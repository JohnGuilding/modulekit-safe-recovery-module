// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../Launchpad.t.sol";
import "forge-std/console2.sol";
import {MODULE_TYPE_EXECUTOR} from "erc7579/interfaces/IERC7579Module.sol";
import {ECDSAOwnedDKIMRegistry} from "ether-email-auth/packages/contracts/src/utils/ECDSAOwnedDKIMRegistry.sol";
import {EmailAuth, EmailAuthMsg, EmailProof} from "ether-email-auth/packages/contracts/src/EmailAuth.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

import {ZkEmailRecovery} from "src/ZkEmailRecovery/ZkEmailRecovery.sol";
import {SafeZkEmailRecovery} from "src/ZkEmailRecovery/SafeZkEmailRecovery.sol";
import {SafeRecoveryModule} from "src/ZkEmailRecovery/modules/SafeRecoveryModule.sol";
import {IZkEmailRecovery} from "src/ZkEmailRecovery/interfaces/IZkEmailRecovery.sol";
import {IEmailAccountRecovery} from "src/ZkEmailRecovery/interfaces/IEmailAccountRecovery.sol";
import {MockGroth16Verifier} from "../mocks/MockGroth16Verifier.sol";

contract ZkEmailRecoveryBase is LaunchpadBase {
    // ZK Email contracts and variables
    address zkEmailDeployer = vm.addr(1);
    ECDSAOwnedDKIMRegistry ecdsaOwnedDkimRegistry;
    MockGroth16Verifier verifier;
    EmailAuth emailAuthImpl;
    SafeZkEmailRecovery safeZkEmailRecovery;
    bytes32 accountSalt1;
    bytes32 accountSalt2;

    address public owner;
    address public newOwner;

    SafeRecoveryModule recoveryModule;
    address recoveryModuleAddress;

    // recovery config
    address[] guardians;
    address guardian1;
    address guardian2;
    uint256[] guardianWeights;
    uint256 delay;
    uint256 expiry;
    uint256 threshold;
    uint templateIdx;

    // address[] guardians = new address[](1);
    string selector = "12345";
    string domainName = "gmail.com";
    bytes32 publicKeyHash =
        0x0ea9c777dc7110e5a9e89b13f0cfc540e3845ba120b2b6dc24024d61488d4788;

    function setUp() public virtual override {
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
        emailAuthImpl = new EmailAuth();
        vm.stopPrank();

        safeZkEmailRecovery = new SafeZkEmailRecovery(
            address(verifier),
            address(ecdsaOwnedDkimRegistry),
            address(emailAuthImpl)
        );
        recoveryModule = new SafeRecoveryModule(address(safeZkEmailRecovery));
        recoveryModuleAddress = address(recoveryModule);

        owner = signer1.addr;
        newOwner = signer2.addr;

        // Compute guardian addresses
        accountSalt1 = keccak256(abi.encode("account salt 1"));
        accountSalt2 = keccak256(abi.encode("account salt 2"));
        guardian1 = safeZkEmailRecovery.computeEmailAuthAddress(accountSalt1);
        guardian2 = safeZkEmailRecovery.computeEmailAuthAddress(accountSalt2);

        // Set recovery config variables
        guardians = new address[](2);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardianWeights = new uint256[](2);
        guardianWeights[0] = 1;
        guardianWeights[1] = 1;
        delay = 1 seconds;
        expiry = 2 weeks;
        threshold = 2;
        templateIdx = 0;
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
        SafeZkEmailRecovery safeZkEmailRecovery,
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

        bytes[] memory subjectParamsForAcceptance = subjectParamsForAcceptance(
            account
        );

        EmailAuthMsg memory emailAuthMsg = EmailAuthMsg({
            templateId: safeZkEmailRecovery.computeAcceptanceTemplateId(
                templateIdx
            ),
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
        address oldOwner,
        address newOwner,
        address recoveryModule,
        address router,
        SafeZkEmailRecovery safeZkEmailRecovery,
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

        bytes[] memory subjectParamsForRecovery = subjectParamsForRecovery(
            account,
            oldOwner,
            newOwner,
            recoveryModule
        );

        EmailAuthMsg memory emailAuthMsg = EmailAuthMsg({
            templateId: safeZkEmailRecovery.computeRecoveryTemplateId(
                templateIdx
            ),
            subjectParams: subjectParamsForRecovery,
            skipedSubjectPrefix: 0,
            proof: emailProof
        });
        IEmailAccountRecovery(router).handleRecovery(emailAuthMsg, templateIdx);
    }

    function subjectParamsForAcceptance(
        address account
    ) public returns (bytes[] memory) {
        bytes[] memory subjectParamsForAcceptance = new bytes[](1);
        subjectParamsForAcceptance[0] = abi.encode(account);
        return subjectParamsForAcceptance;
    }

    function subjectParamsForRecovery(
        address account,
        address oldOwner,
        address newOwner,
        address recoveryModule
    ) public returns (bytes[] memory) {
        bytes[] memory subjectParamsForRecovery = new bytes[](4);
        subjectParamsForRecovery[0] = abi.encode(account);
        subjectParamsForRecovery[1] = abi.encode(oldOwner);
        subjectParamsForRecovery[2] = abi.encode(newOwner);
        subjectParamsForRecovery[3] = abi.encode(recoveryModule);
        return subjectParamsForRecovery;
    }
}
