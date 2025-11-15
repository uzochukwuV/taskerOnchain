// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITaskCore
 * @notice Interface for TaskCore contract that manages task metadata and lifecycle
 */
interface ITaskCore {

    // ============ Enums ============

    enum TaskStatus {
        ACTIVE,      // Ready for execution
        PAUSED,      // Temporarily disabled by creator
        EXECUTING,   // Currently being executed
        COMPLETED,   // All executions finished
        CANCELLED,   // Cancelled by creator
        EXPIRED      // Past expiration time
    }

    // ============ Structs ============

    struct TaskMetadata {
        uint256 id;
        address creator;
        uint96 createdAt;           // Packed with creator
        uint256 expiresAt;
        uint256 maxExecutions;
        uint256 executionCount;
        uint256 lastExecutionTime;
        uint256 recurringInterval;
        uint256 rewardPerExecution;
        TaskStatus status;
        bytes32 conditionHash;      // Hash of condition params
        bytes32 actionsHash;        // Hash of actions array
        bytes32 seedCommitment;     // Commitment for executor authorization
    }

    // ============ Events ============

    event TaskExecuted(
        uint256 indexed taskId,
        address indexed executor,
        bool success,
        uint256 reward,
        uint256 gasUsed
    );

    event TaskStatusChanged(
        uint256 indexed taskId,
        TaskStatus oldStatus,
        TaskStatus newStatus
    );

    event TaskCancelled(uint256 indexed taskId, address indexed creator);

    event TaskRewardUpdated(uint256 indexed taskId, uint256 oldReward, uint256 newReward);

    // ============ Functions ============

    /// @notice Initialize the task (called by factory)
    function initialize(
        uint256 _id,
        address _creator,
        address _vault,
        address _logic,
        TaskMetadata calldata _metadata
    ) external;

    /// @notice Execute the task (called by TaskLogic)
    function executeTask(address executor) external returns (bool success);

    /// @notice Cancel the task and refund funds
    function cancel() external returns (uint256 refundAmount);

    /// @notice Pause the task
    function pause() external;

    /// @notice Resume a paused task
    function resume() external;

    /// @notice Update task reward (with additional funding if needed)
    function updateReward(uint256 newReward) external payable;

    /// @notice Check if task is executable
    function isExecutable() external view returns (bool);

    /// @notice Get task metadata
    function getMetadata() external view returns (TaskMetadata memory);

    /// @notice Get task vault address
    function vault() external view returns (address);

    /// @notice Get task logic address
    function logic() external view returns (address);

    /// @notice Get task creator
    function creator() external view returns (address);

    /// @notice Get task ID
    function taskId() external view returns (uint256);
}
