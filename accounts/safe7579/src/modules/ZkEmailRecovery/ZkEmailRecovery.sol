// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PackedUserOperation} from "@rhinestone/modulekit/src/external/ERC4337.sol";
import {EmailAccountRecovery} from "ether-email-auth/packages/contracts/src/EmailAccountRecovery.sol";
import {IZkEmailRecovery} from "../../interfaces/IZkEmailRecovery.sol";
import {EmailAccountRecoveryRouter} from "./EmailAccountRecoveryRouter.sol";

interface IRecoveryModule {
    function recover(address account, address newOwner) external;
}

contract ZkEmailRecovery is EmailAccountRecovery, IZkEmailRecovery {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /** Mapping of account address to recovery delay */
    mapping(address => RecoveryConfig) public recoveryConfigs;

    /** Mapping of account address to recovery request */
    mapping(address => RecoveryRequest) public recoveryRequests;

    /** Account to guardian to guardian status */
    mapping(address => mapping(address => GuardianStorage))
        internal guardianStorage; // TODO: validate weights

    /** Account to guardian storage */
    mapping(address => GuardianConfig) internal guardianConfigs;

    /** Mapping of email account recovery router contracts to account */
    mapping(address => address) internal routerToAccount;

    /** Mapping of account account addresses to email account recovery router contracts**/
    /** These are stored for frontends to easily find the router contract address from the given account account address**/
    mapping(address => address) internal accountToRouter;

    constructor(
        address _verifier,
        address _dkimRegistry,
        address _emailAuthImpl
    ) {
        verifierAddr = _verifier;
        dkimAddr = _dkimRegistry;
        emailAuthImplementationAddr = _emailAuthImpl;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Initialize the module with the given data
     */
    function configureRecovery(
        address[] memory guardians,
        uint256[] memory weights,
        uint256 threshold,
        uint256 recoveryDelay,
        uint256 recoveryExpiry
    ) external {
        address account = msg.sender;

        setupGuardians(account, guardians, weights, threshold);

        if (recoveryRequests[account].totalWeight > 0) {
            revert RecoveryInProcess();
        }

        address router = deployRouterForAccount(account);

        recoveryConfigs[account] = RecoveryConfig(
            recoveryDelay,
            recoveryExpiry
        );

        emit RecoveryConfigured(account, recoveryDelay, recoveryExpiry, router);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    MODULE LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IZkEmailRecovery
    function getRecoveryConfig(
        address account
    ) external view returns (RecoveryConfig memory) {
        return recoveryConfigs[account];
    }

    /// @inheritdoc IZkEmailRecovery
    function getRecoveryRequest(
        address account
    ) external view returns (RecoveryRequest memory) {
        return recoveryRequests[account];
    }

    /// @inheritdoc EmailAccountRecovery
    function acceptanceSubjectTemplates()
        public
        pure
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

    /// @inheritdoc EmailAccountRecovery
    function recoverySubjectTemplates()
        public
        pure
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

    function acceptGuardian(
        address guardian,
        uint templateIdx,
        bytes[] memory subjectParams,
        bytes32
    ) internal override {
        if (guardian == address(0)) revert InvalidGuardian();
        if (templateIdx != 0) revert InvalidTemplateIndex();
        if (subjectParams.length != 1) revert InvalidSubjectParams();

        address accountInEmail = abi.decode(subjectParams[0], (address));

        if (recoveryRequests[accountInEmail].totalWeight > 0) {
            revert RecoveryInProcess();
        }

        GuardianStorage memory guardianStorage = getGuardian(
            accountInEmail,
            guardian
        );
        if (guardianStorage.status != GuardianStatus.REQUESTED)
            revert InvalidGuardianStatus(
                guardianStorage.status,
                GuardianStatus.REQUESTED
            );

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
        bytes32 nullifier
    ) internal override {
        if (guardian == address(0)) revert InvalidGuardian();
        if (templateIdx != 0) revert InvalidTemplateIndex();
        if (subjectParams.length != 3) revert InvalidSubjectParams();

        address accountInEmail = abi.decode(subjectParams[0], (address));
        address newOwnerInEmail = abi.decode(subjectParams[1], (address));
        address recoveryModuleInEmail = abi.decode(subjectParams[2], (address));

        GuardianStorage memory guardian = getGuardian(accountInEmail, guardian);
        if (guardian.status != GuardianStatus.ACCEPTED)
            revert InvalidGuardianStatus(
                guardian.status,
                GuardianStatus.ACCEPTED
            );
        if (newOwnerInEmail == address(0)) revert InvalidNewOwner();
        if (recoveryModuleInEmail == address(0)) revert InvalidRecoveryModule();

        RecoveryRequest storage recoveryRequest = recoveryRequests[
            accountInEmail
        ];

        recoveryRequest.totalWeight += guardian.weight;

        uint256 threshold = getGuardianConfig(accountInEmail).threshold;
        if (recoveryRequest.totalWeight >= threshold) {
            uint256 executeAfter = block.timestamp +
                recoveryConfigs[accountInEmail].recoveryDelay;
            uint256 executeBefore = block.timestamp +
                recoveryConfigs[accountInEmail].recoveryExpiry;

            recoveryRequest.executeAfter = executeAfter;
            recoveryRequest.executeBefore = executeBefore;
            recoveryRequest.newOwner = newOwnerInEmail;
            recoveryRequest.recoveryModule = recoveryModuleInEmail;

            emit RecoveryInitiated(accountInEmail, executeAfter);

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
        if (recoveryRequest.totalWeight < threshold)
            revert NotEnoughApprovals();

        if (block.timestamp < recoveryRequest.executeAfter)
            revert DelayNotPassed();

        if (block.timestamp >= recoveryRequest.executeBefore) {
            delete recoveryRequests[account];
            revert RecoveryRequestExpired();
        }

        delete recoveryRequests[account];

        IRecoveryModule(recoveryRequest.recoveryModule).recover(
            account,
            recoveryRequest.newOwner
        );

        emit RecoveryCompleted(account);
    }

    /// @inheritdoc IZkEmailRecovery
    function cancelRecovery() external {
        address account = msg.sender;
        delete recoveryRequests[account];
        emit RecoveryCancelled(account);
    }

    /// @inheritdoc IZkEmailRecovery
    function updateRecoveryDelay(uint256 recoveryDelay) external {
        // TODO: add implementation
    }

    /*//////////////////////////////////////////////////////////////////////////
                                GUARDIAN LOGIC
    //////////////////////////////////////////////////////////////////////////*/

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
        uint256 guardianCount = _guardians.length;
        // Threshold can only be 0 at initialization.
        // Check ensures that setup function can only be called once.
        if (guardianConfigs[account].threshold > 0) revert SetupAlreadyCalled();

        // Validate that threshold is smaller than number of added owners.
        if (threshold > guardianCount)
            revert ThresholdCannotExceedGuardianCount();

        // There has to be at least one Account owner.
        if (threshold == 0) revert ThresholdCannotBeZero();

        for (uint256 i = 0; i < guardianCount; i++) {
            address _guardian = _guardians[i];
            uint256 weight = weights[i];
            GuardianStorage memory _guardianStorage = guardianStorage[account][
                _guardian
            ];

            if (_guardian == address(0) || _guardian == address(this))
                revert InvalidGuardianAddress();

            if (_guardianStorage.status == GuardianStatus.REQUESTED)
                revert AddressAlreadyRequested();

            if (_guardianStorage.status == GuardianStatus.ACCEPTED)
                revert AddressAlreadyGuardian();

            guardianStorage[account][_guardian] = GuardianStorage(
                GuardianStatus.REQUESTED,
                weight
            );
        }

        guardianConfigs[account] = GuardianConfig(guardianCount, threshold);
    }

    // @inheritdoc IZkEmailRecovery
    function updateGuardian(
        address guardian,
        GuardianStorage memory _guardianStorage
    ) external override onlyConfiguredAccount {
        _updateGuardian(msg.sender, guardian, _guardianStorage);
    }

    function _updateGuardian(
        address account,
        address guardian,
        GuardianStorage memory _guardianStorage
    ) internal {
        if (account == address(0) || account == address(this))
            revert InvalidAccountAddress();

        if (guardian == address(0) || guardian == address(this))
            revert InvalidGuardianAddress();

        GuardianStorage memory oldGuardian = guardianStorage[account][guardian];
        if (_guardianStorage.status == oldGuardian.status)
            revert GuardianStatusMustBeDifferent();

        guardianStorage[account][guardian] = GuardianStorage(
            _guardianStorage.status,
            _guardianStorage.weight
        );
    }

    // @inheritdoc IZkEmailRecovery
    function addGuardianWithThreshold(
        address guardian,
        uint256 weight,
        uint256 threshold
    ) public override onlyConfiguredAccount {
        address account = msg.sender;
        GuardianStorage memory _guardianStorage = guardianStorage[account][
            guardian
        ];

        // Guardian address cannot be null, the sentinel or the Account itself.
        if (guardian == address(0) || guardian == address(this))
            revert InvalidGuardianAddress();

        if (_guardianStorage.status == GuardianStatus.REQUESTED)
            revert AddressAlreadyRequested();

        if (_guardianStorage.status == GuardianStatus.ACCEPTED)
            revert AddressAlreadyGuardian();

        guardianStorage[account][guardian] = GuardianStorage(
            GuardianStatus.REQUESTED,
            weight
        );
        guardianConfigs[account].guardianCount++;

        emit AddedGuardian(guardian);

        // Change threshold if threshold was changed.
        if (guardianConfigs[account].threshold != threshold)
            _changeThreshold(account, threshold);
    }

    // @inheritdoc IZkEmailRecovery
    function removeGuardian(
        address guardian,
        uint256 threshold
    ) public override onlyConfiguredAccount {
        address account = msg.sender;
        // Only allow to remove an guardian, if threshold can still be reached.
        if (guardianConfigs[account].threshold - 1 < threshold)
            revert ThresholdCannotExceedGuardianCount();

        if (guardian == address(0)) revert InvalidGuardianAddress();

        guardianStorage[account][guardian].status = GuardianStatus.NONE;
        guardianConfigs[account].guardianCount--;

        emit RemovedGuardian(guardian);

        // Change threshold if threshold was changed.
        if (guardianConfigs[account].threshold != threshold)
            _changeThreshold(account, threshold);
    }

    // @inheritdoc IZkEmailRecovery
    function swapGuardian(
        address oldGuardian,
        address newGuardian
    ) public override onlyConfiguredAccount {
        address account = msg.sender;

        GuardianStatus newGuardianStatus = guardianStorage[account][newGuardian]
            .status;

        if (
            newGuardian == address(0) ||
            newGuardian == address(this) ||
            newGuardian == oldGuardian
        ) revert InvalidGuardianAddress();

        if (newGuardianStatus == GuardianStatus.REQUESTED)
            revert AddressAlreadyRequested();

        if (newGuardianStatus == GuardianStatus.ACCEPTED)
            revert AddressAlreadyGuardian();

        GuardianStorage memory oldGuardianStorage = guardianStorage[account][
            oldGuardian
        ];

        if (oldGuardianStorage.status == GuardianStatus.REQUESTED)
            revert AddressAlreadyRequested();

        guardianStorage[account][newGuardian] = GuardianStorage(
            GuardianStatus.REQUESTED,
            oldGuardianStorage.weight
        );
        guardianStorage[account][oldGuardian] = GuardianStorage(
            GuardianStatus.NONE,
            0
        );

        emit RemovedGuardian(oldGuardian);
        emit AddedGuardian(newGuardian);
    }

    // @inheritdoc IZkEmailRecovery
    function changeThreshold(
        uint256 threshold
    ) public override onlyConfiguredAccount {
        address account = msg.sender;
        _changeThreshold(account, threshold);
    }

    function _changeThreshold(address account, uint256 threshold) private {
        // Validate that threshold is smaller than number of guardians.
        if (threshold > guardianConfigs[account].guardianCount)
            revert ThresholdCannotExceedGuardianCount();

        // There has to be at least one Account guardian.
        if (threshold == 0) revert ThresholdCannotBeZero();

        guardianConfigs[account].threshold = threshold;
        emit ChangedThreshold(threshold);
    }

    // @inheritdoc IZkEmailRecovery
    function getGuardianConfig(
        address account
    ) public view override returns (GuardianConfig memory) {
        return guardianConfigs[account];
    }

    // @inheritdoc IZkEmailRecovery
    function getGuardian(
        address account,
        address guardian
    ) public view returns (GuardianStorage memory) {
        return guardianStorage[account][guardian];
    }

    // @inheritdoc IZkEmailRecovery
    function isGuardian(
        address guardian,
        address account
    ) public view override returns (bool) {
        return guardianStorage[account][guardian].status != GuardianStatus.NONE;
    }

    modifier onlyConfiguredAccount() {
        checkConfigured(msg.sender);
        _;
    }

    function checkConfigured(address account) internal {
        bool authorized = guardianConfigs[account].guardianCount > 0;
        if (!authorized) revert AccountNotConfigured();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ROUTER LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IZkEmailRecovery
    function getAccountForRouter(
        address recoveryRouter
    ) public view override returns (address) {
        return routerToAccount[recoveryRouter];
    }

    /// @inheritdoc IZkEmailRecovery
    function getRouterForAccount(
        address account
    ) public view override returns (address) {
        return accountToRouter[account];
    }

    function deployRouterForAccount(
        address account
    ) internal returns (address) {
        if (accountToRouter[account] != address(0))
            revert RouterAlreadyDeployed();

        EmailAccountRecoveryRouter emailAccountRecoveryRouter = new EmailAccountRecoveryRouter(
                address(this)
            );
        address routerAddress = address(emailAccountRecoveryRouter);

        routerToAccount[routerAddress] = account;
        accountToRouter[account] = routerAddress;

        return routerAddress;
    }
}
