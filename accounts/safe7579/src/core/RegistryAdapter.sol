// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { IERC7484 } from "../interfaces/IERC7484.sol";
import { ISafe, ExecOnSafeLib } from "../lib/ExecOnSafeLib.sol";

abstract contract RegistryAdapter {
    using ExecOnSafeLib for *;

    event ERC7484RegistryConfigured(address indexed smartAccount, address indexed registry);

    mapping(address smartAccount => IERC7484 registry) internal $registry;

    modifier withRegistry(address module, uint256 moduleType) {
        IERC7484 registry = $registry[msg.sender];
        if (address(registry) != address(0)) {
            registry.checkForAccount(msg.sender, module, moduleType);
        }
        _;
    }

    function _configureRegistry(
        IERC7484 registry,
        address[] calldata attesters,
        uint8 threshold
    )
        internal
    {
        $registry[msg.sender] = registry;
        ISafe(msg.sender).exec({
            target: address(registry),
            value: 0,
            callData: abi.encodeCall(IERC7484.trustAttesters, (threshold, attesters))
        });
    }
}
