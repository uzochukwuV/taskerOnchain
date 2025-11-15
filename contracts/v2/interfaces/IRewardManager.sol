// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRewardManager
 * @notice Interface for RewardManager contract that handles reward distribution
 */
interface IRewardManager {

    // ============ Structs ============

    struct RewardCalculation {
        uint256 executorReward;
        uint256 platformFee;
        uint256 gasReimbursement;
        uint256 totalFromVault;
    }

    // ============ Events ============

    event RewardDistributed(
        uint256 indexed taskId,
        address indexed executor,
        uint256 executorReward,
        uint256 platformFee,
        uint256 gasReimbursement
    );

    event PlatformFeeCollected(address indexed recipient, uint256 amount);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee);

    // ============ Errors ============

    error OnlyTaskLogic();
    error InvalidFeePercentage();
    error InsufficientVaultBalance();

    // ============ Functions ============

    /// @notice Calculate reward breakdown
    function calculateReward(
        uint256 baseReward,
        address executor,
        uint256 gasUsed
    ) external view returns (RewardCalculation memory);

    /// @notice Distribute reward (called by TaskLogic)
    function distributeReward(
        address vault,
        address executor,
        uint256 baseReward,
        uint256 gasUsed
    ) external returns (uint256 totalPaid);

    /// @notice Collect accumulated platform fees
    function collectFees(address recipient) external returns (uint256 amount);

    /// @notice Set platform fee percentage
    function setPlatformFee(uint256 feePercentage) external;

    /// @notice Get platform fee percentage
    function platformFeePercentage() external view returns (uint256);

    /// @notice Get total fees collected
    function totalFeesCollected() external view returns (uint256);

    /// @notice Get reputation multiplier for executor
    function getReputationMultiplier(address executor) external view returns (uint256);
}
