// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IActionAdapter
 * @notice Standard interface for all action adapters
 */
interface IActionAdapter {

    // ============ Events ============

    event ActionExecuted(
        address indexed vault,
        address indexed protocol,
        bool success,
        bytes result
    );

    // ============ Errors ============

    error OnlyVault();
    error OnlyActionRegistry();
    error ProtocolNotSupported();
    error ExecutionFailed(string reason);

    // ============ Functions ============

    /// @notice Execute action (called by TaskVault)
    /// @param vault Address of the task vault
    /// @param params ABI-encoded parameters for the action
    /// @return success Whether the action succeeded
    /// @return result Return data from the action
    function execute(address vault, bytes calldata params)
        external
        returns (bool success, bytes memory result);

    /// @notice Check if protocol is supported
    function isProtocolSupported(address protocol) external view returns (bool);

    /// @notice Get adapter name/version
    function name() external view returns (string memory);
}
