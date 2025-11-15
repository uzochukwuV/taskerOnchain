// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MerkleProof
 * @notice Library for verifying Merkle proofs
 * @dev Used to verify condition and action data against stored hashes
 */
library MerkleProof {

    /**
     * @notice Verify a Merkle proof
     * @param proof Array of sibling hashes
     * @param root The Merkle root to verify against
     * @param leaf The leaf node to verify
     * @return bool Whether the proof is valid
     */
    function verify(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        return processProof(proof, leaf) == root;
    }

    /**
     * @notice Process a Merkle proof to compute the root
     * @param proof Array of sibling hashes
     * @param leaf The leaf node to start from
     * @return bytes32 The computed Merkle root
     */
    function processProof(bytes32[] memory proof, bytes32 leaf) internal pure returns (bytes32) {
        bytes32 computedHash = leaf;

        for (uint256 i = 0; i < proof.length; i++) {
            computedHash = _hashPair(computedHash, proof[i]);
        }

        return computedHash;
    }

    /**
     * @notice Hash a pair of nodes in sorted order
     * @param a First hash
     * @param b Second hash
     * @return bytes32 Hash of the pair
     */
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? _efficientHash(a, b) : _efficientHash(b, a);
    }

    /**
     * @notice Efficiently hash two bytes32 values
     * @param a First value
     * @param b Second value
     * @return value Keccak256 hash
     */
    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }

    /**
     * @notice Verify multiple leaves against a Merkle root
     * @param proof Array of sibling hashes
     * @param root The Merkle root
     * @param leaves Array of leaves to verify
     * @return bool Whether all leaves are valid
     */
    function multiVerify(
        bytes32[] memory proof,
        bytes32 root,
        bytes32[] memory leaves
    ) internal pure returns (bool) {
        bytes32 computedHash = leaves[0];

        // Hash all leaves together
        for (uint256 i = 1; i < leaves.length; i++) {
            computedHash = _hashPair(computedHash, leaves[i]);
        }

        // Process proof
        return processProof(proof, computedHash) == root;
    }
}
