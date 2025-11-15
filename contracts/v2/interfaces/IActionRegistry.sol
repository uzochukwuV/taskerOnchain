// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IActionRegistry
 * @notice Interface for ActionRegistry contract that manages action adapters
 */
interface IActionRegistry {

    // ============ Structs ============

    struct AdapterInfo {
        address adapter;
        bool isActive;
        uint256 gasLimit;
        bool requiresTokens;
    }

    // ============ Events ============

    event AdapterRegistered(bytes4 indexed selector, address indexed adapter);
    event AdapterDeactivated(bytes4 indexed selector);
    event ProtocolApproved(address indexed protocol);
    event ProtocolRevoked(address indexed protocol);

    // ============ Errors ============

    error AdapterNotFound();
    error AdapterNotActive();
    error ProtocolNotApproved();
    error InvalidAdapter();

    // ============ Functions ============

    /// @notice Register action adapter
    function registerAdapter(
        bytes4 selector,
        address adapter,
        uint256 gasLimit,
        bool requiresTokens
    ) external;

    /// @notice Deactivate adapter
    function deactivateAdapter(bytes4 selector) external;

    /// @notice Approve protocol for interactions
    function approveProtocol(address protocol) external;

    /// @notice Revoke protocol approval
    function revokeProtocol(address protocol) external;

    /// @notice Get adapter info
    function getAdapter(bytes4 selector) external view returns (AdapterInfo memory);

    /// @notice Check if action is allowed
    function isActionAllowed(bytes4 selector, address protocol) external view returns (bool);

    /// @notice Check if protocol is approved
    function isProtocolApproved(address protocol) external view returns (bool);
}
