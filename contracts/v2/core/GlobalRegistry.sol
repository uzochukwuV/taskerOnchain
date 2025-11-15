// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/ITaskCore.sol";

/**
 * @title GlobalRegistry
 * @notice Central registry for all tasks in the system
 * @dev Provides efficient querying and indexing of tasks
 */
contract GlobalRegistry is Ownable {

    // ============ Structs ============

    struct TaskInfo {
        uint256 taskId;
        address taskCore;
        address taskVault;
        address creator;
        uint256 createdAt;
        uint256 expiresAt;
        ITaskCore.TaskStatus status;
    }

    // ============ State Variables ============

    // Authorized factories that can register tasks
    mapping(address => bool) public authorizedFactories;

    // Task storage
    mapping(uint256 => TaskInfo) public tasks;
    uint256 public totalTasks;

    // Indexing
    mapping(address => uint256[]) public tasksByCreator;
    mapping(ITaskCore.TaskStatus => uint256[]) public tasksByStatus;

    // Pagination helpers
    uint256[] public allTaskIds;

    // ============ Events ============

    event TaskRegistered(
        uint256 indexed taskId,
        address indexed creator,
        address taskCore,
        address taskVault
    );

    event TaskStatusUpdated(
        uint256 indexed taskId,
        ITaskCore.TaskStatus oldStatus,
        ITaskCore.TaskStatus newStatus
    );

    event FactoryAuthorized(address indexed factory);
    event FactoryRevoked(address indexed factory);

    // ============ Modifiers ============

    modifier onlyAuthorizedFactory() {
        require(authorizedFactories[msg.sender], "Not authorized");
        _;
    }

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Core Functions ============

    /**
     * @notice Register a new task (called by TaskFactory)
     * @param taskId Unique task identifier
     * @param taskCore Address of TaskCore
     * @param taskVault Address of TaskVault
     * @param creator Address of task creator
     */
    function registerTask(
        uint256 taskId,
        address taskCore,
        address taskVault,
        address creator
    ) external onlyAuthorizedFactory {
        require(tasks[taskId].taskCore == address(0), "Task already exists");

        ITaskCore.TaskMetadata memory metadata = ITaskCore(taskCore).getMetadata();

        TaskInfo memory info = TaskInfo({
            taskId: taskId,
            taskCore: taskCore,
            taskVault: taskVault,
            creator: creator,
            createdAt: metadata.createdAt,
            expiresAt: metadata.expiresAt,
            status: metadata.status
        });

        tasks[taskId] = info;
        allTaskIds.push(taskId);
        tasksByCreator[creator].push(taskId);
        tasksByStatus[metadata.status].push(taskId);

        totalTasks++;

        emit TaskRegistered(taskId, creator, taskCore, taskVault);
    }

    /**
     * @notice Update task status
     * @param taskId Task identifier
     * @param newStatus New status
     */
    function updateTaskStatus(uint256 taskId, ITaskCore.TaskStatus newStatus) external {
        TaskInfo storage info = tasks[taskId];
        require(info.taskCore != address(0), "Task not found");

        // Only TaskCore can update status
        require(msg.sender == info.taskCore, "Only TaskCore");

        ITaskCore.TaskStatus oldStatus = info.status;
        info.status = newStatus;

        emit TaskStatusUpdated(taskId, oldStatus, newStatus);
    }

    // ============ Query Functions ============

    /**
     * @notice Get task addresses
     * @param taskId Task identifier
     * @return taskCore Address of TaskCore
     * @return taskVault Address of TaskVault
     */
    function getTaskAddresses(uint256 taskId)
        external
        view
        returns (address taskCore, address taskVault)
    {
        TaskInfo storage info = tasks[taskId];
        return (info.taskCore, info.taskVault);
    }

    /**
     * @notice Get task info
     * @param taskId Task identifier
     * @return TaskInfo struct
     */
    function getTaskInfo(uint256 taskId) external view returns (TaskInfo memory) {
        return tasks[taskId];
    }

    /**
     * @notice Get all tasks by creator
     * @param creator Creator address
     * @return uint256[] Array of task IDs
     */
    function getTasksByCreator(address creator) external view returns (uint256[] memory) {
        return tasksByCreator[creator];
    }

    /**
     * @notice Get tasks by status
     * @param status Task status
     * @return uint256[] Array of task IDs
     */
    function getTasksByStatus(ITaskCore.TaskStatus status)
        external
        view
        returns (uint256[] memory)
    {
        return tasksByStatus[status];
    }

    /**
     * @notice Get executable tasks (ACTIVE and not expired)
     * @param limit Maximum number of tasks to return
     * @param offset Starting index
     * @return TaskInfo[] Array of executable tasks
     */
    function getExecutableTasks(uint256 limit, uint256 offset)
        external
        view
        returns (TaskInfo[] memory)
    {
        uint256 count = 0;
        TaskInfo[] memory result = new TaskInfo[](limit);

        uint256[] memory activeTasks = tasksByStatus[ITaskCore.TaskStatus.ACTIVE];

        for (uint256 i = offset; i < activeTasks.length && count < limit; i++) {
            TaskInfo storage info = tasks[activeTasks[i]];

            // Check if executable
            if (info.expiresAt == 0 || block.timestamp <= info.expiresAt) {
                // Check with TaskCore if truly executable
                if (ITaskCore(info.taskCore).isExecutable()) {
                    result[count] = info;
                    count++;
                }
            }
        }

        // Resize array
        assembly {
            mstore(result, count)
        }

        return result;
    }

    /**
     * @notice Get paginated task list
     * @param limit Number of tasks to return
     * @param offset Starting index
     * @return TaskInfo[] Array of tasks
     * @return uint256 Total number of tasks
     */
    function getPaginatedTasks(uint256 limit, uint256 offset)
        external
        view
        returns (TaskInfo[] memory, uint256)
    {
        require(offset < allTaskIds.length, "Invalid offset");

        uint256 end = offset + limit;
        if (end > allTaskIds.length) {
            end = allTaskIds.length;
        }

        uint256 count = end - offset;
        TaskInfo[] memory result = new TaskInfo[](count);

        for (uint256 i = 0; i < count; i++) {
            result[i] = tasks[allTaskIds[offset + i]];
        }

        return (result, allTaskIds.length);
    }

    /**
     * @notice Search tasks by multiple criteria
     * @param creator Filter by creator (address(0) = no filter)
     * @param status Filter by status
     * @param minReward Minimum reward per execution
     * @param limit Max results
     * @return TaskInfo[] Matching tasks
     */
    function searchTasks(
        address creator,
        ITaskCore.TaskStatus status,
        uint256 minReward,
        uint256 limit
    ) external view returns (TaskInfo[] memory) {
        uint256 count = 0;
        TaskInfo[] memory result = new TaskInfo[](limit);

        uint256[] memory candidateTasks;

        if (creator != address(0)) {
            candidateTasks = tasksByCreator[creator];
        } else {
            candidateTasks = allTaskIds;
        }

        for (uint256 i = 0; i < candidateTasks.length && count < limit; i++) {
            TaskInfo storage info = tasks[candidateTasks[i]];

            // Apply filters
            if (info.status != status && status != ITaskCore.TaskStatus.ACTIVE) {
                continue; // Skip if status doesn't match (unless querying ACTIVE)
            }

            ITaskCore.TaskMetadata memory metadata = ITaskCore(info.taskCore).getMetadata();

            if (metadata.rewardPerExecution < minReward) {
                continue;
            }

            result[count] = info;
            count++;
        }

        // Resize
        assembly {
            mstore(result, count)
        }

        return result;
    }

    // ============ Admin Functions ============

    /**
     * @notice Authorize a factory to register tasks
     * @param factory Factory address
     */
    function authorizeFactory(address factory) external onlyOwner {
        require(factory != address(0), "Invalid factory");
        authorizedFactories[factory] = true;
        emit FactoryAuthorized(factory);
    }

    /**
     * @notice Revoke factory authorization
     * @param factory Factory address
     */
    function revokeFactory(address factory) external onlyOwner {
        authorizedFactories[factory] = false;
        emit FactoryRevoked(factory);
    }

    /**
     * @notice Batch authorize factories
     * @param factories Array of factory addresses
     */
    function batchAuthorizeFactories(address[] calldata factories) external onlyOwner {
        for (uint256 i = 0; i < factories.length; i++) {
            authorizedFactories[factories[i]] = true;
            emit FactoryAuthorized(factories[i]);
        }
    }
}
