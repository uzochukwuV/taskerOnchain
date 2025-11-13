// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title TaskChecker
 * @notice Helper contract for checking task execution readiness
 * @dev Provides view functions for executor bots to discover executable tasks
 */
contract TaskChecker {

    // ============ Interfaces ============

    interface IDynamicTaskRegistry {
        struct Task {
            uint256 id;
            address creator;
            uint256 reward;
            uint256 createdAt;
            uint256 expiresAt;
            uint8 status; // TaskStatus enum
            uint256 executionCount;
            uint256 maxExecutions;
            uint256 lastExecutionTime;
            uint256 recurringInterval;
        }

        function tasks(uint256 _taskId) external view returns (Task memory);
        function nextTaskId() external view returns (uint256);
        function isTaskExecutable(uint256 _taskId) external view returns (bool);
    }

    interface IConditionChecker {
        function checkCondition(
            uint8 _conditionType,
            bytes calldata _conditionData
        ) external view returns (bool);
    }

    interface IExecutorManager {
        function canExecute(address _executor) external view returns (bool);
        function isTaskLocked(uint256 _taskId) external view returns (bool, address);
    }

    // ============ State Variables ============

    address public taskRegistry;
    address public conditionChecker;
    address public executorManager;

    // ============ Constructor ============

    constructor(
        address _taskRegistry,
        address _conditionChecker,
        address _executorManager
    ) {
        taskRegistry = _taskRegistry;
        conditionChecker = _conditionChecker;
        executorManager = _executorManager;
    }

    // ============ Core View Functions ============

    /**
     * @notice Get all executable tasks for an executor
     * @param _executor Executor address
     * @param _maxResults Maximum number of results to return
     * @return taskIds Array of executable task IDs
     * @return rewards Array of rewards for each task
     * @return priorities Array of priority scores (higher = better)
     */
    function getExecutableTasksForExecutor(
        address _executor,
        uint256 _maxResults
    ) external view returns (
        uint256[] memory taskIds,
        uint256[] memory rewards,
        uint256[] memory priorities
    ) {
        IDynamicTaskRegistry registry = IDynamicTaskRegistry(taskRegistry);
        IExecutorManager manager = IExecutorManager(executorManager);

        // Check if executor can execute
        if (!manager.canExecute(_executor)) {
            return (new uint256[](0), new uint256[](0), new uint256[](0));
        }

        uint256 totalTasks = registry.nextTaskId();
        uint256[] memory tempIds = new uint256[](_maxResults);
        uint256[] memory tempRewards = new uint256[](_maxResults);
        uint256[] memory tempPriorities = new uint256[](_maxResults);
        uint256 count = 0;

        for (uint256 i = 0; i < totalTasks && count < _maxResults; i++) {
            if (_isTaskReadyForExecution(i, registry, manager)) {
                IDynamicTaskRegistry.Task memory task = registry.tasks(i);

                tempIds[count] = i;
                tempRewards[count] = task.reward;
                tempPriorities[count] = _calculateTaskPriority(task);
                count++;
            }
        }

        // Trim arrays to actual size
        taskIds = new uint256[](count);
        rewards = new uint256[](count);
        priorities = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            taskIds[i] = tempIds[i];
            rewards[i] = tempRewards[i];
            priorities[i] = tempPriorities[i];
        }
    }

    /**
     * @notice Get top priority executable tasks
     * @param _executor Executor address
     * @param _limit Number of tasks to return
     * @return taskIds Array of task IDs sorted by priority (highest first)
     * @return rewards Array of rewards
     * @return priorities Array of priority scores
     */
    function getTopPriorityTasks(
        address _executor,
        uint256 _limit
    ) external view returns (
        uint256[] memory taskIds,
        uint256[] memory rewards,
        uint256[] memory priorities
    ) {
        (taskIds, rewards, priorities) = this.getExecutableTasksForExecutor(_executor, _limit * 3);

        // Simple bubble sort by priority (descending)
        for (uint256 i = 0; i < taskIds.length; i++) {
            for (uint256 j = i + 1; j < taskIds.length; j++) {
                if (priorities[j] > priorities[i]) {
                    // Swap priorities
                    (priorities[i], priorities[j]) = (priorities[j], priorities[i]);
                    // Swap taskIds
                    (taskIds[i], taskIds[j]) = (taskIds[j], taskIds[i]);
                    // Swap rewards
                    (rewards[i], rewards[j]) = (rewards[j], rewards[i]);
                }
            }
        }

        // Trim to limit
        if (taskIds.length > _limit) {
            uint256[] memory limitedIds = new uint256[](_limit);
            uint256[] memory limitedRewards = new uint256[](_limit);
            uint256[] memory limitedPriorities = new uint256[](_limit);

            for (uint256 i = 0; i < _limit; i++) {
                limitedIds[i] = taskIds[i];
                limitedRewards[i] = rewards[i];
                limitedPriorities[i] = priorities[i];
            }

            return (limitedIds, limitedRewards, limitedPriorities);
        }

        return (taskIds, rewards, priorities);
    }

    /**
     * @notice Check if a specific task is ready for execution
     * @param _taskId Task ID to check
     * @param _executor Executor address
     * @return isReady Whether task can be executed now
     * @return reason Reason if not ready (empty if ready)
     */
    function isTaskReady(
        uint256 _taskId,
        address _executor
    ) external view returns (bool isReady, string memory reason) {
        IDynamicTaskRegistry registry = IDynamicTaskRegistry(taskRegistry);
        IExecutorManager manager = IExecutorManager(executorManager);

        // Check executor eligibility
        if (!manager.canExecute(_executor)) {
            return (false, "Executor not eligible");
        }

        // Check if task is locked
        (bool isLocked, address lockedBy) = manager.isTaskLocked(_taskId);
        if (isLocked && lockedBy != _executor) {
            return (false, "Task locked by another executor");
        }

        // Check basic executability
        if (!registry.isTaskExecutable(_taskId)) {
            return (false, "Task not executable");
        }

        return (true, "");
    }

    /**
     * @notice Batch check multiple tasks
     * @param _taskIds Array of task IDs
     * @param _executor Executor address
     * @return readyStates Array of ready states
     */
    function batchCheckTasks(
        uint256[] calldata _taskIds,
        address _executor
    ) external view returns (bool[] memory readyStates) {
        readyStates = new bool[](_taskIds.length);

        for (uint256 i = 0; i < _taskIds.length; i++) {
            (bool isReady, ) = this.isTaskReady(_taskIds[i], _executor);
            readyStates[i] = isReady;
        }
    }

    /**
     * @notice Get task statistics for monitoring
     * @return totalTasks Total number of tasks
     * @return activeTasks Number of active tasks
     * @return executableTasks Number of executable tasks
     */
    function getTaskStatistics() external view returns (
        uint256 totalTasks,
        uint256 activeTasks,
        uint256 executableTasks
    ) {
        IDynamicTaskRegistry registry = IDynamicTaskRegistry(taskRegistry);
        IExecutorManager manager = IExecutorManager(executorManager);

        totalTasks = registry.nextTaskId();

        for (uint256 i = 0; i < totalTasks; i++) {
            IDynamicTaskRegistry.Task memory task = registry.tasks(i);

            if (task.status == 0) { // ACTIVE status
                activeTasks++;

                if (_isTaskReadyForExecution(i, registry, manager)) {
                    executableTasks++;
                }
            }
        }
    }

    /**
     * @notice Get tasks by reward range
     * @param _minReward Minimum reward
     * @param _maxReward Maximum reward
     * @param _limit Maximum results
     * @return taskIds Array of task IDs
     */
    function getTasksByRewardRange(
        uint256 _minReward,
        uint256 _maxReward,
        uint256 _limit
    ) external view returns (uint256[] memory taskIds) {
        IDynamicTaskRegistry registry = IDynamicTaskRegistry(taskRegistry);
        IExecutorManager manager = IExecutorManager(executorManager);

        uint256 totalTasks = registry.nextTaskId();
        uint256[] memory tempIds = new uint256[](_limit);
        uint256 count = 0;

        for (uint256 i = 0; i < totalTasks && count < _limit; i++) {
            IDynamicTaskRegistry.Task memory task = registry.tasks(i);

            if (
                _isTaskReadyForExecution(i, registry, manager) &&
                task.reward >= _minReward &&
                task.reward <= _maxReward
            ) {
                tempIds[count] = i;
                count++;
            }
        }

        taskIds = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            taskIds[i] = tempIds[i];
        }
    }

    // ============ Internal Helpers ============

    /**
     * @notice Check if task is ready for execution
     * @param _taskId Task ID
     * @param _registry Task registry interface
     * @param _manager Executor manager interface
     * @return bool Whether task is ready
     */
    function _isTaskReadyForExecution(
        uint256 _taskId,
        IDynamicTaskRegistry _registry,
        IExecutorManager _manager
    ) internal view returns (bool) {
        // Check if task is locked
        (bool isLocked, ) = _manager.isTaskLocked(_taskId);
        if (isLocked) {
            return false;
        }

        // Check basic executability
        return _registry.isTaskExecutable(_taskId);
    }

    /**
     * @notice Calculate priority score for a task
     * @param _task Task data
     * @return priority Priority score (higher = better)
     */
    function _calculateTaskPriority(
        IDynamicTaskRegistry.Task memory _task
    ) internal view returns (uint256 priority) {
        // Base priority on reward
        priority = _task.reward / 1e15; // Convert to manageable number

        // Boost one-time tasks
        if (_task.maxExecutions == 1) {
            priority += 100;
        }

        // Boost expiring tasks
        if (_task.expiresAt > 0) {
            uint256 timeLeft = _task.expiresAt > block.timestamp
                ? _task.expiresAt - block.timestamp
                : 0;

            // Higher priority if expiring soon
            if (timeLeft < 1 hours) {
                priority += 500;
            } else if (timeLeft < 24 hours) {
                priority += 200;
            }
        }

        // Boost older tasks
        uint256 age = block.timestamp - _task.createdAt;
        if (age > 7 days) {
            priority += 150;
        } else if (age > 1 days) {
            priority += 50;
        }
    }

    // ============ Admin Functions ============

    /**
     * @notice Update task registry address
     * @param _taskRegistry New task registry
     */
    function setTaskRegistry(address _taskRegistry) external {
        require(_taskRegistry != address(0), "Invalid address");
        taskRegistry = _taskRegistry;
    }

    /**
     * @notice Update condition checker address
     * @param _conditionChecker New condition checker
     */
    function setConditionChecker(address _conditionChecker) external {
        require(_conditionChecker != address(0), "Invalid address");
        conditionChecker = _conditionChecker;
    }

    /**
     * @notice Update executor manager address
     * @param _executorManager New executor manager
     */
    function setExecutorManager(address _executorManager) external {
        require(_executorManager != address(0), "Invalid address");
        executorManager = _executorManager;
    }
}
