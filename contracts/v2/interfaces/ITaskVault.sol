// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ITaskVault
 * @notice Interface for TaskVault contract that holds task funds in isolation
 */
interface ITaskVault {

    // ============ Structs ============

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    // ============ Events ============

    event NativeDeposited(address indexed from, uint256 amount);
    event TokenDeposited(address indexed token, address indexed from, uint256 amount);
    event RewardReleased(address indexed executor, uint256 amount);
    event TokenActionExecuted(address indexed token, address indexed adapter, uint256 amount, bool success);
    event FundsWithdrawn(address indexed to, uint256 nativeAmount, TokenAmount[] tokens);

    // ============ Errors ============

    error OnlyTaskCore();
    error OnlyTaskLogic();
    error OnlyCreator();
    error TaskNotCancelled();
    error InsufficientBalance();
    error TransferFailed();

    // ============ Functions ============

    /// @notice Initialize the vault (called by factory)
    function initialize(address _taskCore, address _creator, address _rewardManager) external;

    /// @notice Deposit native tokens (ETH/PAS)
    function depositNative() external payable;

    /// @notice Deposit ERC20 tokens
    function depositToken(address token, uint256 amount) external;

    /// @notice Release reward to executor (only TaskLogic)
    function releaseReward(address executor, uint256 amount) external;

    /// @notice Execute token action through adapter (only TaskLogic)
    function executeTokenAction(
        address token,
        address adapter,
        uint256 amount,
        bytes calldata actionData
    ) external returns (bool success, bytes memory result);

    /// @notice Withdraw all funds (only creator, only when cancelled)
    function withdrawAll() external returns (uint256 nativeAmount, TokenAmount[] memory tokens);

    /// @notice Get native balance
    function getNativeBalance() external view returns (uint256);

    /// @notice Get token balance
    function getTokenBalance(address token) external view returns (uint256);

    /// @notice Get available balance for rewards
    function getAvailableForRewards() external view returns (uint256);

    /// @notice Get task core address
    function taskCore() external view returns (address);

    /// @notice Get creator address
    function creator() external view returns (address);
}
