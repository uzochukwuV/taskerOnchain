// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITaskLogic
 * @notice Interface for TaskLogic contract that orchestrates task execution
 */
interface ITaskLogic {

    // ============ Structs ============

    struct ExecutionParams {
        uint256 taskId;
        address executor;
        bytes32 seed;
        bytes conditionProof;
        bytes actionsProof;
    }

    struct ExecutionResult {
        bool success;
        uint256 gasUsed;
        uint256 rewardPaid;
        string failureReason;
    }

    // ============ Events ============

    event ExecutionStarted(uint256 indexed taskId, address indexed executor);
    event ConditionChecked(uint256 indexed taskId, bool conditionMet);
    event ActionsExecuted(uint256 indexed taskId, bool success);
    event RewardDistributed(uint256 indexed taskId, address indexed executor, uint256 amount);

    // ============ Errors ============

    error OnlyExecutorHub();
    error TaskNotExecutable();
    error InvalidSeed();
    error ConditionNotMet();
    error ActionsFailed();

    // ============ Functions ============

    /// @notice Execute a task (called by ExecutorHub)
    function executeTask(ExecutionParams calldata params)
        external
        returns (ExecutionResult memory result);

    /// @notice Set ConditionOracle address
    function setConditionOracle(address _conditionOracle) external;

    /// @notice Set ActionRegistry address
    function setActionRegistry(address _actionRegistry) external;

    /// @notice Set RewardManager address
    function setRewardManager(address _rewardManager) external;

    /// @notice Set ExecutorHub address
    function setExecutorHub(address _executorHub) external;

    /// @notice Get ConditionOracle address
    function conditionOracle() external view returns (address);

    /// @notice Get ActionRegistry address
    function actionRegistry() external view returns (address);

    /// @notice Get RewardManager address
    function rewardManager() external view returns (address);

    /// @notice Get ExecutorHub address
    function executorHub() external view returns (address);
}
