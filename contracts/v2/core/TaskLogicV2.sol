// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "../interfaces/ITaskLogic.sol";
import "../interfaces/ITaskCore.sol";
import "../interfaces/ITaskVault.sol";
import "../interfaces/IConditionOracle.sol";
import "../interfaces/IActionRegistry.sol";
import "../interfaces/IRewardManager.sol";
import "../interfaces/IActionAdapter.sol";
import "../libraries/MerkleProof.sol";

/**
 * @title TaskLogicV2
 * @notice Orchestrates task execution workflow with Merkle proof verification
 * @dev Coordinates condition checking, action execution, and reward distribution
 */
contract TaskLogicV2 is ITaskLogic, Ownable, ReentrancyGuard, Pausable {
    using MerkleProof for bytes32[];

    // ============ State Variables ============

    address public conditionOracle;
    address public actionRegistry;
    address public rewardManager;
    address public executorHub;
    address public taskRegistry; // GlobalRegistry

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
        whenNotPaused
        nonReentrant
        returns (ExecutionResult memory result)
    {
        uint256 startGas = gasleft();

        emit ExecutionStarted(params.taskId, params.executor);

        // Step 1: Load task and validate
        (address taskCore, address taskVault) = _loadTask(params.taskId);

        ITaskCore.TaskMetadata memory metadata = ITaskCore(taskCore).getMetadata();

        // Step 2: Verify seed commitment
        if (metadata.seedCommitment != bytes32(0)) {
            bytes32 providedCommitment = keccak256(abi.encode(params.seed));
            if (providedCommitment != metadata.seedCommitment) {
                revert InvalidSeed();
            }
        }

        // Step 3: Mark task as executing
        bool canExecute = ITaskCore(taskCore).executeTask(params.executor);
        if (!canExecute) revert TaskNotExecutable();

        // Step 4: Verify and check condition
        bool conditionMet = _verifyAndCheckCondition(
            metadata.conditionHash,
            params.conditionProof
        );

        emit ConditionChecked(params.taskId, conditionMet);

        if (!conditionMet) {
            // Mark execution as failed
            ITaskCore(taskCore).completeExecution(false);

            result.success = false;
            result.failureReason = "Condition not met";
            result.gasUsed = startGas - gasleft();
            return result;
        }

        // Step 5: Verify and execute actions
        bool actionsSuccess = _verifyAndExecuteActions(
            taskVault,
            metadata.actionsHash,
            params.actionsProof
        );

        emit ActionsExecuted(params.taskId, actionsSuccess);

        if (!actionsSuccess) {
            // Mark execution as failed
            ITaskCore(taskCore).completeExecution(false);

            result.success = false;
            result.failureReason = "Actions failed";
            result.gasUsed = startGas - gasleft();
            return result;
        }

        // Step 6: Distribute reward
        uint256 gasUsed = startGas - gasleft();
        uint256 rewardPaid = _distributeReward(
            taskVault,
            params.executor,
            metadata.rewardPerExecution,
            gasUsed
        );

        emit RewardDistributed(params.taskId, params.executor, rewardPaid);

        // Step 7: Mark execution as complete
        ITaskCore(taskCore).completeExecution(true);

        result.success = true;
        result.gasUsed = startGas - gasleft();
        result.rewardPaid = rewardPaid;

        return result;
    }

    // ============ Internal Functions ============

    /**
     * @notice Load task addresses from registry
     * @param taskId Task identifier
     * @return taskCore Address of TaskCore
     * @return taskVault Address of TaskVault
     */
    function _loadTask(uint256 taskId)
        internal
        view
        returns (address taskCore, address taskVault)
    {
        require(taskRegistry != address(0), "Registry not set");

        // Call registry to get task addresses
        (bool success, bytes memory data) = taskRegistry.staticcall(
            abi.encodeWithSignature("getTaskAddresses(uint256)", taskId)
        );

        require(success, "Task not found");
        (taskCore, taskVault) = abi.decode(data, (address, address));

        require(taskCore != address(0), "Invalid task");
    }

    /**
     * @notice Verify condition proof and check if condition is met
     * @param conditionHash Stored hash of condition
     * @param conditionProof Encoded condition data with Merkle proof
     * @return bool Whether condition is met
     */
    function _verifyAndCheckCondition(
        bytes32 conditionHash,
        bytes calldata conditionProof
    ) internal view returns (bool) {
        if (conditionOracle == address(0)) {
            return true; // No oracle = always pass
        }

        // Decode proof structure
        (
            IConditionOracle.Condition memory condition,
            bytes32[] memory merkleProof
        ) = abi.decode(conditionProof, (IConditionOracle.Condition, bytes32[]));

        // Verify proof if Merkle proof provided
        if (merkleProof.length > 0) {
            bytes32 leaf = keccak256(abi.encode(condition.conditionType, condition.params));
            bool valid = merkleProof.verify(conditionHash, leaf);

            if (!valid) revert ConditionNotMet();
        } else {
            // Direct hash comparison (single condition case)
            bytes32 computedHash = keccak256(abi.encode(condition.conditionType, condition.params));
            if (computedHash != conditionHash) revert ConditionNotMet();
        }

        // Check condition
        IConditionOracle.ConditionResult memory condResult =
            IConditionOracle(conditionOracle).checkCondition(condition);

        return condResult.isMet;
    }

    /**
     * @notice Verify action proofs and execute actions
     * @param taskVault Address of task vault
     * @param actionsHash Stored hash of actions
     * @param actionsProof Encoded actions with Merkle proofs
     * @return bool Whether all actions succeeded
     */
    function _verifyAndExecuteActions(
        address taskVault,
        bytes32 actionsHash,
        bytes calldata actionsProof
    ) internal returns (bool) {
        require(actionRegistry != address(0), "Registry not set");

        // Decode actions and proofs
        (
            Action[] memory actions,
            bytes32[] memory merkleProof
        ) = abi.decode(actionsProof, (Action[], bytes32[]));

        // Verify actions against hash
        if (merkleProof.length > 0) {
            // Multiple actions - verify Merkle root
            bytes32[] memory leaves = new bytes32[](actions.length);

            for (uint256 i = 0; i < actions.length; i++) {
                leaves[i] = keccak256(abi.encode(
                    actions[i].selector,
                    actions[i].protocol,
                    actions[i].params
                ));
            }

            // Compute root and verify
            bytes32 computedRoot = _computeRoot(leaves);
            bool valid = merkleProof.verify(actionsHash, computedRoot);

            if (!valid) revert ActionsFailed();
        } else {
            // Single action - direct hash
            bytes32 computedHash = keccak256(abi.encode(
                actions[0].selector,
                actions[0].protocol,
                actions[0].params
            ));

            if (computedHash != actionsHash) revert ActionsFailed();
        }

        // Execute each action
        for (uint256 i = 0; i < actions.length; i++) {
            bool success = _executeAction(taskVault, actions[i]);
            if (!success) {
                return false;
            }
        }

        return true;
    }

    /**
     * @notice Execute a single action
     * @param taskVault Address of task vault
     * @param action Action to execute
     * @return bool Whether action succeeded
     */
    function _executeAction(address taskVault, Action memory action) internal returns (bool) {
        // Get adapter from registry
        IActionRegistry.AdapterInfo memory adapterInfo =
            IActionRegistry(actionRegistry).getAdapter(action.selector);

        if (!adapterInfo.isActive) revert ActionsFailed();

        // Check protocol is approved
        if (!IActionRegistry(actionRegistry).isProtocolApproved(action.protocol)) {
            revert ActionsFailed();
        }

        // Prepare adapter call
        bytes memory adapterCall = abi.encodeWithSelector(
            IActionAdapter.execute.selector,
            taskVault,
            action.params
        );

        // Execute through vault with gas limit
        (bool success, ) = taskVault.call{gas: adapterInfo.gasLimit}(
            abi.encodeWithSignature(
                "executeTokenAction(address,address,uint256,bytes)",
                address(0), // token (determined by adapter)
                adapterInfo.adapter,
                0, // amount (determined by adapter)
                adapterCall
            )
        );

        return success;
    }

    /**
     * @notice Distribute reward to executor
     * @param taskVault Address of task vault
     * @param executor Executor address
     * @param baseReward Base reward amount
     * @param gasUsed Gas consumed
     * @return uint256 Total reward paid
     */
    function _distributeReward(
        address taskVault,
        address executor,
        uint256 baseReward,
        uint256 gasUsed
    ) internal returns (uint256) {
        if (rewardManager == address(0)) {
            return 0;
        }

        // Calculate reward and distribute
        uint256 totalPaid = IRewardManager(rewardManager).distributeReward(
            taskVault,
            executor,
            baseReward,
            gasUsed
        );

        return totalPaid;
    }

    /**
     * @notice Compute Merkle root from leaves
     * @param leaves Array of leaf hashes
     * @return bytes32 Merkle root
     */
    function _computeRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "Empty leaves");

        if (leaves.length == 1) {
            return leaves[0];
        }

        uint256 n = leaves.length;
        uint256 offset = 0;

        while (n > 0) {
            for (uint256 i = 0; i < n / 2; i++) {
                leaves[offset + i] = _hashPair(
                    leaves[offset + i * 2],
                    leaves[offset + i * 2 + 1]
                );
            }
            offset += n / 2;
            n = n / 2;
        }

        return leaves[0];
    }

    /**
     * @notice Hash pair in sorted order
     */
    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32 value) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }

    // ============ Structs ============

    struct Action {
        bytes4 selector;
        address protocol;
        bytes params;
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

    function setTaskRegistry(address _taskRegistry) external onlyOwner {
        require(_taskRegistry != address(0), "Invalid registry");
        taskRegistry = _taskRegistry;
    }

    /// @notice Pause execution (emergency)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause execution
    function unpause() external onlyOwner {
        _unpause();
    }
}
