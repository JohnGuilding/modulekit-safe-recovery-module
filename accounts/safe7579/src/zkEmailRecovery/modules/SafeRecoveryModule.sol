// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { IERC7579Account } from "erc7579/interfaces/IERC7579Account.sol";
import { ExecutionLib } from "erc7579/lib/ExecutionLib.sol";
import { ModeLib } from "erc7579/lib/ModeLib.sol";
import { EmailAuth } from "ether-email-auth/packages/contracts/src/EmailAuth.sol";
import { Create2 } from "@openzeppelin/contracts/utils/Create2.sol";
import { RecoveryModuleBase } from "./RecoveryModuleBase.sol";
import { IZkEmailRecovery } from "../interfaces/IZkEmailRecovery.sol";
import { ISafe } from "../interfaces/ISafe.sol";
import "forge-std/console2.sol";

contract SafeRecoveryModule is RecoveryModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/
    error InvalidOldOwner();
    error InvalidSubjectParams();
    error InvalidNewOwner();
    error AccountNotConfigured();

    mapping(address => bool) public accountIsConfigured;

    constructor(address _zkEmailRecovery) {
        zkEmailRecovery = _zkEmailRecovery;
    }

    modifier onlyConfiguredAccount(address account) {
        if (!accountIsConfigured[account]) revert AccountNotConfigured();
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Initialize the module with the given data
     * @param data The data to initialize the module with
     */
    function onInstall(bytes calldata data) external {
        address account = msg.sender;
        accountIsConfigured[account] = true;
        (
            address[] memory guardians,
            uint256[] memory weights,
            uint256 threshold,
            uint256 delay,
            uint256 expiry
        ) = abi.decode(data, (address[], uint256[], uint256, uint256, uint256));

        _execute({
            target: zkEmailRecovery,
            value: 0,
            callData: abi.encodeCall(
                IZkEmailRecovery.configureRecovery,
                (address(this), guardians, weights, threshold, delay, expiry)
            )
        });
    }

    /**
     * De-initialize the module with the given data
     * @param data The data to de-initialize the module with
     */
    function onUninstall(bytes calldata data) external {
        accountIsConfigured[msg.sender] = false;
        bytes memory encodedCall = abi.encodeWithSignature("deInitializeRecovery()");
        _execute(msg.sender, zkEmailRecovery, 0, encodedCall);
    }

    /**
     * Check if the module is initialized
     * @param smartAccount The smart account to check
     * @return true if the module is initialized, false otherwise
     */
    function isInitialized(address smartAccount) external view returns (bool) {
        return accountIsConfigured[smartAccount];
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODULE LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    function _recover(
        address account,
        bytes[] calldata subjectParams
    )
        internal
        override
        onlyConfiguredAccount(account)
    {
        // prevent out of bounds error message, in case subject params are invalid
        if (subjectParams.length < 3) revert InvalidSubjectParams();
        address oldOwner = abi.decode(subjectParams[1], (address));
        address newOwner = abi.decode(subjectParams[2], (address));

        bool isOwner = ISafe(account).isOwner(oldOwner);
        if (!isOwner) {
            revert InvalidOldOwner();
        }
        if (newOwner == address(0)) {
            revert InvalidNewOwner();
        }

        address previousOwnerInLinkedList = getPreviousOwnerInLinkedList(account, oldOwner);
        _execute({
            account: account,
            to: account,
            value: 0,
            data: abi.encodeCall(ISafe.swapOwner, (previousOwnerInLinkedList, oldOwner, newOwner))
        });
    }

    /**
     * @notice Helper function that retrieves the owner that points to the owner to be
     * replaced in the Safe `owners` linked list. Based on the logic used to swap
     * owners in the safe core sdk.
     * @param safe the safe account to query
     * @param oldOwner the old owner to be swapped in the recovery attempt.
     */
    function getPreviousOwnerInLinkedList(
        address safe,
        address oldOwner
    )
        internal
        view
        returns (address)
    {
        address[] memory owners = ISafe(safe).getOwners();
        uint256 length = owners.length;

        uint256 oldOwnerIndex;
        for (uint256 i; i < length; i++) {
            if (owners[i] == oldOwner) {
                oldOwnerIndex = i;
                break;
            }
        }
        address sentinelOwner = address(0x1);
        return oldOwnerIndex == 0 ? sentinelOwner : owners[oldOwnerIndex - 1];
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     METADATA
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * The name of the module
     * @return name The name of the module
     */
    function name() external pure returns (string memory) {
        return "SafeRecoveryModule";
    }

    /**
     * The version of the module
     * @return version The version of the module
     */
    function version() external pure returns (string memory) {
        return "0.0.1";
    }
}
