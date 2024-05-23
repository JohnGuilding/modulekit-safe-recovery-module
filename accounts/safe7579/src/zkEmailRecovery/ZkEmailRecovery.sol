// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PackedUserOperation} from "@rhinestone/modulekit/src/external/ERC4337.sol";
import {EmailAccountRecovery} from "ether-email-auth/packages/contracts/src/EmailAccountRecovery.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {IZkEmailRecovery} from "./interfaces/IZkEmailRecovery.sol";
import {IEmailAuth} from "./interfaces/IEmailAuth.sol";
import {IUUPSUpgradable} from "./interfaces/IUUPSUpgradable.sol";
import {IRecoveryModule} from "./interfaces/IRecoveryModule.sol";
import {EmailAccountRecoveryRouter} from "./EmailAccountRecoveryRouter.sol";

contract ZkEmailRecovery is EmailAccountRecovery, IZkEmailRecovery {
    /*//////////////////////////////////////////////////////////////////////////
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////////////////*/

    uint256 constant MINIMUM_RECOVERY_WINDOW = 1 days;

    /** Account address to recovery config */
    mapping(address => RecoveryConfig) public recoveryConfigs;

    /** Account address to recovery request */
    mapping(address => RecoveryRequest) public recoveryRequests;

    /** Account address to guardian address to guardian storage */
    mapping(address => mapping(address => GuardianStorage))
        internal guardianStorage;

    /** Account to guardian config */
    mapping(address => GuardianConfig) internal guardianConfigs;

    /** Email account recovery router address to account address */
    mapping(address => address) internal routerToAccount;

    /** Account address to email account recovery router address */
    /** These are stored for frontends to easily find the router contract address from the given account account address */
    mapping(address => address) internal accountToRouter;

    /*//////////////////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier onlyWhenNotRecovering() {
        if (recoveryRequests[msg.sender].totalWeight > 0) {
            revert RecoveryInProcess();
        }
        _;
    }

    modifier onlyAccountForGuardian(address guardian) {
        bool isGuardianForAccount = isGuardianForAccount(msg.sender, guardian);
        if (!isGuardianForAccount) {
            revert UnauthorizedAccountForGuardian();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    constructor(
        address _verifier,
        address _dkimRegistry,
        address _emailAuthImpl
    ) {
        verifierAddr = _verifier;
        dkimAddr = _dkimRegistry;
        emailAuthImplementationAddr = _emailAuthImpl;
    }

    function getRecoveryConfig(
        address account
    ) external view returns (RecoveryConfig memory) {
        return recoveryConfigs[account];
    }

    function getRecoveryRequest(
        address account
    ) external view returns (RecoveryRequest memory) {
        return recoveryRequests[account];
    }

    function acceptanceSubjectTemplates()
        public
        pure
        virtual
        override
        returns (string[][] memory)
    {
        string[][] memory templates = new string[][](1);
        templates[0] = new string[](5);
        templates[0][0] = "Accept";
        templates[0][1] = "guardian";
        templates[0][2] = "request";
        templates[0][3] = "for";
        templates[0][4] = "{ethAddr}";
        return templates;
    }

    function recoverySubjectTemplates()
        public
        pure
        virtual
        override
        returns (string[][] memory)
    {
        string[][] memory templates = new string[][](1);
        templates[0] = new string[](11);
        templates[0][0] = "Recover";
        templates[0][1] = "account";
        templates[0][2] = "{ethAddr}";
        templates[0][3] = "to";
        templates[0][4] = "new";
        templates[0][5] = "owner";
        templates[0][6] = "{ethAddr}";
        templates[0][7] = "using";
        templates[0][8] = "recovery";
        templates[0][9] = "module";
        templates[0][10] = "{ethAddr}";
        return templates;
    }

    function validateAcceptanceSubjectTemplates(
        bytes[] memory subjectParams
    ) internal virtual returns (address) {
        if (subjectParams.length != 1) revert InvalidSubjectParams();

        // The GuardianStatus check in acceptGuardian implicitly
        // validates the account, so no need to re-validate here
        address accountInEmail = abi.decode(subjectParams[0], (address));

        return accountInEmail;
    }

    function validateRecoverySubjectTemplates(
        bytes[] memory subjectParams
    ) internal virtual returns (address, address) {
        if (subjectParams.length != 3) revert InvalidSubjectParams();

        // The GuardianStatus check in processRecovery implicitly
        // validates the account, so no need to re-validate here
        address accountInEmail = abi.decode(subjectParams[0], (address));
        address newOwnerInEmail = abi.decode(subjectParams[1], (address));
        address recoveryModuleInEmail = abi.decode(subjectParams[2], (address));

        if (newOwnerInEmail == address(0)) {
            revert InvalidNewOwner();
        }

        address expectedRecoveryModule = recoveryConfigs[accountInEmail]
            .recoveryModule;
        if (recoveryModuleInEmail != expectedRecoveryModule) {
            revert InvalidRecoveryModule();
        }

        return (accountInEmail, recoveryModuleInEmail);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CORE RECOVERY LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    function configureRecovery(
        address recoveryModule,
        address[] memory guardians,
        uint256[] memory weights,
        uint256 threshold,
        uint256 delay,
        uint256 expiry
    ) external onlyWhenNotRecovering {
        address account = msg.sender;

        setupGuardians(account, guardians, weights, threshold);

        address router = deployRouterForAccount(account);

        RecoveryConfig memory recoveryConfig = RecoveryConfig(
            recoveryModule,
            delay,
            expiry
        );
        validateRecoveryConfig(recoveryConfig);
        recoveryConfigs[account] = recoveryConfig;

        emit RecoveryConfigured(
            account,
            recoveryModule,
            guardians.length,
            router
        );
    }

    function acceptGuardian(
        address guardian,
        uint templateIdx,
        bytes[] memory subjectParams,
        bytes32
    ) internal override onlyWhenNotRecovering {
        if (guardian == address(0)) {
            revert InvalidGuardian();
        }
        if (templateIdx != 0) {
            revert InvalidTemplateIndex();
        }
        address accountInEmail = validateAcceptanceSubjectTemplates(
            subjectParams
        );

        // This check ensures GuardianStatus is correct and also that the
        // account in email is a valid account
        GuardianStorage memory guardianStorage = getGuardian(
            accountInEmail,
            guardian
        );
        if (guardianStorage.status != GuardianStatus.REQUESTED) {
            revert InvalidGuardianStatus(
                guardianStorage.status,
                GuardianStatus.REQUESTED
            );
        }

        _updateGuardian(
            accountInEmail,
            guardian,
            GuardianStorage(GuardianStatus.ACCEPTED, guardianStorage.weight)
        );
    }

    function processRecovery(
        address guardian,
        uint templateIdx,
        bytes[] memory subjectParams,
        bytes32
    ) internal override {
        if (guardian == address(0)) {
            revert InvalidGuardian();
        }
        if (templateIdx != 0) {
            revert InvalidTemplateIndex();
        }

        (
            address accountInEmail,
            address recoveryModuleInEmail
        ) = validateRecoverySubjectTemplates(subjectParams);

        // This check ensures GuardianStatus is correct and also that the
        // account in email is a valid account
        GuardianStorage memory guardian = getGuardian(accountInEmail, guardian);
        if (guardian.status != GuardianStatus.ACCEPTED) {
            revert InvalidGuardianStatus(
                guardian.status,
                GuardianStatus.ACCEPTED
            );
        }

        RecoveryRequest storage recoveryRequest = recoveryRequests[
            accountInEmail
        ];

        recoveryRequest.totalWeight += guardian.weight;

        uint256 threshold = getGuardianConfig(accountInEmail).threshold;
        if (recoveryRequest.totalWeight >= threshold) {
            uint256 executeAfter = block.timestamp +
                recoveryConfigs[accountInEmail].delay;
            uint256 executeBefore = block.timestamp +
                recoveryConfigs[accountInEmail].expiry;

            recoveryRequest.executeAfter = executeAfter;
            recoveryRequest.executeBefore = executeBefore;
            recoveryRequest.subjectParams = subjectParams;

            emit RecoveryProcessed(accountInEmail, executeAfter, executeBefore);

            if (executeAfter == block.timestamp) {
                completeRecovery(accountInEmail);
            }
        }
    }

    function completeRecovery() public override {
        address account = getAccountForRouter(msg.sender);
        completeRecovery(account);
    }

    function completeRecovery(address account) public {
        RecoveryRequest memory recoveryRequest = recoveryRequests[account];

        uint256 threshold = getGuardianConfig(account).threshold;
        if (recoveryRequest.totalWeight < threshold) {
            revert NotEnoughApprovals();
        }

        if (block.timestamp < recoveryRequest.executeAfter) {
            revert DelayNotPassed();
        }

        if (block.timestamp >= recoveryRequest.executeBefore) {
            delete recoveryRequests[account];
            revert RecoveryRequestExpired();
        }

        delete recoveryRequests[account];

        address recoveryModule = recoveryConfigs[account].recoveryModule;

        IRecoveryModule(recoveryModule).recover(
            account,
            recoveryRequest.subjectParams
        );

        emit RecoveryCompleted(account);
    }

    function cancelRecovery(bytes calldata) external virtual {
        address account = msg.sender;
        delete recoveryRequests[account];
        emit RecoveryCancelled(account);
    }

    function updateRecoveryConfig(
        RecoveryConfig calldata recoveryConfig
    ) external onlyWhenNotRecovering {
        address account = msg.sender;
        validateRecoveryConfig(recoveryConfig);
        recoveryConfigs[account] = recoveryConfig;
    }

    function validateRecoveryConfig(
        RecoveryConfig memory recoveryConfig
    ) internal {
        if (recoveryConfig.recoveryModule == address(0)) {
            revert InvalidRecoveryModule();
        }
        if (recoveryConfig.delay > recoveryConfig.expiry) {
            revert DelayLessThanExpiry();
        }
        if (
            recoveryConfig.expiry - recoveryConfig.delay <
            MINIMUM_RECOVERY_WINDOW
        ) {
            revert RecoveryWindowTooShort();
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                                GUARDIAN LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    function getGuardianConfig(
        address account
    ) public view override returns (GuardianConfig memory) {
        return guardianConfigs[account];
    }

    function getGuardian(
        address account,
        address guardian
    ) public view returns (GuardianStorage memory) {
        return guardianStorage[account][guardian];
    }

    function isGuardianForAccount(
        address guardian,
        address account
    ) public view override returns (bool) {
        return guardianStorage[account][guardian].status != GuardianStatus.NONE;
    }

    /**
     * @notice Sets the initial storage of the contract.
     * @param account The account.
     */
    function setupGuardians(
        address account,
        address[] memory _guardians,
        uint256[] memory weights,
        uint256 threshold
    ) internal {
        // Threshold can only be 0 at initialization.
        // Check ensures that setup function can only be called once.
        if (guardianConfigs[account].threshold > 0) {
            revert SetupAlreadyCalled();
        }

        uint256 guardianCount = _guardians.length;

        // Validate that threshold is smaller than number of added owners.
        if (threshold > guardianCount) {
            revert ThresholdCannotExceedGuardianCount();
        }

        if (guardianCount != weights.length) {
            revert IncorrectNumberOfWeights();
        }

        // There has to be at least one Account owner.
        if (threshold == 0) {
            revert ThresholdCannotBeZero();
        }

        for (uint256 i = 0; i < guardianCount; i++) {
            address _guardian = _guardians[i];
            uint256 weight = weights[i];
            GuardianStorage memory _guardianStorage = guardianStorage[account][
                _guardian
            ];

            if (_guardian == address(0) || _guardian == address(this)) {
                revert InvalidGuardianAddress();
            }

            // As long as weights are 1 or above, there will be enough total weight to reach the
            // required threshold. This is because we check the guardian count cannot be less
            // than the threshold and there is an equal amount of guardians to weights.
            if (weight == 0) {
                revert InvalidGuardianWeight();
            }

            if (_guardianStorage.status == GuardianStatus.REQUESTED) {
                revert AddressAlreadyRequested();
            }

            if (_guardianStorage.status == GuardianStatus.ACCEPTED) {
                revert AddressAlreadyGuardian();
            }

            guardianStorage[account][_guardian] = GuardianStorage(
                GuardianStatus.REQUESTED,
                weight
            );
        }

        guardianConfigs[account] = GuardianConfig(guardianCount, threshold);
    }

    function updateGuardian(
        address guardian,
        GuardianStorage memory _guardianStorage
    ) external override onlyAccountForGuardian(guardian) onlyWhenNotRecovering {
        _updateGuardian(msg.sender, guardian, _guardianStorage);
    }

    function _updateGuardian(
        address account,
        address guardian,
        GuardianStorage memory _guardianStorage
    ) internal {
        if (account == address(0) || account == address(this)) {
            revert InvalidAccountAddress();
        }

        if (guardian == address(0) || guardian == address(this)) {
            revert InvalidGuardianAddress();
        }

        GuardianStorage memory oldGuardian = guardianStorage[account][guardian];
        if (_guardianStorage.status == oldGuardian.status) {
            revert GuardianStatusMustBeDifferent();
        }

        if (_guardianStorage.weight == 0) {
            revert InvalidGuardianWeight();
        }

        guardianStorage[account][guardian] = GuardianStorage(
            _guardianStorage.status,
            _guardianStorage.weight
        );
    }

    function addGuardianWithThreshold(
        address guardian,
        uint256 weight,
        uint256 threshold
    ) public override onlyAccountForGuardian(guardian) onlyWhenNotRecovering {
        address account = msg.sender;
        GuardianStorage memory _guardianStorage = guardianStorage[account][
            guardian
        ];

        // Guardian address cannot be null, the sentinel or the Account itself.
        if (guardian == address(0) || guardian == address(this)) {
            revert InvalidGuardianAddress();
        }

        if (_guardianStorage.status == GuardianStatus.REQUESTED) {
            revert AddressAlreadyRequested();
        }

        if (_guardianStorage.status == GuardianStatus.ACCEPTED) {
            revert AddressAlreadyGuardian();
        }

        if (weight == 0) {
            revert InvalidGuardianWeight();
        }

        guardianStorage[account][guardian] = GuardianStorage(
            GuardianStatus.REQUESTED,
            weight
        );
        guardianConfigs[account].guardianCount++;

        emit AddedGuardian(guardian);

        // Change threshold if threshold was changed.
        if (guardianConfigs[account].threshold != threshold) {
            _changeThreshold(account, threshold);
        }
    }

    function removeGuardian(
        address guardian,
        uint256 threshold
    ) public override onlyAccountForGuardian(guardian) onlyWhenNotRecovering {
        address account = msg.sender;
        // Only allow to remove an guardian, if threshold can still be reached.
        // TODO: change error name and assess whether guardian count could be lowered below threshold
        if (guardianConfigs[account].threshold - 1 < threshold) {
            revert ThresholdCannotExceedGuardianCount();
        }

        if (guardian == address(0)) {
            revert InvalidGuardianAddress();
        }

        delete guardianStorage[account][guardian];
        guardianConfigs[account].guardianCount--;

        emit RemovedGuardian(guardian);

        // Change threshold if threshold was changed.
        if (guardianConfigs[account].threshold != threshold) {
            _changeThreshold(account, threshold);
        }
    }

    function swapGuardian(
        address oldGuardian,
        address newGuardian
    )
        public
        override
        onlyAccountForGuardian(oldGuardian)
        onlyWhenNotRecovering
    {
        address account = msg.sender;

        GuardianStatus newGuardianStatus = guardianStorage[account][newGuardian]
            .status;

        if (
            newGuardian == address(0) ||
            newGuardian == address(this) ||
            newGuardian == oldGuardian
        ) {
            revert InvalidGuardianAddress();
        }

        if (newGuardianStatus != GuardianStatus.NONE) {
            revert AddressAlreadyGuardian();
        }

        GuardianStorage memory oldGuardianStorage = guardianStorage[account][
            oldGuardian
        ];

        guardianStorage[account][newGuardian] = GuardianStorage(
            GuardianStatus.REQUESTED,
            oldGuardianStorage.weight
        );
        delete guardianStorage[account][oldGuardian];

        emit RemovedGuardian(oldGuardian);
        emit AddedGuardian(newGuardian);
    }

    function changeThreshold(
        uint256 threshold
    ) public override onlyWhenNotRecovering {
        address account = msg.sender;
        if (guardianConfigs[account].guardianCount == 0) {
            revert AccountNotConfigured();
        }
        _changeThreshold(account, threshold);
    }

    function _changeThreshold(address account, uint256 threshold) private {
        // Validate that threshold is smaller than number of guardians.
        if (threshold > guardianConfigs[account].guardianCount) {
            revert ThresholdCannotExceedGuardianCount();
        }

        // There has to be at least one Account guardian.
        if (threshold == 0) {
            revert ThresholdCannotBeZero();
        }

        guardianConfigs[account].threshold = threshold;
        emit ChangedThreshold(threshold);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ROUTER LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    function getAccountForRouter(
        address recoveryRouter
    ) public view override returns (address) {
        return routerToAccount[recoveryRouter];
    }

    function getRouterForAccount(
        address account
    ) public view override returns (address) {
        return accountToRouter[account];
    }

    function computeRouterAddress(bytes32 salt) public view returns (address) {
        return
            Create2.computeAddress(
                salt,
                keccak256(
                    abi.encodePacked(
                        type(EmailAccountRecoveryRouter).creationCode,
                        abi.encode(address(this))
                    )
                )
            );
    }

    function deployRouterForAccount(
        address account
    ) internal returns (address) {
        if (accountToRouter[account] != address(0)) {
            revert RouterAlreadyDeployed();
        }

        EmailAccountRecoveryRouter emailAccountRecoveryRouter = new EmailAccountRecoveryRouter{
                salt: keccak256(abi.encode(account))
            }(address(this));
        address routerAddress = address(emailAccountRecoveryRouter);

        routerToAccount[routerAddress] = account;
        accountToRouter[account] = routerAddress;

        return routerAddress;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                EMAIL AUTH LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    function updateGuardianDKIMRegistry(
        address guardian,
        address dkimRegistryAddr
    ) external onlyAccountForGuardian(guardian) onlyWhenNotRecovering {
        IEmailAuth(guardian).updateDKIMRegistry(dkimRegistryAddr);
    }

    function updateGuardianVerifier(
        address guardian,
        address verifierAddr
    ) external onlyAccountForGuardian(guardian) onlyWhenNotRecovering {
        IEmailAuth(guardian).updateVerifier(verifierAddr);
    }

    function updateGuardianSubjectTemplate(
        address guardian,
        uint templateId,
        string[] memory subjectTemplate
    ) external onlyAccountForGuardian(guardian) onlyWhenNotRecovering {
        IEmailAuth(guardian).updateSubjectTemplate(templateId, subjectTemplate);
    }

    function deleteGuardianSubjectTemplate(
        address guardian,
        uint templateId
    ) external onlyAccountForGuardian(guardian) onlyWhenNotRecovering {
        IEmailAuth(guardian).deleteSubjectTemplate(templateId);
    }

    function setGuardianTimestampCheckEnabled(
        address guardian,
        bool enabled
    ) external onlyAccountForGuardian(guardian) onlyWhenNotRecovering {
        IEmailAuth(guardian).setTimestampCheckEnabled(enabled);
    }

    function upgradeEmailAuthGuardian(
        address guardian,
        address newImplementation,
        bytes memory data
    ) external onlyAccountForGuardian(guardian) onlyWhenNotRecovering {
        IUUPSUpgradable(guardian).upgradeToAndCall(newImplementation, data);
    }
}
