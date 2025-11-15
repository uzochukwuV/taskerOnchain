// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IActionAdapter.sol";

// Compound V3 Comet Interface
interface IComet {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title CompoundAdapter
 * @notice Adapter for Compound V3 (Comet) lending protocol
 * @dev Supports supply and withdraw operations
 */
contract CompoundAdapter is IActionAdapter, Ownable {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    enum ActionType {
        SUPPLY,       // Deposit assets to earn yield
        WITHDRAW      // Withdraw deposited assets
    }

    // ============ Structs ============

    struct CompoundParams {
        ActionType actionType;
        address comet;          // Comet market address
        address asset;          // Asset to interact with
        uint256 amount;         // Amount (use type(uint256).max for full balance)
        address recipient;      // Where to send withdrawn funds
    }

    // ============ State Variables ============

    mapping(address => bool) public supportedComets;

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Core Functions ============

    /// @inheritdoc IActionAdapter
    function execute(address vault, bytes calldata params)
        external
        override
        returns (bool success, bytes memory result)
    {
        require(msg.sender == vault, "Only vault");

        CompoundParams memory compoundParams = abi.decode(params, (CompoundParams));

        require(supportedComets[compoundParams.comet], "Comet not supported");
        require(compoundParams.asset != address(0), "Invalid asset");

        if (compoundParams.actionType == ActionType.SUPPLY) {
            return _supply(vault, compoundParams);
        } else if (compoundParams.actionType == ActionType.WITHDRAW) {
            return _withdraw(vault, compoundParams);
        } else {
            revert ExecutionFailed("Invalid action type");
        }
    }

    // ============ Action Implementations ============

    function _supply(address vault, CompoundParams memory params)
        internal
        returns (bool, bytes memory)
    {
        IERC20 asset = IERC20(params.asset);

        // Pull tokens from vault
        asset.safeTransferFrom(vault, address(this), params.amount);

        // Approve comet
        asset.safeApprove(params.comet, params.amount);

        // Supply to Compound
        try IComet(params.comet).supply(params.asset, params.amount) {
            // Clear approval
            asset.safeApprove(params.comet, 0);

            // Transfer cTokens to vault
            uint256 cTokenBalance = IComet(params.comet).balanceOf(address(this));
            if (cTokenBalance > 0) {
                IERC20(params.comet).safeTransfer(vault, cTokenBalance);
            }

            emit ActionExecuted(vault, params.comet, true, abi.encode(params.amount));
            return (true, abi.encode(params.amount));
        } catch Error(string memory reason) {
            // Return tokens to vault
            asset.safeApprove(params.comet, 0);
            asset.safeTransfer(vault, params.amount);

            return (false, bytes(reason));
        }
    }

    function _withdraw(address vault, CompoundParams memory params)
        internal
        returns (bool, bytes memory)
    {
        // Note: This requires the vault to hold cTokens
        // We'll pull cTokens from vault and withdraw

        try IComet(params.comet).withdraw(
            params.asset,
            params.amount
        ) {
            // Transfer withdrawn assets to recipient
            uint256 balance = IERC20(params.asset).balanceOf(address(this));
            IERC20(params.asset).safeTransfer(params.recipient, balance);

            emit ActionExecuted(vault, params.comet, true, abi.encode(balance));
            return (true, abi.encode(balance));
        } catch Error(string memory reason) {
            return (false, bytes(reason));
        }
    }

    // ============ View Functions ============

    /// @inheritdoc IActionAdapter
    function isProtocolSupported(address protocol) external view override returns (bool) {
        return supportedComets[protocol];
    }

    /// @inheritdoc IActionAdapter
    function name() external pure override returns (string memory) {
        return "CompoundAdapter_v1.0";
    }

    // ============ Admin Functions ============

    function addComet(address comet) external onlyOwner {
        require(comet != address(0), "Invalid comet");
        supportedComets[comet] = true;
    }

    function removeComet(address comet) external onlyOwner {
        supportedComets[comet] = false;
    }

    function batchAddComets(address[] calldata comets) external onlyOwner {
        for (uint256 i = 0; i < comets.length; i++) {
            supportedComets[comets[i]] = true;
        }
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(to, amount);
    }
}
