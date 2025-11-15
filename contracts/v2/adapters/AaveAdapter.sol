// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IActionAdapter.sol";

// Aave V3 Pool Interface
interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf) external returns (uint256);
}

/**
 * @title AaveAdapter
 * @notice Adapter for Aave V3 lending protocol
 * @dev Supports supply, withdraw, borrow, and repay operations
 */
contract AaveAdapter is IActionAdapter, Ownable {
    using SafeERC20 for IERC20;

    // ============ Enums ============

    enum ActionType {
        SUPPLY,       // Deposit assets to earn yield
        WITHDRAW,     // Withdraw deposited assets
        BORROW,       // Borrow assets
        REPAY         // Repay borrowed assets
    }

    // ============ Structs ============

    struct AaveParams {
        ActionType actionType;
        address pool;           // Aave Pool address
        address asset;          // Asset to interact with
        uint256 amount;         // Amount (use type(uint256).max for full balance)
        address onBehalfOf;     // Address on behalf of (usually task creator)
        uint256 interestRateMode; // 1 = stable, 2 = variable (for borrow/repay)
    }

    // ============ State Variables ============

    mapping(address => bool) public supportedPools;

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

        AaveParams memory aaveParams = abi.decode(params, (AaveParams));

        require(supportedPools[aaveParams.pool], "Pool not supported");
        require(aaveParams.asset != address(0), "Invalid asset");
        require(aaveParams.onBehalfOf != address(0), "Invalid onBehalfOf");

        if (aaveParams.actionType == ActionType.SUPPLY) {
            return _supply(vault, aaveParams);
        } else if (aaveParams.actionType == ActionType.WITHDRAW) {
            return _withdraw(vault, aaveParams);
        } else if (aaveParams.actionType == ActionType.BORROW) {
            return _borrow(vault, aaveParams);
        } else if (aaveParams.actionType == ActionType.REPAY) {
            return _repay(vault, aaveParams);
        } else {
            revert ExecutionFailed("Invalid action type");
        }
    }

    // ============ Action Implementations ============

    function _supply(address vault, AaveParams memory params)
        internal
        returns (bool, bytes memory)
    {
        IERC20 asset = IERC20(params.asset);

        // Pull tokens from vault
        asset.safeTransferFrom(vault, address(this), params.amount);

        // Approve pool
        asset.safeApprove(params.pool, params.amount);

        // Supply to Aave
        try IPool(params.pool).supply(
            params.asset,
            params.amount,
            params.onBehalfOf,
            0 // No referral code
        ) {
            // Clear approval
            asset.safeApprove(params.pool, 0);

            emit ActionExecuted(vault, params.pool, true, abi.encode(params.amount));
            return (true, abi.encode(params.amount));
        } catch Error(string memory reason) {
            // Return tokens to vault
            asset.safeApprove(params.pool, 0);
            asset.safeTransfer(vault, params.amount);

            return (false, bytes(reason));
        }
    }

    function _withdraw(address vault, AaveParams memory params)
        internal
        returns (bool, bytes memory)
    {
        // Note: This withdraws aTokens from the onBehalfOf address
        // The vault must have approval to spend the aTokens

        try IPool(params.pool).withdraw(
            params.asset,
            params.amount,
            vault // Withdraw to vault
        ) returns (uint256 amountWithdrawn) {
            emit ActionExecuted(vault, params.pool, true, abi.encode(amountWithdrawn));
            return (true, abi.encode(amountWithdrawn));
        } catch Error(string memory reason) {
            return (false, bytes(reason));
        }
    }

    function _borrow(address vault, AaveParams memory params)
        internal
        returns (bool, bytes memory)
    {
        try IPool(params.pool).borrow(
            params.asset,
            params.amount,
            params.interestRateMode, // 1 = stable, 2 = variable
            0, // No referral code
            params.onBehalfOf
        ) {
            // Borrowed funds go to onBehalfOf address
            emit ActionExecuted(vault, params.pool, true, abi.encode(params.amount));
            return (true, abi.encode(params.amount));
        } catch Error(string memory reason) {
            return (false, bytes(reason));
        }
    }

    function _repay(address vault, AaveParams memory params)
        internal
        returns (bool, bytes memory)
    {
        IERC20 asset = IERC20(params.asset);

        // Pull tokens from vault
        asset.safeTransferFrom(vault, address(this), params.amount);

        // Approve pool
        asset.safeApprove(params.pool, params.amount);

        // Repay debt
        try IPool(params.pool).repay(
            params.asset,
            params.amount,
            params.interestRateMode,
            params.onBehalfOf
        ) returns (uint256 amountRepaid) {
            // Clear approval
            asset.safeApprove(params.pool, 0);

            // Return unused tokens if any
            uint256 remaining = params.amount - amountRepaid;
            if (remaining > 0) {
                asset.safeTransfer(vault, remaining);
            }

            emit ActionExecuted(vault, params.pool, true, abi.encode(amountRepaid));
            return (true, abi.encode(amountRepaid));
        } catch Error(string memory reason) {
            // Return tokens to vault
            asset.safeApprove(params.pool, 0);
            asset.safeTransfer(vault, params.amount);

            return (false, bytes(reason));
        }
    }

    // ============ View Functions ============

    /// @inheritdoc IActionAdapter
    function isProtocolSupported(address protocol) external view override returns (bool) {
        return supportedPools[protocol];
    }

    /// @inheritdoc IActionAdapter
    function name() external pure override returns (string memory) {
        return "AaveAdapter_v1.0";
    }

    // ============ Admin Functions ============

    function addPool(address pool) external onlyOwner {
        require(pool != address(0), "Invalid pool");
        supportedPools[pool] = true;
    }

    function removePool(address pool) external onlyOwner {
        supportedPools[pool] = false;
    }

    function batchAddPools(address[] calldata pools) external onlyOwner {
        for (uint256 i = 0; i < pools.length; i++) {
            supportedPools[pools[i]] = true;
        }
    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(to, amount);
    }
}
