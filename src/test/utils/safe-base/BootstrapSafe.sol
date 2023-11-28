// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.8.0 <0.9.0;

import { IBootstrap, InitialModule } from "../../../common/IBootstrap.sol";

contract Bootstrap is IBootstrap {
    address internal SENTINEL_ADDRESS = address(0x1);

    error InitializationFailed(address module);

    function initialize(InitialModule[] calldata modules, address owner) external {
        // ENABLE MODULES
        uint256 len = modules.length;
        for (uint256 i = 0; i < len;) {
            InitialModule calldata initialModule = modules[i];
            address module = initialModule.moduleAddress;
            if (initialModule.initializer.length != 0) {
                (bool success,) = module.call(initialModule.initializer);
                if (!success) {
                    revert InitializationFailed(module);
                }
            }
            if (initialModule.isSafeModule) {
                bytes32 moduleSlot = keccak256(abi.encode(module, 1));
                bytes32 sentinelModuleSlot = keccak256(abi.encode(SENTINEL_ADDRESS, 1));
                assembly {
                    sstore(moduleSlot, sload(0x00))
                    sstore(sentinelModuleSlot, module)
                    mstore(0x80, module)
                    log1(
                        0x80,
                        0x20,
                        // keccak256("EnabledModule(address)")
                        0xecdf3a3effea5783a3c4c2140e677577666428d44ed9d474a0b3a4c9943f8440
                    )
                }
            }
            unchecked {
                i++;
            }
        }
        // REMOVE OWNER
        bytes32 ownerSlot = keccak256(abi.encode(owner, 2));
        bytes32 sentinelOwnerSlot = keccak256(abi.encode(SENTINEL_ADDRESS, 2));
        assembly {
            sstore(ownerSlot, 0x0000000000000000000000000000000000000000000000000000000000000000)
            sstore(sentinelOwnerSlot, sload(0x00))
            sstore(0x0000000000000000000000000000000000000000000000000000000000000003, 0x00)
        }
    }
}
