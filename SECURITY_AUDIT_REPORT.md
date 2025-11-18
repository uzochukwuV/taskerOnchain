# TaskerOnchain Smart Contract Security Audit Report

**Audit Date:** 2025-11-18
**Auditor:** Claude Code Agent
**Contracts Version:** Latest commit (b88b7f2)
**Solidity Version:** ^0.8.20

---

## Executive Summary

This audit identified **15 security vulnerabilities** ranging from **CRITICAL** to **LOW** severity:
- **3 CRITICAL** vulnerabilities (fund loss, logic bugs, insufficient funding validation)
- **5 HIGH** vulnerabilities (token recovery issues, race conditions, validation gaps)
- **4 MEDIUM** vulnerabilities (gas issues, price manipulation, event inconsistencies)
- **3 LOW** vulnerabilities (DoS vectors, design quirks)

### Critical Issues Requiring Immediate Attention:
1. **[CRITICAL] Insufficient Vault Funding Validation** - Tasks will fail prematurely
2. **[CRITICAL] Token Recovery Logic Bug in TaskVault** - Permanent fund loss
3. **[CRITICAL] Unlimited Execution Funding Bug** - maxExecutions=0 underfunded

---

## Architecture Overview

### System Components
```
TaskFactory (Entry Point)
    ├── TaskCore (Task Lifecycle Management)
    ├── TaskVault (Fund Storage - Isolated per task)
    └── GlobalRegistry (Task Registry)

ExecutorHub (Executor Management)
    └── TaskLogicV2 (Execution Orchestration)
        ├── ActionRegistry (Adapter Registry)
        │   └── Adapters (e.g., UniswapV2USDCETHBuyLimitAdapter)
        └── RewardManager (Reward Distribution)
```

### Execution Flow
```
1. User creates task → TaskFactory.createTask()
2. Factory deploys TaskCore + TaskVault (minimal proxies)
3. User funds TaskVault with ETH/tokens
4. Executor calls ExecutorHub.executeTask()
5. ExecutorHub → TaskLogicV2.executeTask()
6. TaskLogicV2 validates Merkle proofs
7. TaskLogicV2 → TaskVault.executeTokenAction()
8. TaskVault → Adapter.execute()
9. RewardManager.distributeReward()
10. TaskCore.completeExecution()
```

---

## Critical Vulnerabilities (IN SCOPE)

### 🔴 CRITICAL-1: Insufficient Vault Funding Validation

**Contract:** `RewardManager.sol`, `TaskFactory.sol`
**Location:** `RewardManager.sol:74-108`, `TaskFactory.sol:114-120`
**Severity:** CRITICAL
**Type:** Logic Bug / Fund Loss

#### Description
The reward calculation includes reputation multipliers (up to 125%), platform fees (1%), and gas reimbursement (120% of gas), but the TaskFactory only validates that the user funded `baseReward * maxExecutions`. This causes tasks to fail prematurely when the vault runs out of funds.

#### Vulnerable Code
```solidity
// TaskFactory.sol:114-120
uint256 totalReward = params.maxExecutions == 0
    ? params.rewardPerExecution
    : params.rewardPerExecution * params.maxExecutions;

uint256 providedValue = msg.value - creationFee;
require(providedValue >= totalReward, "Insufficient reward funding");
```

```solidity
// RewardManager.sol:51-68
uint256 executorReward = (baseReward * multiplier) / BASIS_POINTS; // Up to 125%
uint256 platformFee = (baseReward * platformFeePercentage) / BASIS_POINTS; // 1%
uint256 gasReimbursement = (gasUsed * tx.gasprice * gasReimbursementMultiplier) / 100; // 120%
uint256 totalFromVault = executorReward + platformFee + gasReimbursement;
```

#### Proof of Concept
```javascript
// Scenario: User creates task with 10 executions @ 1 ETH each
// User funds: 10 ETH
// First execution:
//   - Executor reputation multiplier: 125%
//   - executorReward: 1 ETH * 1.25 = 1.25 ETH
//   - platformFee: 1 ETH * 0.01 = 0.01 ETH
//   - gasReimbursement: ~0.1 ETH (estimated)
//   - Total needed: 1.36 ETH per execution
// Total needed for 10 executions: 13.6 ETH
// Funded: 10 ETH
// Result: Task fails after ~7 executions (10 ETH / 1.36 ETH)
```

