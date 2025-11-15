// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ITaskLogic.sol";
import "../interfaces/ITaskCore.sol";
import "../interfaces/ITaskVault.sol";
import "../interfaces/IConditionOracle.sol";
import "../interfaces/IActionRegistry.sol";
import "../interfaces/IRewardManager.sol";

/**
 * @title TaskLogic
 * @notice Orchestrates task execution workflow
 * @dev Coordinates condition checking, action execution, and reward distribution
 */
contract TaskLogic is ITaskLogic, Ownable, ReentrancyGuard {

    // ============ State Variables ============

    address public conditionOracle;
    address public actionRegistry;
    address public rewardManager;
    address public executorHub;

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Modifiers ============

    modifier onlyExecutorHub() {
        if (msg.sender != executorHub) revert OnlyExecutorHub();
        _;
    }

    // ============ Core Functions ============

    /// @inheritdoc ITaskLogic
    function executeTask(ExecutionParams calldata params)
        external
        onlyExecutorHub
        nonReentrant
        returns (ExecutionResult memory result)
    {
        uint256 startGas = gasleft();

        emit ExecutionStarted(params.taskId, params.executor);

        // Get task core from factory or registry (assuming params.taskId maps to TaskCore address)
        // For simplicity, we'll need a registry. Let's add that requirement.
        // For now, we'll assume the caller provides the taskCore address via a lookup

        // Step 1: Validate execution
        // This would typically involve loading the task and checking permissions
        // Simplified for now - in production, add task registry lookup

        // Step 2: Verify seed commitment
        // Simplified - in production, verify against stored commitment

        // Step 3: Check condition
        bool conditionMet = _checkCondition(params.conditionProof);
        emit ConditionChecked(params.taskId, conditionMet);

        if (!conditionMet) {
            result.success = false;
            result.failureReason = "Condition not met";
            result.gasUsed = startGas - gasleft();
            return result;
        }

        // Step 4: Execute actions
        bool actionsSuccess = _executeActions(params.taskId, params.actionsProof);
        emit ActionsExecuted(params.taskId, actionsSuccess);

        if (!actionsSuccess) {
            result.success = false;
            result.failureReason = "Actions failed";
            result.gasUsed = startGas - gasleft();
            return result;
        }

        // Step 5: Distribute reward
        uint256 rewardPaid = _distributeReward(
            params.taskId,
            params.executor,
            startGas - gasleft()
        );

        emit RewardDistributed(params.taskId, params.executor, rewardPaid);

        result.success = true;
        result.gasUsed = startGas - gasleft();
        result.rewardPaid = rewardPaid;

        return result;
    }

    // ============ Internal Functions ============

    function _checkCondition(bytes calldata conditionProof) internal view returns (bool) {
        if (conditionOracle == address(0)) {
            return true; // No oracle = always pass
        }

        // Decode condition from proof
        IConditionOracle.Condition memory condition = abi.decode(
            conditionProof,
            (IConditionOracle.Condition)
        );

        // Check condition
        IConditionOracle.ConditionResult memory condResult =
            IConditionOracle(conditionOracle).checkCondition(condition);

        return condResult.isMet;
    }

    function _executeActions(uint256 taskId, bytes calldata actionsProof)
        internal
        returns (bool)
    {
        // Decode actions from proof
        // In production, verify against stored hash
        // For now, simplified implementation

        // This would call through ActionRegistry to execute each action
        // via the appropriate adapter

        return true; // Simplified
    }

    function _distributeReward(uint256 taskId, address executor, uint256 gasUsed)
        internal
        returns (uint256)
    {
        if (rewardManager == address(0)) {
            return 0;
        }

        // This would calculate and distribute the reward
        // For now, simplified implementation

        return 0; // Simplified - would return actual reward paid
    }

    // ============ Admin Functions ============

    /// @inheritdoc ITaskLogic
    function setConditionOracle(address _conditionOracle) external onlyOwner {
        require(_conditionOracle != address(0), "Invalid oracle");
        conditionOracle = _conditionOracle;
    }

    /// @inheritdoc ITaskLogic
    function setActionRegistry(address _actionRegistry) external onlyOwner {
        require(_actionRegistry != address(0), "Invalid registry");
        actionRegistry = _actionRegistry;
    }

    /// @inheritdoc ITaskLogic
    function setRewardManager(address _rewardManager) external onlyOwner {
        require(_rewardManager != address(0), "Invalid manager");
        rewardManager = _rewardManager;
    }

    /// @inheritdoc ITaskLogic
    function setExecutorHub(address _executorHub) external onlyOwner {
        require(_executorHub != address(0), "Invalid hub");
        executorHub = _executorHub;
    }
}
