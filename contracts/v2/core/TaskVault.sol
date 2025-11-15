// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ITaskVault.sol";
import "../interfaces/ITaskCore.sol";

/**
 * @title TaskVault
 * @notice Isolated vault for holding task funds securely
 * @dev One vault per task, prevents fund mixing and enables proper accounting
 */
contract TaskVault is ITaskVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ State Variables ============

    address public taskCore;
    address public creator;
    address public rewardManager;
    address public taskLogic;

    uint256 private nativeBalance;
    uint256 private nativeReserved;

    mapping(address => uint256) private tokenBalances;
    mapping(address => uint256) private tokenReserved;

    address[] private trackedTokens;
    mapping(address => bool) private isTracked;

    bool private initialized;

    // ============ Modifiers ============

    modifier onlyTaskCore() {
        if (msg.sender != taskCore) revert OnlyTaskCore();
        _;
    }

    modifier onlyTaskLogic() {
        if (msg.sender != taskLogic) revert OnlyTaskLogic();
        _;
    }

    modifier onlyCreator() {
        if (msg.sender != creator) revert OnlyCreator();
        _;
    }

    modifier onlyCancelled() {
        ITaskCore.TaskStatus status = ITaskCore(taskCore).getMetadata().status;
        if (status != ITaskCore.TaskStatus.CANCELLED) revert TaskNotCancelled();
        _;
    }

    // ============ Initialization ============

    /// @inheritdoc ITaskVault
    function initialize(
        address _taskCore,
        address _creator,
        address _rewardManager
    ) external {
        require(!initialized, "Already initialized");
        require(_taskCore != address(0), "Invalid taskCore");
        require(_creator != address(0), "Invalid creator");
        require(_rewardManager != address(0), "Invalid rewardManager");

        initialized = true;
        taskCore = _taskCore;
        creator = _creator;
        rewardManager = _rewardManager;
        taskLogic = ITaskCore(_taskCore).logic();
    }

    // ============ Deposit Functions ============

    /// @inheritdoc ITaskVault
    function depositNative() external payable {
        require(msg.value > 0, "Zero deposit");
        nativeBalance += msg.value;
        emit NativeDeposited(msg.sender, msg.value);
    }

    /// @inheritdoc ITaskVault
    function depositToken(address token, uint256 amount) external nonReentrant {
        require(token != address(0), "Invalid token");
        require(amount > 0, "Zero amount");

        // Track token if not already tracked
        if (!isTracked[token]) {
            trackedTokens.push(token);
            isTracked[token] = true;
        }

        // Pull tokens from sender
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        tokenBalances[token] += amount;
        emit TokenDeposited(token, msg.sender, amount);
    }

    // ============ Execution Functions ============

    /// @inheritdoc ITaskVault
    function releaseReward(address executor, uint256 amount) external onlyTaskLogic nonReentrant {
        require(executor != address(0), "Invalid executor");

        if (nativeBalance < amount) revert InsufficientBalance();

        nativeBalance -= amount;
        nativeReserved += amount; // Mark as reserved until transfer completes

        (bool success, ) = executor.call{value: amount}("");
        if (!success) revert TransferFailed();

        nativeReserved -= amount; // Transfer complete, unreserve

        emit RewardReleased(executor, amount);
    }

    /// @inheritdoc ITaskVault
    function executeTokenAction(
        address token,
        address adapter,
        uint256 amount,
        bytes calldata actionData
    ) external onlyTaskLogic nonReentrant returns (bool success, bytes memory result) {
        require(token != address(0), "Invalid token");
        require(adapter != address(0), "Invalid adapter");

        if (tokenBalances[token] < amount) revert InsufficientBalance();

        // Reserve tokens
        tokenBalances[token] -= amount;
        tokenReserved[token] += amount;

        // Approve adapter to spend tokens
        IERC20(token).safeApprove(adapter, amount);

        // Execute action through adapter
        (success, result) = adapter.call(actionData);

        // Cleanup: remove approval
        IERC20(token).safeApprove(adapter, 0);

        // Unreserve tokens (adapter should have spent them or returned them)
        tokenReserved[token] -= amount;

        // If failed, tokens should have been returned to vault
        if (!success) {
            // Reclaim tokens that weren't spent
            uint256 currentBalance = IERC20(token).balanceOf(address(this));
            uint256 expectedBalance = tokenBalances[token] + tokenReserved[token];

            if (currentBalance > expectedBalance) {
                // Adapter returned tokens
                tokenBalances[token] += (currentBalance - expectedBalance);
            }
        }

        emit TokenActionExecuted(token, adapter, amount, success);
        return (success, result);
    }

    // ============ Withdrawal Functions ============

    /// @inheritdoc ITaskVault
    function withdrawAll()
        external
        onlyCreator
        onlyCancelled
        nonReentrant
        returns (uint256 nativeAmount, TokenAmount[] memory tokens)
    {
        // Calculate available native balance
        nativeAmount = nativeBalance - nativeReserved;

        // Calculate available token balances
        uint256 tokenCount = trackedTokens.length;
        tokens = new TokenAmount[](tokenCount);

        for (uint256 i = 0; i < tokenCount; i++) {
            address token = trackedTokens[i];
            uint256 available = tokenBalances[token] - tokenReserved[token];

            tokens[i] = TokenAmount({
                token: token,
                amount: available
            });

            if (available > 0) {
                tokenBalances[token] -= available;
                IERC20(token).safeTransfer(creator, available);
            }
        }

        // Transfer native tokens
        if (nativeAmount > 0) {
            nativeBalance -= nativeAmount;
            (bool success, ) = creator.call{value: nativeAmount}("");
            if (!success) revert TransferFailed();
        }

        emit FundsWithdrawn(creator, nativeAmount, tokens);
    }

    // ============ View Functions ============

    /// @inheritdoc ITaskVault
    function getNativeBalance() external view returns (uint256) {
        return nativeBalance;
    }

    /// @inheritdoc ITaskVault
    function getTokenBalance(address token) external view returns (uint256) {
        return tokenBalances[token];
    }

    /// @inheritdoc ITaskVault
    function getAvailableForRewards() external view returns (uint256) {
        return nativeBalance - nativeReserved;
    }

    /// @notice Get all tracked tokens
    function getTrackedTokens() external view returns (address[] memory) {
        return trackedTokens;
    }

    /// @notice Get available token balance (not reserved)
    function getAvailableTokenBalance(address token) external view returns (uint256) {
        return tokenBalances[token] - tokenReserved[token];
    }

    // ============ Receive Function ============

    receive() external payable {
        nativeBalance += msg.value;
        emit NativeDeposited(msg.sender, msg.value);
    }
}
