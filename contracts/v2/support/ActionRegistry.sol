// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IActionRegistry.sol";

/**
 * @title ActionRegistry
 * @notice Manages approved action adapters and protocols
 * @dev Maps function selectors to adapter contracts
 */
contract ActionRegistry is IActionRegistry, Ownable {

    // ============ State Variables ============

    mapping(bytes4 => AdapterInfo) private adapters;
    mapping(address => bool) private approvedProtocols;

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Admin Functions ============

    /// @inheritdoc IActionRegistry
    function registerAdapter(
        bytes4 selector,
        address adapter,
        uint256 gasLimit,
        bool requiresTokens
    ) external onlyOwner {
        if (adapter == address(0)) revert InvalidAdapter();
        require(gasLimit > 0 && gasLimit <= 5000000, "Invalid gas limit");

        adapters[selector] = AdapterInfo({
            adapter: adapter,
            isActive: true,
            gasLimit: gasLimit,
            requiresTokens: requiresTokens
        });

        emit AdapterRegistered(selector, adapter);
    }

    /// @inheritdoc IActionRegistry
    function deactivateAdapter(bytes4 selector) external onlyOwner {
        adapters[selector].isActive = false;
        emit AdapterDeactivated(selector);
    }

    /// @inheritdoc IActionRegistry
    function approveProtocol(address protocol) external onlyOwner {
        require(protocol != address(0), "Invalid protocol");
        approvedProtocols[protocol] = true;
        emit ProtocolApproved(protocol);
    }

    /// @inheritdoc IActionRegistry
    function revokeProtocol(address protocol) external onlyOwner {
        approvedProtocols[protocol] = false;
        emit ProtocolRevoked(protocol);
    }

    /// @notice Batch approve protocols
    function batchApproveProtocols(address[] calldata protocols) external onlyOwner {
        for (uint256 i = 0; i < protocols.length; i++) {
            approvedProtocols[protocols[i]] = true;
            emit ProtocolApproved(protocols[i]);
        }
    }

    // ============ View Functions ============

    /// @inheritdoc IActionRegistry
    function getAdapter(bytes4 selector) external view returns (AdapterInfo memory) {
        AdapterInfo memory info = adapters[selector];
        if (info.adapter == address(0)) revert AdapterNotFound();
        return info;
    }

    /// @inheritdoc IActionRegistry
    function isActionAllowed(bytes4 selector, address protocol) external view returns (bool) {
        AdapterInfo memory info = adapters[selector];
        return info.isActive && approvedProtocols[protocol];
    }

    /// @inheritdoc IActionRegistry
    function isProtocolApproved(address protocol) external view returns (bool) {
        return approvedProtocols[protocol];
    }
}
