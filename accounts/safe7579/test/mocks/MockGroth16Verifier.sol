// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

struct EmailProof {
    string domainName; // Domain name of the sender's email
    bytes32 publicKeyHash; // Hash of the DKIM public key used in email/proof
    uint timestamp; // Timestamp of the email
    string maskedSubject; // Masked subject of the email
    bytes32 emailNullifier; // Nullifier of the email to prevent its reuse.
    bytes32 accountSalt; // Create2 salt of the account
    bool isCodeExist; // Check if the account code is exist
    bytes proof; // ZK Proof of Email
}

/** @notice Mock snarkjs Groth16 Solidity verifier */
contract MockGroth16Verifier {
    function verifyEmailProof(
        EmailProof memory proof
    ) public view returns (bool) {
        proof;

        return true;
    }
}
