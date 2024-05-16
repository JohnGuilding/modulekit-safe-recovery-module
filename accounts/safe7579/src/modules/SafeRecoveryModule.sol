// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC7579Account} from "erc7579/interfaces/IERC7579Account.sol";
import {ExecutionLib} from "erc7579/lib/ExecutionLib.sol";
import {ModeLib} from "erc7579/lib/ModeLib.sol";
import {EmailAuth} from "ether-email-auth/packages/contracts/src/EmailAuth.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {RecoveryModuleBase} from "./RecoveryModuleBase.sol";

interface ISafe {
    function getOwners() external view returns (address[] memory);
}

contract SafeRecoveryModule is RecoveryModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/
    error NoPreviousOwnersStored();

    struct RecoveryInfo {
        address oldOwner;
        address newOwner;
    }

    mapping(address => RecoveryInfo) public recoveryInfo;

    constructor(
        address _zkEmailRecovery
    ) RecoveryModuleBase(_zkEmailRecovery) {}

    /*//////////////////////////////////////////////////////////////////////////
                                     CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Initialize the module with the given data
     * @param data The data to initialize the module with
     */
    function onInstall(bytes calldata data) external override {
        // address oldOwner = abi.decode(data, (address));
        // oldOwners[msg.sender] = oldOwner;
    }

    /**
     * De-initialize the module with the given data
     * @param data The data to de-initialize the module with
     */
    function onUninstall(bytes calldata data) external override {}

    /**
     * Check if the module is initialized
     * @param smartAccount The smart account to check
     * @return true if the module is initialized, false otherwise
     */
    function isInitialized(
        address smartAccount
    ) external view override returns (bool) {
        return false;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODULE LOGIC
    //////////////////////////////////////////////////////////////////////////*/
    error CannotOverwriteOldOwner();
    error InvalidSignature();
    // storeOwner implementation for a Safe recovery module - the value we need to store for later is the old owner address

    function storeOwner(
        address account,
        address oldOwner,
        address newOwner
    ) external {
        address create2Owner = computeOwnerAddress(account, oldOwner, newOwner);
        recoveryInfo[create2Owner] = RecoveryInfo(oldOwner, newOwner);
    }

    function recover(address account, address create2Owner) external override {
        RecoveryInfo memory addressInfo = recoveryInfo[create2Owner];

        if (
            addressInfo.newOwner == address(0) ||
            addressInfo.oldOwner == address(0)
        ) {
            revert NoPreviousOwnersStored();
        }
        address previousOwnerInLinkedList = getPreviousOwnerInLinkedList(
            account,
            addressInfo.oldOwner
        );
        bytes memory encodedSwapOwnerCall = abi.encodeWithSignature(
            "swapOwner(address,address,address)",
            previousOwnerInLinkedList,
            addressInfo.oldOwner,
            addressInfo.newOwner
        );
        IERC7579Account(account).executeFromExecutor(
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(account, 0, encodedSwapOwnerCall)
        );
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
    ) internal view returns (address) {
        address[] memory owners = ISafe(safe).getOwners();

        uint256 oldOwnerIndex;
        for (uint256 i = 0; i < owners.length; i++) {
            if (owners[i] == oldOwner) {
                oldOwnerIndex = i;
                break;
            }
        }
        address sentinelOwner = address(0x1);
        return oldOwnerIndex == 0 ? sentinelOwner : owners[oldOwnerIndex - 1];
    }

    function computeOwnerAddress(
        address account,
        address oldOwner,
        address newOwner
    ) public returns (address) {
        // Having a secure salt doesn't matter here as the randomness comes from the
        // combination of addresses - importantly, the newOwner address, which should
        // not be known before the account needs to be recovered.
        bytes32 salt = keccak256(abi.encode(account));
        bytes32 ownerHash = keccak256(abi.encode(oldOwner, newOwner));
        return Create2.computeAddress(salt, ownerHash);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     METADATA
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * The name of the module
     * @return name The name of the module
     */
    function name() external pure override returns (string memory) {
        return "SafeRecoveryModule";
    }

    /**
     * The version of the module
     * @return version The version of the module
     */
    function version() external pure override returns (string memory) {
        return "0.0.1";
    }
}
