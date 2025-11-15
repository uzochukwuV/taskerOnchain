// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IConditionOracle.sol";

/**
 * @title ITaskFactory
 * @notice Interface for TaskFactory contract that deploys new tasks
 */
interface ITaskFactory {

    // ============ Structs ============

    struct TaskParams {
        uint256 expiresAt;
        uint256 maxExecutions;
        uint256 recurringInterval;
        uint256 rewardPerExecution;
        bytes32 seedCommitment;
    }

    struct ConditionParams {
        IConditionOracle.ConditionType conditionType;
        bytes conditionData;
    }

    struct ActionParams {
        bytes4 selector;
        address protocol;
        bytes params;
    }

    struct TokenDeposit {
        address token;
        uint256 amount;
    }

    struct DeployedTask {
        uint256 taskId;
        address taskCore;
        address taskVault;
        address creator;
    }

    // ============ Events ============

    event TaskCreated(
        uint256 indexed taskId,
        address indexed creator,
        address indexed taskCore,
        address taskVault,
        uint256 reward,
        uint256 maxExecutions
    );

    event MinTaskRewardUpdated(uint256 oldMin, uint256 newMin);
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);

    // ============ Errors ============

    error InvalidReward();
    error InvalidExpiration();
    error InvalidActions();
    error InsufficientCreationFee();
    error DeploymentFailed();

    // ============ Functions ============

    /// @notice Create a new task with native token reward
    function createTask(
        TaskParams calldata params,
        ConditionParams calldata condition,
        ActionParams[] calldata actions
    ) external payable returns (uint256 taskId, address taskCore, address taskVault);

    /// @notice Create task with ERC20 token deposits
    function createTaskWithTokens(
        TaskParams calldata params,
        ConditionParams calldata condition,
        ActionParams[] calldata actions,
        TokenDeposit[] calldata deposits
    ) external payable returns (uint256 taskId, address taskCore, address taskVault);

    /// @notice Get task addresses by ID
    function getTaskAddresses(uint256 taskId)
        external
        view
        returns (address taskCore, address taskVault);

    /// @notice Get deployed task info
    function getTask(uint256 taskId) external view returns (DeployedTask memory);

    /// @notice Get next task ID
    function nextTaskId() external view returns (uint256);

    /// @notice Get minimum task reward
    function minTaskReward() external view returns (uint256);

    /// @notice Get creation fee
    function creationFee() external view returns (uint256);
}
