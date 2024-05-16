// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IGuardianManager} from "./IGuardianManager.sol";

interface IZkEmailRecovery {
    struct RecoveryConfig {
        uint256 recoveryDelay; // the time from when recovery is started until the recovery request can be executed
        uint256 recoveryExpiry; // the time from when recovery is started until the recovery request becomes invalid
    }
    struct RecoveryRequest {
        uint256 executeAfter; // the timestamp from which the recovery request can be executed
        uint256 executeBefore; // the timestamp from which the recovery request becomes invalid
        uint256 totalWeight; // total weight of all guardian approvals for the recovery request
        address newOwner;
        address recoveryModule; // the trusted recovery module that has permission to recover an account
    }

    /** Errors */
    error InvalidGuardian();
    error InvalidRecoveryModule();
    error InvalidNewOwner();
    error InvalidTemplateIndex();
    error InvalidSubjectParams();
    error InvalidGuardianStatus(
        IGuardianManager.GuardianStatus guardianStatus,
        IGuardianManager.GuardianStatus expectedGuardianStatus
    );
    error RecoveryInProcess();
    error NotEnoughApprovals();
    error DelayNotPassed();
    error RecoveryRequestExpired();

    /** Events */
    event RecoveryConfigured(
        address indexed account,
        uint256 recoveryDelay,
        uint256 recoveryExpiry,
        address router
    );
    event RecoveryInitiated(address indexed account, uint256 executeAfter);
    event RecoveryCompleted(address indexed account);
    event RecoveryCancelled(address indexed account);

    /** Functions */

    /**
     * @notice Returns recovery request accociated with a account address
     * @param account address to query storage with
     */
    function getRecoveryRequest(
        address account
    ) external view returns (RecoveryRequest memory);

    /**
     * @notice Returns the recovery delay that corresponds to the specified account
     * @param account address to query storage with
     */
    function getRecoveryConfig(
        address account
    ) external view returns (RecoveryConfig memory);

    /**
     * @notice Cancels the recovery process of the sender if it exits.
     * @dev Deletes the recovery request accociated with a account. Assumes
     *      the msg.sender is the account that the recovery request is being deleted for
     */
    function cancelRecovery() external;

    // TODO: add natspec
    function updateRecoveryDelay(uint256 recoveryDelay) external;
}
