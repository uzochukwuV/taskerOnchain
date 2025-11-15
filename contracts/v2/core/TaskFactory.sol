// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/ITaskFactory.sol";
import "../interfaces/ITaskCore.sol";
import "../interfaces/ITaskVault.sol";

/**
 * @title TaskFactory
 * @notice Deploys new task instances using minimal proxies (EIP-1167)
 * @dev Each task gets its own TaskCore and TaskVault clone
 */
contract TaskFactory is ITaskFactory, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Clones for address;

    // ============ State Variables ============

    // Implementation contracts for cloning
    address public immutable taskCoreImplementation;
    address public immutable taskVaultImplementation;

    // System contracts
    address public immutable taskLogic;
    address public immutable executorHub;
    address public immutable conditionOracle;
    address public immutable actionRegistry;
    address public immutable rewardManager;
    address public globalRegistry;

    // Configuration
    uint256 public minTaskReward = 0.001 ether;
    uint256 public maxTaskDuration = 365 days;
    uint256 public creationFee = 0;

    // Task tracking
    uint256 public override nextTaskId;
    mapping(uint256 => DeployedTask) private tasks;

    // ============ Constructor ============

    constructor(
        address _taskCoreImpl,
        address _taskVaultImpl,
        address _taskLogic,
        address _executorHub,
        address _conditionOracle,
        address _actionRegistry,
        address _rewardManager,
        address _owner
    ) Ownable(_owner) {
        require(_taskCoreImpl != address(0), "Invalid core impl");
        require(_taskVaultImpl != address(0), "Invalid vault impl");
        require(_taskLogic != address(0), "Invalid logic");
        require(_executorHub != address(0), "Invalid hub");
        require(_conditionOracle != address(0), "Invalid oracle");
        require(_actionRegistry != address(0), "Invalid registry");
        require(_rewardManager != address(0), "Invalid reward manager");

        taskCoreImplementation = _taskCoreImpl;
        taskVaultImplementation = _taskVaultImpl;
        taskLogic = _taskLogic;
        executorHub = _executorHub;
        conditionOracle = _conditionOracle;
        actionRegistry = _actionRegistry;
        rewardManager = _rewardManager;
    }

    // ============ Core Functions ============

    /// @inheritdoc ITaskFactory
    function createTask(
        TaskParams calldata params,
        ConditionParams calldata condition,
        ActionParams[] calldata actions
    ) external payable nonReentrant returns (uint256 taskId, address taskCore, address taskVault) {
        return _createTask(params, condition, actions, new TokenDeposit[](0));
    }

    /// @inheritdoc ITaskFactory
    function createTaskWithTokens(
        TaskParams calldata params,
        ConditionParams calldata condition,
        ActionParams[] calldata actions,
        TokenDeposit[] calldata deposits
    ) external payable nonReentrant returns (uint256 taskId, address taskCore, address taskVault) {
        return _createTask(params, condition, actions, deposits);
    }

    // ============ Internal Functions ============

    function _createTask(
        TaskParams calldata params,
        ConditionParams calldata condition,
        ActionParams[] calldata actions,
        TokenDeposit[] calldata deposits
    ) internal returns (uint256 taskId, address taskCore, address taskVault) {
        // Validate parameters
        _validateTaskParams(params, actions);

        // Collect creation fee
        if (creationFee > 0) {
            require(msg.value >= creationFee, "Insufficient creation fee");
        }

        // Generate task ID
        taskId = nextTaskId++;

        // Deploy TaskCore clone
        taskCore = taskCoreImplementation.clone();

        // Deploy TaskVault clone
        taskVault = taskVaultImplementation.clone();

        // Calculate funding requirements
        uint256 totalReward = params.maxExecutions == 0
            ? params.rewardPerExecution
            : params.rewardPerExecution * params.maxExecutions;

        uint256 providedValue = msg.value - creationFee;
        require(providedValue >= totalReward, "Insufficient reward funding");

        // Hash condition and actions for verification
        bytes32 conditionHash = _hashCondition(condition);
        bytes32 actionsHash = _hashActions(actions);

        // Create metadata
        ITaskCore.TaskMetadata memory metadata = ITaskCore.TaskMetadata({
            id: taskId,
            creator: msg.sender,
            createdAt: uint96(block.timestamp),
            expiresAt: params.expiresAt,
            maxExecutions: params.maxExecutions,
            executionCount: 0,
            lastExecutionTime: 0,
            recurringInterval: params.recurringInterval,
            rewardPerExecution: params.rewardPerExecution,
            status: ITaskCore.TaskStatus.ACTIVE,
            conditionHash: conditionHash,
            actionsHash: actionsHash,
            seedCommitment: params.seedCommitment
        });

        // Initialize TaskCore
        ITaskCore(taskCore).initialize(
            taskId,
            msg.sender,
            taskVault,
            taskLogic,
            metadata
        );

        // Initialize TaskVault
        ITaskVault(taskVault).initialize(taskCore, msg.sender, rewardManager);

        // Fund vault with native tokens
        if (totalReward > 0) {
            ITaskVault(taskVault).depositNative{value: totalReward}();
        }

        // Deposit ERC20 tokens if provided
        for (uint256 i = 0; i < deposits.length; i++) {
            IERC20(deposits[i].token).safeTransferFrom(
                msg.sender,
                address(this),
                deposits[i].amount
            );

            // Approve vault to pull tokens
            IERC20(deposits[i].token).safeApprove(taskVault, deposits[i].amount);

            // Deposit into vault
            ITaskVault(taskVault).depositToken(deposits[i].token, deposits[i].amount);

            // Clear approval
            IERC20(deposits[i].token).safeApprove(taskVault, 0);
        }

        // Store task info
        tasks[taskId] = DeployedTask({
            taskId: taskId,
            taskCore: taskCore,
            taskVault: taskVault,
            creator: msg.sender
        });

        emit TaskCreated(
            taskId,
            msg.sender,
            taskCore,
            taskVault,
            params.rewardPerExecution,
            params.maxExecutions
        );

        // Register task with GlobalRegistry
        if (globalRegistry != address(0)) {
            (bool success, ) = globalRegistry.call(
                abi.encodeWithSignature(
                    "registerTask(uint256,address,address,address)",
                    taskId,
                    taskCore,
                    taskVault,
                    msg.sender
                )
            );
            require(success, "Registry registration failed");
        }

        return (taskId, taskCore, taskVault);
    }

    function _validateTaskParams(TaskParams calldata params, ActionParams[] calldata actions)
        internal
        view
    {
        if (params.rewardPerExecution < minTaskReward) revert InvalidReward();

        if (params.expiresAt != 0) {
            if (params.expiresAt <= block.timestamp) revert InvalidExpiration();
            if (params.expiresAt > block.timestamp + maxTaskDuration) revert InvalidExpiration();
        }

        if (actions.length == 0 || actions.length > 10) revert InvalidActions();
    }

    function _hashCondition(ConditionParams calldata condition) internal pure returns (bytes32) {
        return keccak256(abi.encode(condition.conditionType, condition.conditionData));
    }

    function _hashActions(ActionParams[] calldata actions) internal pure returns (bytes32) {
        return keccak256(abi.encode(actions));
    }

    // ============ View Functions ============

    /// @inheritdoc ITaskFactory
    function getTaskAddresses(uint256 taskId)
        external
        view
        returns (address taskCore, address taskVault)
    {
        DeployedTask storage task = tasks[taskId];
        return (task.taskCore, task.taskVault);
    }

    /// @inheritdoc ITaskFactory
    function getTask(uint256 taskId) external view returns (DeployedTask memory) {
        return tasks[taskId];
    }

    // ============ Admin Functions ============

    function setMinTaskReward(uint256 _minReward) external onlyOwner {
        uint256 oldMin = minTaskReward;
        minTaskReward = _minReward;
        emit MinTaskRewardUpdated(oldMin, _minReward);
    }

    function setCreationFee(uint256 _fee) external onlyOwner {
        uint256 oldFee = creationFee;
        creationFee = _fee;
        emit CreationFeeUpdated(oldFee, _fee);
    }

    function setMaxTaskDuration(uint256 _duration) external onlyOwner {
        require(_duration > 0, "Invalid duration");
        maxTaskDuration = _duration;
    }

    function withdrawFees(address recipient) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        uint256 balance = address(this).balance;
        (bool success, ) = recipient.call{value: balance}("");
        require(success, "Transfer failed");
    }

    function setGlobalRegistry(address _globalRegistry) external onlyOwner {
        require(_globalRegistry != address(0), "Invalid registry");
        globalRegistry = _globalRegistry;
    }

    // ============ Receive Function ============

    receive() external payable {}
}
