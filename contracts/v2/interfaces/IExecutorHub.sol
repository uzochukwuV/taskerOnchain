// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IExecutorHub
 * @notice Interface for ExecutorHub contract that manages executor lifecycle
 */
interface IExecutorHub {

    // ============ Structs ============

    struct Executor {
        address addr;
        uint128 stakedAmount;
        uint128 registeredAt;
        uint256 totalExecutions;
        uint256 successfulExecutions;
        uint256 failedExecutions;
        uint256 reputationScore;
        bool isActive;
        bool isSlashed;
    }

    struct ExecutionLock {
        address executor;
        uint96 lockedAt;
        bytes32 commitment;
    }

    // ============ Events ============

    event ExecutorRegistered(address indexed executor, uint256 stakeAmount);
    event ExecutorUnregistered(address indexed executor);
    event StakeAdded(address indexed executor, uint256 amount);
    event StakeWithdrawn(address indexed executor, uint256 amount);
    event ExecutionRequested(uint256 indexed taskId, address indexed executor, bytes32 commitment);
    event ExecutionCompleted(uint256 indexed taskId, address indexed executor, bool success);
    event ExecutorSlashed(address indexed executor, uint256 amount, string reason);

    // ============ Errors ============

    error AlreadyRegistered();
    error NotRegistered();
    error InsufficientStake();
    error ExecutorBlacklisted();
    error TaskLocked();
    error InvalidCommitment();
    error CommitmentNotReady();

    // ============ Functions ============

    /// @notice Register as an executor
    function registerExecutor() external payable;

    /// @notice Unregister and withdraw stake
    function unregisterExecutor() external;

    /// @notice Add more stake
    function addStake() external payable;

    /// @notice Withdraw stake (only when not active)
    function withdrawStake(uint256 amount) external;

    /// @notice Request execution lock (commit phase)
    function requestExecution(uint256 taskId, bytes32 commitment) external returns (bool locked);

    /// @notice Execute task (reveal phase)
    function executeTask(
        uint256 taskId,
        bytes32 reveal,
        bytes calldata conditionProof,
        bytes calldata actionsProof
    ) external returns (bool success);

    /// @notice Record execution result (called by TaskLogic)
    function recordExecution(uint256 taskId, address executor, bool success, uint256 gasUsed) external;

    /// @notice Slash executor for misbehavior
    function slashExecutor(address executor, uint256 amount, string calldata reason) external;

    /// @notice Check if executor can execute
    function canExecute(address executor) external view returns (bool);

    /// @notice Get executor info
    function getExecutor(address executor) external view returns (Executor memory);

    /// @notice Get execution lock
    function getExecutionLock(uint256 taskId) external view returns (ExecutionLock memory);

    /// @notice Check if task is locked
    function isTaskLocked(uint256 taskId) external view returns (bool);
}
