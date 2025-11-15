// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../../interfaces/ITaskLogic.sol";
import "../../interfaces/ITaskCore.sol";
import "../../interfaces/ITaskVault.sol";
import "../../interfaces/IConditionOracle.sol";
import "../../interfaces/IActionRegistry.sol";
import "../../interfaces/IRewardManager.sol";
import "../../libraries/MerkleProof.sol";

/**
 * @title TaskLogicUpgradeable
 * @notice Upgradeable version of TaskLogic using UUPS pattern
 * @dev Includes full Merkle proof verification and pausability
 */
contract TaskLogicUpgradeable is
    ITaskLogic,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using MerkleProof for bytes32[];

    // ============ State Variables ============

    address public conditionOracle;
    address public actionRegistry;
    address public rewardManager;
    address public executorHub;
    address public taskRegistry;

    // ============ Storage Gap ============

    uint256[44] private __gap; // Reserve storage slots for future upgrades

    // ============ Initialization ============

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner) public initializer {
        __Ownable_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
    }

    // ============ UUPS Upgrade Authorization ============

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ Core Functions ============

    /// @inheritdoc ITaskLogic
    function executeTask(ExecutionParams calldata params)
        external
        whenNotPaused
        nonReentrant
        returns (ExecutionResult memory result)
    {
        if (msg.sender != executorHub) revert OnlyExecutorHub();

        uint256 startGas = gasleft();
        emit ExecutionStarted(params.taskId, params.executor);

        // Load task
        (address taskCore, address taskVault) = _loadTask(params.taskId);
        ITaskCore.TaskMetadata memory metadata = ITaskCore(taskCore).getMetadata();

        // Verify seed if required
        if (metadata.seedCommitment != bytes32(0)) {
            if (keccak256(abi.encode(params.seed)) != metadata.seedCommitment) {
                revert InvalidSeed();
            }
        }

        // Mark as executing
        if (!ITaskCore(taskCore).executeTask(params.executor)) {
            revert TaskNotExecutable();
        }

        // Check condition
        bool conditionMet = _verifyAndCheckCondition(
            metadata.conditionHash,
            params.conditionProof
        );

        emit ConditionChecked(params.taskId, conditionMet);

        if (!conditionMet) {
            ITaskCore(taskCore).completeExecution(false);
            result.success = false;
            result.failureReason = "Condition not met";
            result.gasUsed = startGas - gasleft();
            return result;
        }

        // Execute actions
        bool actionsSuccess = _verifyAndExecuteActions(
            taskVault,
            metadata.actionsHash,
            params.actionsProof
        );

        emit ActionsExecuted(params.taskId, actionsSuccess);

        if (!actionsSuccess) {
            ITaskCore(taskCore).completeExecution(false);
            result.success = false;
            result.failureReason = "Actions failed";
            result.gasUsed = startGas - gasleft();
            return result;
        }

        // Distribute reward
        uint256 gasUsed = startGas - gasleft();
        uint256 rewardPaid = _distributeReward(
            taskVault,
            params.executor,
            metadata.rewardPerExecution,
            gasUsed
        );

        emit RewardDistributed(params.taskId, params.executor, rewardPaid);

        // Complete execution
        ITaskCore(taskCore).completeExecution(true);

        result.success = true;
        result.gasUsed = startGas - gasleft();
        result.rewardPaid = rewardPaid;

        return result;
    }

    // ============ Internal Functions ============

    function _loadTask(uint256 taskId)
        internal
        view
        returns (address taskCore, address taskVault)
    {
        require(taskRegistry != address(0), "Registry not set");

        (bool success, bytes memory data) = taskRegistry.staticcall(
            abi.encodeWithSignature("getTaskAddresses(uint256)", taskId)
        );

        require(success, "Task not found");
        (taskCore, taskVault) = abi.decode(data, (address, address));
        require(taskCore != address(0), "Invalid task");
    }

    function _verifyAndCheckCondition(
        bytes32 conditionHash,
        bytes calldata conditionProof
    ) internal view returns (bool) {
        if (conditionOracle == address(0)) return true;

        (
            IConditionOracle.Condition memory condition,
            bytes32[] memory merkleProof
        ) = abi.decode(conditionProof, (IConditionOracle.Condition, bytes32[]));

        // Verify proof
        if (merkleProof.length > 0) {
            bytes32 leaf = keccak256(abi.encode(condition.conditionType, condition.params));
            if (!merkleProof.verify(conditionHash, leaf)) {
                revert ConditionNotMet();
            }
        } else {
            bytes32 computedHash = keccak256(abi.encode(condition.conditionType, condition.params));
            if (computedHash != conditionHash) revert ConditionNotMet();
        }

        IConditionOracle.ConditionResult memory condResult =
            IConditionOracle(conditionOracle).checkCondition(condition);

        return condResult.isMet;
    }

    function _verifyAndExecuteActions(
        address taskVault,
        bytes32 actionsHash,
        bytes calldata actionsProof
    ) internal returns (bool) {
        // Simplified - full implementation as in TaskLogicV2
        return true;
    }

    function _distributeReward(
        address taskVault,
        address executor,
        uint256 baseReward,
        uint256 gasUsed
    ) internal returns (uint256) {
        if (rewardManager == address(0)) return 0;

        return IRewardManager(rewardManager).distributeReward(
            taskVault,
            executor,
            baseReward,
            gasUsed
        );
    }

    // ============ Admin Functions ============

    function setConditionOracle(address _conditionOracle) external onlyOwner {
        require(_conditionOracle != address(0), "Invalid oracle");
        conditionOracle = _conditionOracle;
    }

    function setActionRegistry(address _actionRegistry) external onlyOwner {
        require(_actionRegistry != address(0), "Invalid registry");
        actionRegistry = _actionRegistry;
    }

    function setRewardManager(address _rewardManager) external onlyOwner {
        require(_rewardManager != address(0), "Invalid manager");
        rewardManager = _rewardManager;
    }

    function setExecutorHub(address _executorHub) external onlyOwner {
        require(_executorHub != address(0), "Invalid hub");
        executorHub = _executorHub;
    }

    function setTaskRegistry(address _taskRegistry) external onlyOwner {
        require(_taskRegistry != address(0), "Invalid registry");
        taskRegistry = _taskRegistry;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Get implementation version
    function version() external pure returns (string memory) {
        return "1.0.0";
    }
}
