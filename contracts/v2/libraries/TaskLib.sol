// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TaskLib
 * @notice Library for task-related utility functions
 */
library TaskLib {

    /**
     * @notice Hash a condition for Merkle tree
     * @param conditionType Type of condition
     * @param conditionData Encoded condition parameters
     * @return bytes32 Hash of the condition
     */
    function hashCondition(uint8 conditionType, bytes memory conditionData)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(conditionType, conditionData));
    }

    /**
     * @notice Hash an action for Merkle tree
     * @param selector Function selector
     * @param protocol Protocol address
     * @param params Action parameters
     * @return bytes32 Hash of the action
     */
    function hashAction(bytes4 selector, address protocol, bytes memory params)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(selector, protocol, params));
    }

    /**
     * @notice Compute Merkle root from array of hashes
     * @param leaves Array of leaf hashes
     * @return bytes32 Merkle root
     */
    function computeMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "Empty leaves");

        if (leaves.length == 1) {
            return leaves[0];
        }

        // Build tree bottom-up
        uint256 n = leaves.length;
        bytes32[] memory tree = new bytes32[](n);

        // Copy leaves
        for (uint256 i = 0; i < n; i++) {
            tree[i] = leaves[i];
        }

        // Build layers
        uint256 layerSize = n;
        while (layerSize > 1) {
            for (uint256 i = 0; i < layerSize / 2; i++) {
                tree[i] = _hashPair(tree[2 * i], tree[2 * i + 1]);
            }

            // Handle odd number of nodes
            if (layerSize % 2 == 1) {
                tree[layerSize / 2] = tree[layerSize - 1];
                layerSize = layerSize / 2 + 1;
            } else {
                layerSize = layerSize / 2;
            }
        }

        return tree[0];
    }

    /**
     * @notice Hash pair in sorted order
     */
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? _efficientHash(a, b) : _efficientHash(b, a);
    }

    /**
     * @notice Efficient hash of two bytes32
     */
    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }
}
