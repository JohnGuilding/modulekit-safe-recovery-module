// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import { ERC7579ValidatorBase } from "@rhinestone/modulekit/src/Modules.sol";
import { PackedUserOperation } from "@rhinestone/modulekit/src/external/ERC4337.sol";

import { SignatureCheckerLib } from "solady/src/utils/SignatureCheckerLib.sol";
import { ECDSA } from "solady/src/utils/ECDSA.sol";
import { EncodedModuleTypes, ModuleTypeLib, ModuleType } from "erc7579/lib/ModuleTypeLib.sol";

contract SubValidator is ERC7579ValidatorBase {
    using SignatureCheckerLib for address;

    mapping(address subAccout => address owner) public owners;

    function onInstall(bytes calldata data) external override {
        if (data.length == 0) return;
        address owner = abi.decode(data, (address));
        owners[msg.sender] = owner;
    }

    function onUninstall(bytes calldata) external override {
        delete owners[msg.sender];
    }

    function _validate(
        address owner,
        bytes calldata signature,
        bytes32 userOpHash
    )
        internal
        view
        returns (bool validSig)
    {
        address recover = ECDSA.recoverCalldata(userOpHash, signature);
        validSig = recover == owner;
    }

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    )
        external
        view
        override
        returns (ValidationData)
    {
        bool validSig = _validate(owners[userOp.sender], userOp.signature, userOpHash);
        return _packValidationData(!validSig, type(uint48).max, 0);
    }

    function validateUserOpWithData(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        bytes calldata validationData
    )
        external
        view
        returns (bool validSignature)
    {
        address owner = abi.decode(validationData, (address));
        return _validate(owner, userOp.signature, userOpHash);
    }

    function isValidSignatureWithSender(
        address,
        bytes32 hash,
        bytes calldata data
    )
        external
        view
        override
        returns (bytes4)
    { }

    function name() external pure returns (string memory) {
        return "ECDSAValidator";
    }

    function version() external pure returns (string memory) {
        return "0.0.1";
    }

    function isModuleType(uint256 typeID) external pure override returns (bool) {
        return typeID == TYPE_VALIDATOR;
    }

    function getModuleTypes() external view returns (EncodedModuleTypes) { }

    function isInitialized(address smartAccount) external view returns (bool) { }
}
