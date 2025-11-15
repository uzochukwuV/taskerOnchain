// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IRewardManager.sol";
import "../interfaces/ITaskVault.sol";
import "../interfaces/IExecutorHub.sol";

/**
 * @title RewardManager
 * @notice Calculates and distributes rewards to executors
 * @dev Applies reputation multipliers and collects platform fees
 */
contract RewardManager is IRewardManager, Ownable, ReentrancyGuard {

    // ============ State Variables ============

    address public taskLogic;
    address public executorHub;

    uint256 public platformFeePercentage = 100; // 1% (basis points)
    uint256 public constant MAX_PLATFORM_FEE = 500; // 5% maximum
    uint256 public constant BASIS_POINTS = 10000;

    uint256 public totalFeesCollected;
    uint256 public gasReimbursementMultiplier = 120; // 120% of gas used

    // ============ Constructor ============

    constructor(address _owner) Ownable(_owner) {}

    // ============ Modifiers ============

    modifier onlyTaskLogic() {
        if (msg.sender != taskLogic) revert OnlyTaskLogic();
        _;
    }

    // ============ Core Functions ============

    /// @inheritdoc IRewardManager
    function calculateReward(
        uint256 baseReward,
        address executor,
        uint256 gasUsed
    ) external view returns (RewardCalculation memory) {
        // Get reputation multiplier
        uint256 multiplier = getReputationMultiplier(executor);

        // Calculate executor reward with multiplier
        uint256 executorReward = (baseReward * multiplier) / BASIS_POINTS;

        // Calculate platform fee (on base reward, not multiplied)
        uint256 platformFee = (baseReward * platformFeePercentage) / BASIS_POINTS;

        // Calculate gas reimbursement (120% of actual gas)
        uint256 gasReimbursement = (gasUsed * tx.gasprice * gasReimbursementMultiplier) / 100;

        // Total amount needed from vault
        uint256 totalFromVault = executorReward + platformFee + gasReimbursement;

        return RewardCalculation({
            executorReward: executorReward,
            platformFee: platformFee,
            gasReimbursement: gasReimbursement,
            totalFromVault: totalFromVault
        });
    }

    /// @inheritdoc IRewardManager
    function distributeReward(
        address vault,
        address executor,
        uint256 baseReward,
        uint256 gasUsed
    ) external onlyTaskLogic nonReentrant returns (uint256 totalPaid) {
        // Calculate reward breakdown
        RewardCalculation memory calc = this.calculateReward(baseReward, executor, gasUsed);

        // Check vault has sufficient balance
        uint256 available = ITaskVault(vault).getAvailableForRewards();
        if (available < calc.totalFromVault) revert InsufficientVaultBalance();

        // Release total payment to executor (includes gas reimbursement)
        uint256 executorTotal = calc.executorReward + calc.gasReimbursement;
        ITaskVault(vault).releaseReward(executor, executorTotal);

        // Collect platform fee
        if (calc.platformFee > 0) {
            ITaskVault(vault).releaseReward(address(this), calc.platformFee);
            totalFeesCollected += calc.platformFee;
        }

        emit RewardDistributed(
            0, // taskId would come from context
            executor,
            calc.executorReward,
            calc.platformFee,
            calc.gasReimbursement
        );

        return calc.totalFromVault;
    }

    /// @inheritdoc IRewardManager
    function collectFees(address recipient) external onlyOwner nonReentrant returns (uint256 amount) {
        require(recipient != address(0), "Invalid recipient");

        amount = totalFeesCollected;
        totalFeesCollected = 0;

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Transfer failed");

        emit PlatformFeeCollected(recipient, amount);
    }

    // ============ Admin Functions ============

    /// @inheritdoc IRewardManager
    function setPlatformFee(uint256 feePercentage) external onlyOwner {
        if (feePercentage > MAX_PLATFORM_FEE) revert InvalidFeePercentage();

        uint256 oldFee = platformFeePercentage;
        platformFeePercentage = feePercentage;

        emit PlatformFeeUpdated(oldFee, feePercentage);
    }

    function setTaskLogic(address _taskLogic) external onlyOwner {
        require(_taskLogic != address(0), "Invalid logic");
        taskLogic = _taskLogic;
    }

    function setExecutorHub(address _executorHub) external onlyOwner {
        require(_executorHub != address(0), "Invalid hub");
        executorHub = _executorHub;
    }

    function setGasReimbursementMultiplier(uint256 _multiplier) external onlyOwner {
        require(_multiplier >= 100 && _multiplier <= 200, "Invalid multiplier");
        gasReimbursementMultiplier = _multiplier;
    }

    // ============ View Functions ============

    /// @inheritdoc IRewardManager
    function platformFeePercentage() external view returns (uint256) {
        return platformFeePercentage;
    }

    /// @inheritdoc IRewardManager
    function totalFeesCollected() external view returns (uint256) {
        return totalFeesCollected;
    }

    /// @inheritdoc IRewardManager
    function getReputationMultiplier(address executor) public view returns (uint256) {
        if (executorHub == address(0)) {
            return BASIS_POINTS; // 100% (no multiplier)
        }

        IExecutorHub.Executor memory exec = IExecutorHub(executorHub).getExecutor(executor);

        // Reputation score is 0-10000
        // Convert to multiplier: 5000 score = 100%, 10000 score = 125%
        // Multiplier = 10000 + (score * 25 / 10000)
        uint256 bonus = (exec.reputationScore * 2500) / BASIS_POINTS;
        return BASIS_POINTS + bonus; // Range: 100% to 125%
    }

    // ============ Receive Function ============

    receive() external payable {
        // Accept platform fees
    }
}
