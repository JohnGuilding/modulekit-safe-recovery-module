// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ERC7579ExecutorBase } from "@rhinestone/modulekit/src/Modules.sol";

abstract contract RecoveryModuleBase is ERC7579ExecutorBase {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    error NotTrustedRecoveryContract();

    address public immutable zkEmailRecovery;

    modifier onlyZkEmailRecovery() {
        if (msg.sender != zkEmailRecovery) revert NotTrustedRecoveryContract();
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODULE LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    function recover(
        address account,
        bytes[] calldata subjectParams
    )
        external
        virtual
        onlyZkEmailRecovery
    {
        _recover(account, subjectParams);
    }

    function _recover(address account, bytes[] calldata subjectParams) internal virtual;

    /*//////////////////////////////////////////////////////////////////////////
                                     METADATA
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Check if the module is of a certain type
     * @param typeID The type ID to check
     * @return true if the module is of the given type, false otherwise
     */
    function isModuleType(uint256 typeID) external pure virtual returns (bool) {
        return typeID == TYPE_EXECUTOR;
    }
}