#### Attack Scenario
1. User creates task with `rewardPerExecution = 1 ETH` and `maxExecutions = 10`
2. User sends exactly 10 ETH (thinking it's sufficient)
3. First executor has high reputation (125% multiplier)
4. First execution consumes 1.36 ETH instead of 1 ETH
5. After 7 executions, vault has insufficient funds
6. Remaining 3 executions fail with "InsufficientVaultBalance"
7. User loses ability to execute remaining tasks

#### Impact
- **Fund Loss:** Users cannot retrieve unused execution slots
- **Task Failure:** Tasks fail before reaching maxExecutions
- **Poor UX:** Users don't understand why their task stopped working

#### Recommendation
```solidity
// TaskFactory.sol - Add comprehensive funding validation
function _validateFunding(TaskParams calldata params, uint256 providedValue) internal view {
    uint256 estimatedGasReimbursement = 500000 * tx.gasprice * 120 / 100; // Conservative estimate
    uint256 maxReputationMultiplier = 12500; // 125%
    uint256 platformFeeRate = platformFeePercentage; // 100 = 1%

    uint256 costPerExecution = (
        (params.rewardPerExecution * maxReputationMultiplier / 10000) +
        (params.rewardPerExecution * platformFeeRate / 10000) +
        estimatedGasReimbursement
    );

    uint256 totalRequired = params.maxExecutions == 0
        ? costPerExecution * 3 // At least 3 executions for unlimited tasks
        : costPerExecution * params.maxExecutions;

    require(providedValue >= totalRequired, "Insufficient funding for rewards+fees+gas");
}
```

---

### 🔴 CRITICAL-2: Token Recovery Logic Bug in executeTokenAction

**Contract:** `TaskVault.sol`
**Location:** `TaskVault.sol:169-178`
**Severity:** CRITICAL
**Type:** Fund Loss

#### Description
When an action fails, the token recovery logic only adds tokens back to the vault's internal balance if the actual token balance exceeds the expected balance. However, if a malicious or buggy adapter pulls tokens but doesn't return them, the vault permanently loses those tokens.

#### Vulnerable Code
```solidity
// TaskVault.sol:141-178
tokenBalances[token] -= amount;  // Line 141
tokenReserved[token] += amount;  // Line 142

// Execute action through adapter
(bool callSuccess, bytes memory returnData) = adapter.call(actionData);  // Line 148

// Unreserve tokens
tokenReserved[token] -= amount;  // Line 166

// If failed, tokens should have been returned to vault
if (success == false) {
    // Reclaim tokens that weren't spent
    uint256 currentBalance = IERC20(token).balanceOf(address(this));
    uint256 expectedBalance = tokenBalances[token] + tokenReserved[token];

    if (currentBalance > expectedBalance) {
        // Adapter returned tokens
        tokenBalances[token] += (currentBalance - expectedBalance);
    }
}
```

#### Proof of Concept - Token Loss Scenario
```javascript
// Initial state:
// - Vault actual balance: 1000 USDC
// - tokenBalances[USDC]: 1000
// - tokenReserved[USDC]: 0

// Execution with malicious adapter:
// 1. Line 141: tokenBalances[USDC] -= 100 → 900
// 2. Line 142: tokenReserved[USDC] += 100 → 100
// 3. Line 145: Approve adapter for 100 USDC
// 4. Line 148: Adapter.call()
//    - Adapter pulls 100 USDC via transferFrom (actual balance = 900)
//    - Adapter keeps the USDC (malicious behavior)
//    - Adapter returns success = false
// 5. Line 166: tokenReserved[USDC] -= 100 → 0
// 6. Line 169: success == false (enter recovery)
// 7. Line 171: currentBalance = 900 USDC
// 8. Line 172: expectedBalance = 900 + 0 = 900
// 9. Line 174: 900 > 900? NO - No recovery performed
// 10. Result: Vault lost 100 USDC permanently!
//     - tokenBalances[USDC] = 900
//     - Actual balance = 900
//     - Missing 100 USDC (stolen by adapter)
```

#### Attack Scenario
```solidity
// Malicious Adapter
contract MaliciousAdapter {
    function execute(address vault, bytes calldata params) external returns (bool, bytes memory) {
        // Pull tokens from vault (vault approved us)
        IERC20(token).transferFrom(vault, address(this), amount);

        // Keep the tokens and return false (pretend we failed)
        return (false, "Failed");
    }
}

// Attack steps:
// 1. Attacker registers malicious adapter in ActionRegistry (requires owner access)
// 2. OR: Attacker exploits a buggy approved adapter
// 3. Adapter pulls tokens but returns false
// 4. Vault's recovery logic fails to detect missing tokens
// 5. Tokens are permanently lost
```

#### Impact
- **Direct Fund Loss:** Tokens can be stolen by malicious adapters
- **Protocol Risk:** Any buggy adapter that pulls tokens but fails will cause permanent fund loss
- **Trust Issues:** Users lose funds due to adapter bugs

#### Recommendation
```solidity
// TaskVault.sol - Fix token recovery logic
function executeTokenAction(
    address token,
    address adapter,
    uint256 amount,
    bytes calldata actionData
) external onlyTaskLogic nonReentrant returns (bool success, bytes memory result) {
    require(token != address(0), "Invalid token");
    require(adapter != address(0), "Invalid adapter");

    if (tokenBalances[token] < amount) revert InsufficientBalance();

    // Record balances BEFORE execution
    uint256 balanceBefore = IERC20(token).balanceOf(address(this));

    // Reserve tokens
    tokenBalances[token] -= amount;
    tokenReserved[token] += amount;

    // Approve adapter to spend tokens
    IERC20(token).approve(adapter, amount);

    // Execute action through adapter
    (bool callSuccess, bytes memory returnData) = adapter.call(actionData);

    // Decode response
    if (callSuccess && returnData.length > 0) {
        (success, result) = abi.decode(returnData, (bool, bytes));
    } else {
        success = false;
        result = returnData;
    }

    // Cleanup: remove approval
    IERC20(token).approve(adapter, 0);

    // Unreserve tokens
    tokenReserved[token] -= amount;

    // Calculate actual tokens spent/returned
    uint256 balanceAfter = IERC20(token).balanceOf(address(this));
    uint256 actualSpent = balanceBefore - balanceAfter;

    if (success) {
        // Action succeeded - update balance based on actual spent
        // tokenBalances already reduced by 'amount', adjust for difference
        if (actualSpent < amount) {
            // Adapter didn't spend everything, return the difference
            tokenBalances[token] += (amount - actualSpent);
        } else if (actualSpent > amount) {
            // Should never happen, but handle gracefully
            revert("Adapter overspent");
        }
    } else {
        // Action failed - tokens should be returned
        if (actualSpent > 0) {
            // Adapter spent tokens despite failing - this is a bug/attack
            // We already reduced tokenBalances by 'amount'
            // We need to reduce it further by the amount actually lost
            if (actualSpent >= amount) {
                // All tokens lost
                revert("Adapter failed but consumed tokens");
            } else {
                // Some tokens returned, some lost
                // tokenBalances[token] -= (amount - (balanceBefore - balanceAfter));
                // Simplify: tokenBalances already -= amount,
                // add back what we got back
                tokenBalances[token] += (amount - actualSpent);
            }
        } else {
            // No tokens spent, recover all
            tokenBalances[token] += amount;
        }
    }

    emit TokenActionExecuted(token, adapter, actualSpent, success);
    return (success, result);
}
```

---

### 🔴 CRITICAL-3: Unlimited Execution Underfunding Bug

**Contract:** `TaskFactory.sol`, `TaskCore.sol`
**Location:** `TaskFactory.sol:114-118`, `TaskCore.sol:114-116`
**Severity:** CRITICAL
**Type:** Logic Bug / Inconsistent Behavior

#### Description
When `maxExecutions == 0` (unlimited executions), TaskFactory only requires funding for 1 execution, but the task can actually be executed unlimited times. This leads to the vault running out of funds after the first execution.

#### Vulnerable Code
```solidity
// TaskFactory.sol:114-118
uint256 totalReward = params.maxExecutions == 0
    ? params.rewardPerExecution  // Only 1 execution worth!
    : params.rewardPerExecution * params.maxExecutions;

uint256 providedValue = msg.value - creationFee;
require(providedValue >= totalReward, "Insufficient reward funding");
```

```solidity
// TaskCore.sol:162-164
if (metadata.maxExecutions > 0 && metadata.executionCount >= metadata.maxExecutions) {
    return false;  // maxExecutions == 0 means unlimited executions!
}
```

#### Proof of Concept
```javascript
// User creates unlimited recurring task:
TaskParams({
    rewardPerExecution: 1 ether,
    maxExecutions: 0,  // Unlimited executions
    recurringInterval: 1 day,
    expiresAt: block.timestamp + 365 days,
    seedCommitment: bytes32(0)
})

// Factory validation:
// totalReward = 1 ether (only 1 execution)
// User sends 1 ether
// Validation passes ✓

// First execution:
// - Task executes successfully
// - Vault has ~0 ETH left (after fees + gas)
// - executionCount = 1

// Second execution (1 day later):
// - isExecutable() returns true (no maxExecutions check)
// - TaskLogic calls executeTask()
// - Vault has insufficient funds
// - Execution fails with "InsufficientVaultBalance"

// Result: Task is broken after first execution
```

#### Impact
- **Task Failure:** Unlimited execution tasks fail after first execution
- **User Confusion:** Users don't understand why unlimited tasks stop working
- **Fund Waste:** Users pay for task creation but get only 1 execution

#### Recommendation
```solidity
// TaskFactory.sol - Fix unlimited execution validation
function _validateTaskParams(TaskParams calldata params, ActionParams[] calldata actions)
    internal
    view
{
    if (params.rewardPerExecution < minTaskReward) revert InvalidReward();

    // NEW: Disallow unlimited executions OR require substantial funding
    if (params.maxExecutions == 0) {
        // Option 1: Disallow unlimited executions
        revert("Unlimited executions not supported");

        // Option 2: Require minimum funding (e.g., 10 executions)
        // uint256 minExecutions = 10;
        // uint256 minFunding = params.rewardPerExecution * minExecutions;
        // require(msg.value >= minFunding, "Insufficient funding for unlimited task");
    }

    if (params.expiresAt != 0) {
        if (params.expiresAt <= block.timestamp) revert InvalidExpiration();
        if (params.expiresAt > block.timestamp + maxTaskDuration) revert InvalidExpiration();
    }

    if (actions.length == 0 || actions.length > 10) revert InvalidActions();
}
```

---

## High Severity Vulnerabilities

### 🟠 HIGH-1: Unsafe ETH Transfer in releaseReward

**Contract:** `TaskVault.sol`
**Location:** `TaskVault.sol:117-118`
**Severity:** HIGH
**Type:** Potential Reentrancy / Gas Griefing

#### Description
The vault uses a low-level `.call{value: amount}("")` to send ETH to the executor without a gas limit. A malicious executor contract could consume all available gas or attempt reentrancy attacks.

#### Vulnerable Code
```solidity
// TaskVault.sol:117-118
(bool success, ) = executor.call{value: amount}("");
if (!success) revert TransferFailed();
```

#### Recommendation
```solidity
// Option 1: Use gas-limited call
(bool success, ) = executor.call{value: amount, gas: 2300}("");

// Option 2: Use transfer (auto gas-limited to 2300)
payable(executor).transfer(amount);

// Option 3: Pull payment pattern (most secure)
mapping(address => uint256) public pendingWithdrawals;
function claimReward() external nonReentrant {
    uint256 amount = pendingWithdrawals[msg.sender];
    require(amount > 0, "No pending reward");
    pendingWithdrawals[msg.sender] = 0;
    payable(msg.sender).transfer(amount);
}
```

---

### 🟠 HIGH-2: tx.origin Usage in Event Emission

**Contract:** `TaskCore.sol`
**Location:** `TaskCore.sol:96, 100`
**Severity:** HIGH
**Type:** Information Disclosure / Incorrect Attribution

#### Description
The `TaskExecuted` event emits `tx.origin` instead of the `executor` parameter, leading to incorrect attribution of who executed the task.

#### Vulnerable Code
```solidity
// TaskCore.sol:96, 100
emit TaskExecuted(taskId, tx.origin, true, metadata.rewardPerExecution, 0);
emit TaskExecuted(taskId, tx.origin, false, 0, 0);
```

#### Impact
- Rewards may be sent to wrong address
- Event listeners receive incorrect data
- Phishing attacks via proxy contracts

#### Recommendation
```solidity
// TaskCore.sol:96, 100 - Use executor parameter instead
emit TaskExecuted(taskId, executor, true, metadata.rewardPerExecution, 0);
emit TaskExecuted(taskId, executor, false, 0, 0);
```

---

### 🟠 HIGH-3: Missing Refund Mechanism After Task Completion

**Contract:** `TaskCore.sol`
**Location:** `TaskCore.sol:89-95`
**Severity:** HIGH
**Type:** Fund Lock

#### Description
When a task completes all executions, any remaining funds in the vault are locked forever. There's no mechanism to refund the creator.

#### Current Behavior
```solidity
// TaskCore.sol:89-95
if (metadata.maxExecutions > 0 && metadata.executionCount >= metadata.maxExecutions) {
    _setStatus(TaskStatus.COMPLETED);  // Status changes to COMPLETED
} else {
    _setStatus(TaskStatus.ACTIVE);
}
```

After status is COMPLETED:
- `cancel()` requires status to be ACTIVE or PAUSED (line 107-108)
- `withdrawAll()` in vault requires status to be CANCELLED (line 190)
- Funds are permanently locked

#### Recommendation
```solidity
// TaskCore.sol - Add refund mechanism for completed tasks
function claimRefund() external onlyCreator returns (uint256 refundAmount) {
    require(
        metadata.status == TaskStatus.COMPLETED ||
        metadata.status == TaskStatus.EXPIRED,
        "Task not finished"
    );

    // Transfer all remaining vault funds to creator
    // (This would require adding a new function to TaskVault)
}

// TaskVault.sol - Add refund function
function refundCreator() external onlyTaskCore returns (uint256 amount) {
    require(
        ITaskCore(taskCore).getMetadata().status == ITaskCore.TaskStatus.COMPLETED ||
        ITaskCore(taskCore).getMetadata().status == ITaskCore.TaskStatus.EXPIRED,
        "Task not finished"
    );

    amount = nativeBalance - nativeReserved;
    if (amount > 0) {
        nativeBalance -= amount;
        (bool success, ) = creator.call{value: amount}("");
        require(success, "Transfer failed");
    }
}
```

---

### 🟠 HIGH-4: Merkle Proof Bypass Potential

**Contract:** `TaskLogicV2.sol`
**Location:** `TaskLogicV2.sol:169-191`
**Severity:** HIGH
**Type:** Logic Bug / Verification Bypass

#### Description
The Merkle proof verification branches on `merkleProof.length > 0`. An attacker could attempt to bypass verification by providing carefully crafted empty proofs, though the hash check should prevent this in most cases.

#### Vulnerable Code
```solidity
// TaskLogicV2.sol:169-191
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
    bytes32 computedRoot = _computeRoot(leaves);
    bool valid = merkleProof.verify(actionsHash, computedRoot);
    if (!valid) revert ActionsFailed();
} else {
    // Single action - hash the entire action array
    bytes32 computedHash = keccak256(abi.encode(actions));
    if (computedHash != actionsHash) revert ActionsFailed();
}
```

#### Recommendation
```solidity
// TaskLogicV2.sol - Enforce explicit action count validation
function _verifyAndExecuteActions(
    address taskVault,
    bytes32 actionsHash,
    bytes calldata actionsProof
) internal returns (bool) {
    require(actionRegistry != address(0), "Registry not set");

    (
        Action[] memory actions,
        bytes32[] memory merkleProof,
        uint256 expectedActionCount  // NEW: Add explicit count
    ) = abi.decode(actionsProof, (Action[], bytes32[], uint256));

    // Validate action count matches
    require(actions.length == expectedActionCount, "Action count mismatch");

    if (actions.length == 1) {
        // Single action - direct hash
        bytes32 computedHash = keccak256(abi.encode(actions));
        if (computedHash != actionsHash) revert ActionsFailed();
    } else {
        // Multiple actions - require Merkle proof
        require(merkleProof.length > 0, "Missing Merkle proof");

        bytes32[] memory leaves = new bytes32[](actions.length);
        for (uint256 i = 0; i < actions.length; i++) {
            leaves[i] = keccak256(abi.encode(
                actions[i].selector,
                actions[i].protocol,
                actions[i].params
            ));
        }
        bytes32 computedRoot = _computeRoot(leaves);
        bool valid = merkleProof.verify(actionsHash, computedRoot);
        if (!valid) revert ActionsFailed();
    }

    // Execute actions...
}
```

---

### 🟠 HIGH-5: Integer Overflow in Gas Reimbursement

**Contract:** `RewardManager.sol`
**Location:** `RewardManager.sol:58`
**Severity:** HIGH (DoS potential)
**Type:** Overflow / DoS

#### Description
Gas reimbursement calculation could overflow if `gasUsed * tx.gasprice` exceeds `uint256.max / 120`, causing transaction reversion and preventing task execution.

#### Vulnerable Code
```solidity
// RewardManager.sol:58
uint256 gasReimbursement = (gasUsed * tx.gasprice * gasReimbursementMultiplier) / 100;
```

#### Recommendation
```solidity
// RewardManager.sol - Add overflow protection
uint256 public constant MAX_GAS_REIMBURSEMENT = 10 ether; // Cap at 10 ETH

function calculateReward(
    uint256 baseReward,
    address executor,
    uint256 gasUsed
) external view returns (RewardCalculation memory) {
    uint256 multiplier = getReputationMultiplier(executor);
    uint256 executorReward = (baseReward * multiplier) / BASIS_POINTS;
    uint256 platformFee = (baseReward * platformFeePercentage) / BASIS_POINTS;

    // Safe gas reimbursement calculation with cap
    uint256 gasReimbursement;
    if (gasUsed > 0 && tx.gasprice > 0) {
        // Check for overflow before multiplication
        uint256 gasCost = gasUsed * tx.gasprice;
        if (gasCost / gasUsed != tx.gasprice) {
            // Overflow detected, use max
            gasReimbursement = MAX_GAS_REIMBURSEMENT;
        } else {
            gasReimbursement = (gasCost * gasReimbursementMultiplier) / 100;
            if (gasReimbursement > MAX_GAS_REIMBURSEMENT) {
                gasReimbursement = MAX_GAS_REIMBURSEMENT;
            }
        }
    }

    uint256 totalFromVault = executorReward + platformFee + gasReimbursement;

    return RewardCalculation({
        executorReward: executorReward,
        platformFee: platformFee,
        gasReimbursement: gasReimbursement,
        totalFromVault: totalFromVault
    });
}
```

---

## Medium Severity Vulnerabilities

### 🟡 MEDIUM-1: Price Manipulation Risk in Uniswap Adapter

**Contract:** `UniswapV2USDCETHBuyLimitAdapter.sol`
**Location:** `UniswapV2USDCETHBuyLimitAdapter.sol:225-233`
**Severity:** MEDIUM
**Type:** Price Manipulation

#### Description
The adapter compares Uniswap spot price against Chainlink oracle with ±5% tolerance. An attacker could manipulate the Uniswap pool within this tolerance window.

#### Recommendation
- Implement TWAP (Time-Weighted Average Price)
- Reduce tolerance to ±2%
- Add minimum liquidity checks

---

### 🟡 MEDIUM-2: Centralization Risk in ActionRegistry

**Contract:** `ActionRegistry.sol`
**Location:** `ActionRegistry.sol:26-43`
**Severity:** MEDIUM
**Type:** Centralization / Trust

#### Description
The owner can register malicious adapters that steal funds. Consider implementing a multi-sig or DAO governance.

#### Recommendation
```solidity
// Add timelock for adapter registration
uint256 public constant ADAPTER_TIMELOCK = 7 days;
mapping(bytes4 => uint256) public pendingAdapterActivation;

function registerAdapter(bytes4 selector, address adapter, uint256 gasLimit, bool requiresTokens)
    external onlyOwner
{
    adapters[selector] = AdapterInfo({
        adapter: adapter,
        isActive: false,  // Not active yet
        gasLimit: gasLimit,
        requiresTokens: requiresTokens
    });
    pendingAdapterActivation[selector] = block.timestamp + ADAPTER_TIMELOCK;
    emit AdapterRegistered(selector, adapter);
}

function activateAdapter(bytes4 selector) external onlyOwner {
    require(block.timestamp >= pendingAdapterActivation[selector], "Timelock not expired");
    adapters[selector].isActive = true;
    emit AdapterActivated(selector);
}
```

---

### 🟡 MEDIUM-3: Gas Griefing via Long Action Arrays

**Contract:** `TaskLogicV2.sol`
**Location:** `TaskLogicV2.sol:194-199`
**Severity:** MEDIUM
**Type:** DoS / Gas Griefing

#### Description
Tasks with maximum 10 actions could consume excessive gas, causing out-of-gas errors or high costs for executors.

#### Recommendation
- Reduce max actions to 5
- Implement gas limit checks per action
- Add executor gas reimbursement caps

---

### 🟡 MEDIUM-4: Missing Staleness Check on Task Execution

**Contract:** `TaskCore.sol`
**Location:** `TaskCore.sol:156-159`
**Severity:** MEDIUM
**Type:** Logic Bug

#### Description
Expired tasks can still be executed if the status hasn't been updated. The `isExecutable()` check at line 157-159 checks expiration, but the status is never automatically updated to EXPIRED.

#### Recommendation
```solidity
// TaskCore.sol - Auto-update status on expiration check
function isExecutable() public view returns (bool) {
    if (metadata.status != TaskStatus.ACTIVE) {
        return false;
    }

    if (metadata.expiresAt != 0 && block.timestamp > metadata.expiresAt) {
        return false;  // Expired
    }

    // ... rest of checks
}

// Add a function to update status if expired
function updateStatusIfExpired() external {
    if (metadata.expiresAt != 0 &&
        block.timestamp > metadata.expiresAt &&
        metadata.status == TaskStatus.ACTIVE) {
        _setStatus(TaskStatus.EXPIRED);
    }
}
```

---

## Low Severity Vulnerabilities

### 🟢 LOW-1: Missing Zero Address Checks

**Contract:** Multiple
**Severity:** LOW
**Type:** Input Validation

#### Description
Several functions lack zero address validation for critical parameters.

**Affected Functions:**
- `TaskVault.initialize()` - no check on `_rewardManager`
- `TaskLogicV2.setActionRegistry()` - checked ✓
- `RewardManager.setExecutorHub()` - checked ✓

---

### 🟢 LOW-2: Testnet Security Features Disabled

**Contract:** `ExecutorHub.sol`
**Location:** `ExecutorHub.sol:133-139, 241-247`
**Severity:** LOW (Informational)
**Type:** Security Feature Disabled

#### Description
The ExecutorHub explicitly disables registration checks and commit-reveal mechanisms for testnet. Ensure these are re-enabled for mainnet.

```solidity
// ExecutorHub.sol:241-247
function canExecute(address) external pure returns (bool) {
    // TESTNET: Everyone can execute, no restrictions
    return true;
}
```

---

### 🟢 LOW-3: Incomplete Gas Calculation

**Contract:** `TaskLogicV2.sol`
**Location:** `TaskLogicV2.sol:52, 94`
**Severity:** LOW
**Type:** Accounting Issue

#### Description
Gas calculation happens before reward distribution, so the gas used for `_distributeReward()` is not included in reimbursement.

#### Recommendation
```solidity
// TaskLogicV2.sol - Calculate gas after all operations
function executeTask(ExecutionParams calldata params)
    external
    onlyExecutorHub
    whenNotPaused
    nonReentrant
    returns (ExecutionResult memory result)
{
    uint256 startGas = gasleft();

    // ... execution logic ...

    // Distribute reward
    uint256 rewardPaid = _distributeReward(
        taskVault,
        params.executor,
        metadata.rewardPerExecution,
        0  // Pass 0 initially
    );

    // Calculate total gas AFTER distribution
    uint256 gasUsed = startGas - gasleft();

    // Update reward with actual gas (may need to adjust reward)
    // OR: Calculate gas including a buffer for distribution
    uint256 adjustedGas = gasUsed + 50000; // Add buffer for distribution overhead

    result.gasUsed = adjustedGas;
    result.rewardPaid = rewardPaid;
    return result;
}
```

---

## Out of Scope Issues

The following were identified but are marked as OUT OF SCOPE per the bounty requirements:

1. **OLD-1:** Solidity version not locked (uses `^0.8.20`)
2. **OLD-2:** Gas optimizations (e.g., storage packing, loop optimization)
3. **OLD-3:** Code style inconsistencies
4. **OLD-4:** Missing NatSpec documentation in some functions
5. **OLD-5:** Redundant code in `TaskLib.computeMerkleRoot()`

---

## Recommendations Summary

### Immediate Actions (Critical)
1. ✅ Fix vault funding validation to account for fees + gas + multipliers
2. ✅ Fix token recovery logic in `executeTokenAction()`
3. ✅ Disallow or properly fund unlimited execution tasks (`maxExecutions = 0`)

### High Priority
4. ✅ Replace unsafe ETH transfers with gas-limited calls or pull pattern
5. ✅ Fix `tx.origin` usage in events
6. ✅ Add refund mechanism for completed tasks
7. ✅ Strengthen Merkle proof verification
8. ✅ Add overflow protection for gas reimbursement

### Medium Priority
9. ✅ Implement TWAP for Uniswap price checks
10. ✅ Add timelock for adapter registration
11. ✅ Reduce max actions or add gas caps
12. ✅ Auto-update expired task status

### Low Priority
13. ✅ Add comprehensive zero address checks
14. ✅ Re-enable security features for mainnet
15. ✅ Improve gas calculation accuracy

---

## Testing Recommendations

### Unit Tests Needed
```solidity
// Test insufficient vault funding
function testCRITICAL1_InsufficientVaultFunding() {
    // Create task with 10 executions @ 1 ETH each
    // Fund with exactly 10 ETH
    // Execute with high-reputation executor (125% multiplier)
    // Verify task fails after 7 executions
}

// Test token recovery bug
function testCRITICAL2_TokenRecoveryBug() {
    // Deploy malicious adapter that pulls tokens but returns false
    // Execute task
    // Verify vault loses tokens permanently
}

// Test unlimited execution underfunding
function testCRITICAL3_UnlimitedExecutionUnderfunding() {
    // Create task with maxExecutions = 0
    // Fund with 1 ETH
    // Execute twice
    // Verify second execution fails
}
```

### Integration Tests
- Multi-executor scenarios with varying reputations
- Edge cases for Merkle proof verification
- Gas limit stress tests with 10 actions
- Price manipulation scenarios in Uniswap adapter

### Fuzzing Targets
- `TaskVault.executeTokenAction()` - token balance accounting
- `TaskLogicV2._verifyAndExecuteActions()` - Merkle proof verification
- `RewardManager.calculateReward()` - overflow conditions
- `TaskFactory.createTask()` - funding validation

---

## Conclusion

The TaskerOnchain protocol demonstrates a well-architected system with proper use of minimal proxies, reentrancy guards, and separation of concerns. However, the **3 CRITICAL vulnerabilities** identified pose significant risks to user funds and protocol stability:

1. **Insufficient vault funding validation** will cause most tasks to fail prematurely
2. **Token recovery bug** allows permanent fund loss via malicious/buggy adapters
3. **Unlimited execution underfunding** breaks recurring task functionality

**Immediate remediation of these critical issues is required before mainnet deployment.**

The protocol would benefit from:
- Comprehensive unit and integration test coverage
- Formal verification of fund accounting logic
- Multi-sig governance for critical admin functions
- Bug bounty program after fixes are deployed

---

**Audit Completed:** 2025-11-18
**Next Steps:** Address critical vulnerabilities and re-audit before mainnet launch
