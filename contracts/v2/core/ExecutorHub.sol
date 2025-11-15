// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IExecutorHub.sol";
import "../interfaces/ITaskLogic.sol";

/**
 * @title ExecutorHub
 * @notice Manages executor registration, staking, and execution coordination
 * @dev Implements commit-reveal scheme to prevent front-running
 */
contract ExecutorHub is IExecutorHub, Ownable, ReentrancyGuard {

    // ============ State Variables ============

    mapping(address => Executor) public executors;
    mapping(uint256 => ExecutionLock) public taskLocks;

    address public taskLogic;
    address public taskRegistry;

    uint256 public minStakeAmount = 0.1 ether;
    uint256 public lockDuration = 30 seconds;
    uint256 public commitDelay = 1; // Blocks to wait after commit

    uint256 public totalExecutors;

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Modifiers ============

    modifier onlyRegistered() {
        if (!executors[msg.sender].isActive) revert NotRegistered();
        _;
    }

    modifier notBlacklisted() {
        if (executors[msg.sender].isSlashed) revert ExecutorBlacklisted();
        _;
    }

    modifier onlyTaskLogic() {
        require(msg.sender == taskLogic, "Only task logic");
        _;
    }

    // ============ Registration Functions ============

    /// @inheritdoc IExecutorHub
    function registerExecutor() external payable {
        if (executors[msg.sender].isActive) revert AlreadyRegistered();
        if (msg.value < minStakeAmount) revert InsufficientStake();

        executors[msg.sender] = Executor({
            addr: msg.sender,
            stakedAmount: uint128(msg.value),
            registeredAt: uint128(block.timestamp),
            totalExecutions: 0,
            successfulExecutions: 0,
            failedExecutions: 0,
            reputationScore: 5000, // Start at 50%
            isActive: true,
            isSlashed: false
        });

        totalExecutors++;

        emit ExecutorRegistered(msg.sender, msg.value);
    }

    /// @inheritdoc IExecutorHub
    function unregisterExecutor() external onlyRegistered nonReentrant {
        Executor storage executor = executors[msg.sender];

        uint256 stakeAmount = executor.stakedAmount;
        executor.isActive = false;
        executor.stakedAmount = 0;

        // Return stake
        (bool success, ) = msg.sender.call{value: stakeAmount}("");
        require(success, "Transfer failed");

        totalExecutors--;

        emit ExecutorUnregistered(msg.sender);
    }

    /// @inheritdoc IExecutorHub
    function addStake() external payable onlyRegistered {
        require(msg.value > 0, "Zero stake");

        Executor storage executor = executors[msg.sender];
        executor.stakedAmount += uint128(msg.value);

        emit StakeAdded(msg.sender, msg.value);
    }

    /// @inheritdoc IExecutorHub
    function withdrawStake(uint256 amount) external onlyRegistered nonReentrant {
        Executor storage executor = executors[msg.sender];

        require(amount > 0, "Zero amount");
        require(executor.stakedAmount >= amount, "Insufficient stake");

        uint256 remaining = executor.stakedAmount - amount;
        require(remaining >= minStakeAmount || remaining == 0, "Below minimum");

        executor.stakedAmount -= uint128(amount);

        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");

        emit StakeWithdrawn(msg.sender, amount);
    }

    // ============ Execution Functions ============

    /// @inheritdoc IExecutorHub
    function requestExecution(uint256 taskId, bytes32 commitment)
        external
        onlyRegistered
        notBlacklisted
        returns (bool locked)
    {
        ExecutionLock storage lock = taskLocks[taskId];

        // Check if already locked
        if (lock.executor != address(0)) {
            // Check if lock expired
            if (block.timestamp <= lock.lockedAt + lockDuration) {
                revert TaskLocked();
            }
        }

        // Lock task
        taskLocks[taskId] = ExecutionLock({
            executor: msg.sender,
            lockedAt: uint96(block.timestamp),
            commitment: commitment
        });

        emit ExecutionRequested(taskId, msg.sender, commitment);
        return true;
    }

    /// @inheritdoc IExecutorHub
    function executeTask(
        uint256 taskId,
        bytes32 reveal,
        bytes calldata conditionProof,
        bytes calldata actionsProof
    ) external onlyRegistered notBlacklisted nonReentrant returns (bool success) {
        ExecutionLock storage lock = taskLocks[taskId];

        // Verify executor holds lock
        if (lock.executor != msg.sender) revert InvalidCommitment();

        // Verify commitment delay passed
        if (lock.lockedAt + commitDelay > block.number) revert CommitmentNotReady();

        // Verify reveal matches commitment
        bytes32 commitment = keccak256(abi.encode(reveal));
        if (commitment != lock.commitment) revert InvalidCommitment();

        // Execute task via TaskLogic
        ITaskLogic.ExecutionParams memory params = ITaskLogic.ExecutionParams({
            taskId: taskId,
            executor: msg.sender,
            seed: reveal,
            conditionProof: conditionProof,
            actionsProof: actionsProof
        });

        ITaskLogic.ExecutionResult memory result = ITaskLogic(taskLogic).executeTask(params);

        // Update executor stats
        Executor storage executor = executors[msg.sender];
        executor.totalExecutions++;

        if (result.success) {
            executor.successfulExecutions++;
            _updateReputation(msg.sender, true);
        } else {
            executor.failedExecutions++;
            _updateReputation(msg.sender, false);
        }

        // Clear lock
        delete taskLocks[taskId];

        emit ExecutionCompleted(taskId, msg.sender, result.success);

        return result.success;
    }

    /// @inheritdoc IExecutorHub
    function recordExecution(uint256 taskId, address executor, bool success, uint256 gasUsed)
        external
        onlyTaskLogic
    {
        // Additional tracking can be done here
        // This is called by TaskLogic after execution
    }

    // ============ Admin Functions ============

    /// @inheritdoc IExecutorHub
    function slashExecutor(address executor, uint256 amount, string calldata reason)
        external
        onlyOwner
    {
        Executor storage exec = executors[executor];
        require(exec.isActive, "Not active");
        require(exec.stakedAmount >= amount, "Insufficient stake");

        exec.stakedAmount -= uint128(amount);
        exec.isSlashed = true;

        // Send slashed amount to owner (could go to insurance pool)
        (bool success, ) = owner().call{value: amount}("");
        require(success, "Transfer failed");

        emit ExecutorSlashed(executor, amount, reason);
    }

    function setMinStakeAmount(uint256 _minStake) external onlyOwner {
        require(_minStake > 0, "Invalid stake");
        minStakeAmount = _minStake;
    }

    function setLockDuration(uint256 _duration) external onlyOwner {
        require(_duration > 0 && _duration <= 5 minutes, "Invalid duration");
        lockDuration = _duration;
    }

    function setTaskLogic(address _taskLogic) external onlyOwner {
        require(_taskLogic != address(0), "Invalid logic");
        taskLogic = _taskLogic;
    }

    function setTaskRegistry(address _taskRegistry) external onlyOwner {
        require(_taskRegistry != address(0), "Invalid registry");
        taskRegistry = _taskRegistry;
    }

    // ============ View Functions ============

    /// @inheritdoc IExecutorHub
    function canExecute(address executor) external view returns (bool) {
        Executor storage exec = executors[executor];
        return exec.isActive && !exec.isSlashed && exec.stakedAmount >= minStakeAmount;
    }

    /// @inheritdoc IExecutorHub
    function getExecutor(address executor) external view returns (Executor memory) {
        return executors[executor];
    }

    /// @inheritdoc IExecutorHub
    function getExecutionLock(uint256 taskId) external view returns (ExecutionLock memory) {
        return taskLocks[taskId];
    }

    /// @inheritdoc IExecutorHub
    function isTaskLocked(uint256 taskId) external view returns (bool) {
        ExecutionLock storage lock = taskLocks[taskId];
        if (lock.executor == address(0)) return false;
        if (block.timestamp > lock.lockedAt + lockDuration) return false;
        return true;
    }

    // ============ Internal Functions ============

    function _updateReputation(address executor, bool success) internal {
        Executor storage exec = executors[executor];

        if (exec.totalExecutions == 0) return;

        // Calculate success rate (0-10000)
        uint256 successRate = (exec.successfulExecutions * 10000) / exec.totalExecutions;

        // Simple reputation: 70% success rate + 30% volume bonus
        uint256 volumeBonus = _calculateVolumeBonus(exec.totalExecutions);
        exec.reputationScore = (successRate * 70 + volumeBonus * 30) / 100;
    }

    function _calculateVolumeBonus(uint256 totalTasks) internal pure returns (uint256) {
        if (totalTasks >= 2000) return 10000;
        if (totalTasks >= 500) return 7500;
        if (totalTasks >= 100) return 5000;
        if (totalTasks >= 10) return 2500;
        return 1000;
    }
}
