# TaskerOnchain - Architecture Redesign Document

## Executive Summary

This document presents a comprehensive redesign of the TaskerOnchain smart contract system - an onchain task automation marketplace backed by the community. The current implementation has significant security vulnerabilities, architectural flaws, and gas inefficiencies that make it unsuitable for production use.

The redesigned architecture focuses on:
- **Modularity**: Small, focused contracts that stay well within EVM limits
- **Security**: Proper escrow patterns, oracle integration, and access control
- **Gas Efficiency**: Off-chain computation, efficient storage, and optimized execution
- **Scalability**: Factory patterns and upgradeable contracts
- **User Experience**: Clear task creation flows with proper asset management

---

## Table of Contents

1. [Current Architecture Analysis](#current-architecture-analysis)
2. [Critical Bugs & Vulnerabilities](#critical-bugs--vulnerabilities)
3. [Proposed Architecture](#proposed-architecture)
4. [Contract Specifications](#contract-specifications)
5. [Security Model](#security-model)
6. [Gas Optimization Strategies](#gas-optimization-strategies)
7. [User Flows](#user-flows)
8. [Migration Path](#migration-path)

---

## Current Architecture Analysis

### Issues Identified

#### 1. **Security Vulnerabilities** (CRITICAL)

**Low-level call() abuse:**
```solidity
// DynamicTaskRegistry.sol:331-339 - Unsafe escrow lock
(bool success, ) = paymentEscrow.call{value: totalFunding}(
    abi.encodeWithSignature(
        "lockFunds(uint256,address,uint256)",
        taskId,
        msg.sender,
        totalFunding
    )
);
require(success, "Escrow lock failed"); // No return data validation!
```
- **Risk**: If escrow contract changes interface, funds are lost
- **Risk**: Return data not validated - call can succeed but function fails

**Token handling in adapter:**
```solidity
// UniswapLimitOrderAdapter.sol:148-156
bool transferSuccess = IERC20(params.tokenIn).transferFrom(
    params.creator,
    address(this),
    params.amountIn
);
```
- **Risk**: Assumes creator has approved tokens DURING execution (won't work)
- **Risk**: No proper escrow - funds pulled on-demand
- **Risk**: Non-standard ERC20 tokens (USDT) will fail

**Re-entrancy vectors:**
```solidity
// DynamicTaskRegistry.sol:376-378 - State change AFTER external call
task.status = TaskStatus.EXECUTING;
bool conditionMet = _checkCondition(task.condition); // External call!
```
- **Risk**: Condition checker can re-enter and manipulate task state

**Missing access controls:**
- ActionRouter has no validation that msg.sender is authorized
- PaymentEscrow doesn't validate task existence before locking funds
- No emergency pause mechanism

#### 2. **Architectural Flaws**

**Monolithic contracts:**
- DynamicTaskRegistry: 866 lines, handles task creation, execution, payment, conditions
- Violates Single Responsibility Principle
- Gas-inefficient, hard to test, hard to upgrade

**Tight coupling via low-level calls:**
```solidity
(bool success, bytes memory result) = conditionChecker.call(
    abi.encodeWithSignature("checkCondition(uint8,bytes)", ...)
);
```
- Should use interfaces: `IConditionChecker(conditionChecker).checkCondition(...)`
- Makes testing impossible, type safety non-existent

**Storage inefficiency:**
```solidity
struct Task {
    uint256 id;
    address creator;
    uint256 reward;
    // ... 10 more fields
    Action[] actions; // Dynamic array in storage - GAS BOMB!
}
```
- Dynamic arrays in storage = expensive reads/writes
- Task struct has 15+ fields = multiple storage slots
- No packing optimization

**No separation of concerns:**
- Task metadata, execution logic, and payment all mixed
- Should separate: TaskRegistry (metadata), TaskExecutor (execution), TaskVault (funds)

#### 3. **Functional Bugs**

**Self-external call fails:**
```solidity
// DynamicTaskRegistry.sol:471
function executeTaskWithSeed(...) external {
    // ...
    return this.executeTask(_taskId, _executor); // Calls external function on self
}
```
- **Bug**: Calls `executeTask` which has `onlyExecutorManager` modifier
- **Result**: Always reverts because msg.sender is still this contract, not executorManager

**Recursive batch execution:**
```solidity
// ExecutorManager.sol:195-196
try this.attemptExecute(_taskIds[i]) {
    // ...
}
```
- **Bug**: External call to self in loop
- **Result**: Breaks re-entrancy guard, wastes gas, can cause stack overflow

**Missing token approval validation:**
```solidity
// UniswapLimitOrderAdapter.sol:148 - Pull tokens from creator
IERC20(params.tokenIn).transferFrom(params.creator, address(this), params.amountIn);
```
- **Bug**: No check that creator has approved this contract
- **Bug**: No validation that creator has sufficient balance
- **Result**: Transaction reverts, wasting executor gas

**Insufficient escrow logic:**
- PaymentEscrow only handles native tokens (ETH/PAS)
- ERC20 tokens for task execution not properly escrowed
- No way to escrow multiple token types per task

#### 4. **Gas Inefficiencies**

**Unbounded loops:**
```solidity
// DynamicTaskRegistry.sol:701-719
for (uint256 i = 0; i < nextTaskId && count < _limit; i++) {
    // Reads every task from storage!
}
```
- **Cost**: O(n) storage reads where n = total tasks ever created
- **Risk**: DoS as task count grows

**Redundant storage operations:**
- Reading task from storage multiple times in same function
- Not using memory caching
- Emitting events with full structs instead of indexed fields

**On-chain data storage:**
- Action params stored on-chain (could be IPFS hash)
- Condition data stored on-chain
- Should use commitment scheme (store hash, reveal on execution)

#### 5. **Economic/Game Theory Issues**

**Weak seed mechanism:**
```solidity
bytes32 providedHash = keccak256(abi.encodePacked(_seed));
require(providedHash == task.seedHash, "Invalid platform seed");
```
- **Issue**: Executor can brute-force seed offline
- **Issue**: No time-based seed rotation
- **Better**: Use Chainlink VRF or commit-reveal with time lock

**MEV/Front-running:**
- Task locks only 30 seconds (can be front-run)
- No priority queue or fair execution ordering
- High-value tasks will be front-run by MEV bots

**No slippage protection:**
- UniswapLimitOrderAdapter doesn't validate final output
- amountOutMin can be set maliciously low by creator
- No protection against sandwich attacks

#### 6. **Missing Features**

- No task cancellation after partial execution
- No emergency pause
- No upgradability
- No oracle verification
- No multi-signature for high-value tasks
- No insurance/slashing for failed executors
- No dispute resolution

---

## Critical Bugs & Vulnerabilities

### High Severity

| ID | Location | Issue | Impact | Fix |
|----|----------|-------|--------|-----|
| H-1 | DynamicTaskRegistry:471 | Self-external call breaks modifier | Tasks with seed cannot execute | Use internal function |
| H-2 | UniswapLimitOrderAdapter:148 | Token pull without escrow | Transactions revert, gas wasted | Pre-escrow tokens |
| H-3 | DynamicTaskRegistry:331 | Unsafe call without validation | Funds can be lost | Use interfaces |
| H-4 | PaymentEscrow:144 | No ERC20 support | Only native token tasks work | Add ERC20 vault |
| H-5 | ConditionChecker:199 | Unchecked external call | Malicious oracle can drain gas | Add gas limits |

### Medium Severity

| ID | Location | Issue | Impact | Fix |
|----|----------|-------|--------|-----|
| M-1 | DynamicTaskRegistry:701 | Unbounded loop | DoS as tasks grow | Use off-chain indexing |
| M-2 | ExecutorManager:195 | Recursive external call | Gas waste, stack issues | Use internal loop |
| M-3 | UniswapLimitOrderAdapter:159 | Unsafe approve | Approval race condition | Use safeApprove |
| M-4 | DynamicTaskRegistry:466 | Weak seed verification | Bots can brute-force | Use VRF or commit-reveal |
| M-5 | ActionRouter:174 | No gas limit on protocol call | Malicious protocol can drain gas | Add gas stipend |

### Low Severity

| ID | Location | Issue | Impact | Fix |
|----|----------|-------|--------|-----|
| L-1 | DynamicTaskRegistry:722 | Assembly for array resize | Gas inefficient | Return fixed array |
| L-2 | Multiple | Missing events | Poor off-chain tracking | Add events |
| L-3 | Multiple | Magic numbers | Hard to maintain | Use constants |
| L-4 | ReputationSystem:233 | Hardcoded weights | Inflexible reputation | Make configurable |
| L-5 | PaymentEscrow | No pause mechanism | Can't stop in emergency | Add pause |

---

## Proposed Architecture

### Design Principles

1. **Separation of Concerns**: Each contract has ONE job
2. **Interface-Driven**: All contracts use typed interfaces
3. **Factory Pattern**: Deploy task vaults via factory
4. **Upgradeable**: Use proxy pattern for core logic
5. **Off-chain First**: Store commitments on-chain, data off-chain
6. **Gas Optimized**: Minimal storage, efficient algorithms
7. **Secure by Default**: Fail-safe, not fail-deadly

### System Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      USER INTERFACE                          │
│  (Creates tasks, deposits funds, executes tasks)             │
└────────────────────┬────────────────────────────────────────┘
                     │
         ┌───────────┴───────────┐
         │                       │
         ▼                       ▼
┌──────────────────┐    ┌──────────────────┐
│  TaskFactory     │    │  ExecutorHub     │
│  (Deploy vaults) │    │  (Registration)  │
└────────┬─────────┘    └──────────────────┘
         │
         │ deploys
         ▼
┌──────────────────────────────────────────────────┐
│           TASK INSTANCE (Per Task)               │
│  ┌─────────────┐  ┌────────────┐  ┌───────────┐│
│  │ TaskVault   │  │ TaskCore   │  │ TaskLogic ││
│  │ (Funds)     │←─│ (Metadata) │←─│ (Execute) ││
│  └─────────────┘  └────────────┘  └─────┬─────┘│
└────────────────────────────────────────────┼────┘
                                             │
                    ┌────────────────────────┴─────────────────┐
                    │                                          │
                    ▼                                          ▼
          ┌──────────────────┐                      ┌──────────────────┐
          │  ConditionOracle │                      │  ActionAdapter   │
          │  (Verify trigger)│                      │  (Execute action)│
          └──────────────────┘                      └──────────────────┘
                    │                                          │
                    └────────────────┬─────────────────────────┘
                                     │
                                     ▼
                          ┌──────────────────┐
                          │  RewardManager   │
                          │  (Distribute)    │
                          └──────────────────┘
```

### Contract Breakdown

#### **Core Contracts** (Upgradeable via Proxy)

1. **TaskFactory.sol** (~200 lines)
   - Deploys new TaskCore + TaskVault pairs
   - Registers tasks in global registry
   - Manages task templates
   - Validates task parameters

2. **ExecutorHub.sol** (~250 lines)
   - Executor registration and staking
   - Reputation tracking
   - Slashing for misbehavior
   - Reward distribution

3. **GlobalRegistry.sol** (~150 lines)
   - Index of all tasks
   - Query executable tasks
   - Off-chain event tracking
   - Task status updates

#### **Task Instance Contracts** (Deployed per task via factory)

4. **TaskCore.sol** (~200 lines)
   - Task metadata (creator, expiry, max executions)
   - Task status management
   - Execution authorization
   - Minimal storage footprint

5. **TaskVault.sol** (~300 lines)
   - Holds task-specific funds (ETH + ERC20)
   - Escrows input tokens for swaps
   - Releases rewards to executors
   - Refunds to creator on cancellation
   - **One vault per task** = isolated funds

6. **TaskLogic.sol** (~250 lines)
   - Orchestrates execution flow
   - Validates conditions
   - Routes actions
   - Handles failures gracefully

#### **Support Contracts** (Shared across tasks)

7. **ConditionOracle.sol** (~200 lines)
   - Chainlink integration for prices
   - Time-based conditions
   - Balance checks
   - Custom oracle support

8. **ActionRegistry.sol** (~150 lines)
   - Registry of approved action adapters
   - Adapter validation
   - Gas limit management

9. **RewardManager.sol** (~200 lines)
   - Calculate executor rewards
   - Apply reputation multipliers
   - Distribute platform fees
   - Native token rewards

#### **Action Adapters** (Pluggable)

10. **UniswapV2Adapter.sol** (~200 lines)
    - Limit order swaps
    - Multi-hop routing
    - Slippage protection
    - Works with task vault

11. **AaveAdapter.sol** (~200 lines)
    - Supply/withdraw
    - Borrow/repay
    - Flash loans

12. **CompoundAdapter.sol** (~200 lines)
    - cToken interactions
    - Yield harvesting

13. **GenericAdapter.sol** (~150 lines)
    - Arbitrary approved protocol calls
    - Gas-limited execution

#### **Utility Contracts**

14. **PlatformToken.sol** (Standard ERC20)
    - TASK governance token
    - Staking for executors
    - Fee discounts

15. **AccessControl.sol** (~100 lines)
    - Role-based permissions
    - Multi-sig admin
    - Emergency controls

---

## Contract Specifications

### 1. TaskFactory.sol

**Purpose**: Deploy and configure new task instances

**State Variables**:
```solidity
// Immutable references
address public immutable taskCoreImplementation;
address public immutable taskVaultImplementation;
address public immutable executorHub;
address public immutable conditionOracle;
address public immutable actionRegistry;
address public immutable rewardManager;

// Configuration
uint256 public minTaskReward;      // Minimum reward per execution
uint256 public maxTaskDuration;    // Maximum task lifetime
uint256 public creationFee;        // Fee to create task (anti-spam)
mapping(uint256 => address) public tasks; // taskId => TaskCore address
uint256 public nextTaskId;
```

**Key Functions**:
```solidity
function createTask(
    TaskParams calldata params,
    ConditionParams calldata condition,
    ActionParams[] calldata actions
) external payable returns (uint256 taskId, address taskCore, address taskVault);

function createTaskWithTokens(
    TaskParams calldata params,
    ConditionParams calldata condition,
    ActionParams[] calldata actions,
    TokenDeposit[] calldata deposits // ERC20 tokens to escrow
) external returns (uint256 taskId, address taskCore, address taskVault);

function createRecurringTask(...) external returns (uint256 taskId);

function getTaskAddress(uint256 taskId) external view returns (address);
```

**Responsibilities**:
- Validate task parameters
- Deploy TaskCore clone (EIP-1167 minimal proxy)
- Deploy TaskVault clone
- Transfer funds to vault
- Emit TaskCreated event
- Register in GlobalRegistry

**Size Estimate**: ~200 lines

---

### 2. TaskCore.sol

**Purpose**: Store task metadata and manage lifecycle

**State Variables**:
```solidity
struct TaskMetadata {
    uint256 id;
    address creator;
    uint256 createdAt;
    uint256 expiresAt;
    uint256 maxExecutions;
    uint256 executionCount;
    uint256 lastExecutionTime;
    uint256 recurringInterval;
    uint256 rewardPerExecution;
    TaskStatus status;
    bytes32 conditionHash;    // Hash of condition params
    bytes32 actionsHash;      // Hash of actions array
    bytes32 seedCommitment;   // Commitment for executor randomness
}

TaskMetadata public metadata;
address public immutable vault;
address public immutable logic;
```

**Key Functions**:
```solidity
function execute(
    address executor,
    bytes32 seed,
    bytes calldata conditionProof,
    bytes calldata actionsProof
) external returns (bool success);

function cancel() external onlyCreator returns (uint256 refund);

function updateReward(uint256 newReward) external payable onlyCreator;

function pause() external onlyCreator;
function resume() external onlyCreator;

function isExecutable() external view returns (bool);
```

**Security**:
- Only TaskLogic can call execute()
- Only creator can cancel/pause
- No direct fund access (funds in vault)

**Size Estimate**: ~200 lines

---

### 3. TaskVault.sol

**Purpose**: Hold task funds securely with isolated accounting

**State Variables**:
```solidity
address public immutable taskCore;
address public immutable creator;
address public immutable rewardManager;

struct VaultBalance {
    uint256 nativeBalance;     // ETH/PAS
    uint256 nativeReserved;    // Reserved for rewards
    mapping(address => uint256) tokenBalances;    // ERC20 balances
    mapping(address => uint256) tokenReserved;    // Reserved for rewards
}

VaultBalance private balance;
```

**Key Functions**:
```solidity
// Deposit
function depositNative() external payable onlyCreatorOrFactory;
function depositToken(address token, uint256 amount) external onlyCreatorOrFactory;

// Withdraw (only creator, only if task cancelled)
function withdrawAll() external onlyCreatorWhenCancelled returns (uint256 native, TokenAmount[] memory tokens);

// Execution (only TaskLogic)
function releaseReward(address executor, uint256 amount) external onlyTaskLogic;

function executeTokenAction(
    address token,
    address adapter,
    uint256 amount,
    bytes calldata actionData
) external onlyTaskLogic returns (bool success);

// Views
function getBalance() external view returns (uint256 native, TokenAmount[] memory tokens);
function getAvailableForRewards() external view returns (uint256);
```

**Security Features**:
- **Isolated**: One vault per task, no cross-contamination
- **Access Control**: Only TaskLogic can release funds
- **Accounting**: Separate available vs reserved balances
- **Safe Transfers**: Use SafeERC20 for all token operations
- **Reentrancy**: ReentrancyGuard on all external calls

**Size Estimate**: ~300 lines

---

### 4. TaskLogic.sol

**Purpose**: Orchestrate task execution workflow

**Key Functions**:
```solidity
function executeTask(
    uint256 taskId,
    address executor,
    bytes32 seed,
    bytes calldata conditionProof,
    bytes calldata actionsProof
) external onlyExecutorHub returns (bool success, uint256 gasUsed);

function _validateExecution(TaskCore task, address executor) internal view;

function _checkCondition(
    bytes32 conditionHash,
    bytes calldata conditionProof
) internal returns (bool);

function _executeActions(
    address vault,
    bytes32 actionsHash,
    bytes calldata actionsProof
) internal returns (bool);

function _distributeReward(
    address vault,
    address executor,
    uint256 reward,
    uint256 gasUsed
) internal;
```

**Execution Flow**:
1. Validate executor is registered and not blacklisted
2. Validate task is executable (not paused, not expired, not max executions)
3. Verify seed commitment (prevent unauthorized execution)
4. Check condition (via ConditionOracle)
5. Execute actions (via ActionAdapters through vault)
6. Calculate reward + gas reimbursement
7. Release payment from vault
8. Update task execution count
9. Emit events

**Size Estimate**: ~250 lines

---

### 5. ConditionOracle.sol

**Purpose**: Verify execution conditions are met

**Supported Conditions**:
```solidity
enum ConditionType {
    ALWAYS,              // No condition
    TIME_AFTER,          // block.timestamp >= target
    PRICE_ABOVE,         // Chainlink price >= target
    PRICE_BELOW,         // Chainlink price <= target
    BALANCE_ABOVE,       // Account balance >= target
    BALANCE_BELOW,       // Account balance <= target
    CUSTOM_ORACLE,       // External oracle with standard interface
    MULTI_AND,           // All sub-conditions true
    MULTI_OR             // Any sub-condition true
}

struct Condition {
    ConditionType conditionType;
    bytes params; // ABI-encoded condition-specific params
}
```

**Key Functions**:
```solidity
function checkCondition(
    Condition calldata condition
) external view returns (bool isMet, string memory reason);

function verifyConditionWithProof(
    bytes32 conditionHash,
    bytes calldata proof
) external view returns (bool);

// Chainlink integration
function setPriceFeed(address token, address feed) external onlyOwner;
function getLatestPrice(address token) external view returns (uint256);

// Custom oracle
function registerOracle(address oracle) external onlyOwner;
function isOracleApproved(address oracle) external view returns (bool);
```

**Security**:
- All oracle calls are view/staticcall (no state changes)
- Gas limits on external calls
- Stale price validation (Chainlink)
- Whitelisted custom oracles only

**Size Estimate**: ~200 lines

---

### 6. ActionRegistry.sol

**Purpose**: Manage approved action adapters

**State Variables**:
```solidity
struct AdapterInfo {
    address adapter;
    bool isActive;
    uint256 gasLimit;          // Max gas for this adapter
    bool requiresTokens;       // Whether adapter needs token approval
    address[] supportedTokens; // Tokens this adapter works with
}

mapping(bytes4 => AdapterInfo) public adapters; // selector => adapter
mapping(address => bool) public approvedProtocols; // e.g., Uniswap router
```

**Key Functions**:
```solidity
function registerAdapter(
    bytes4 selector,
    address adapter,
    uint256 gasLimit,
    bool requiresTokens
) external onlyOwner;

function getAdapter(bytes4 selector) external view returns (AdapterInfo memory);

function approveProtocol(address protocol) external onlyOwner;

function isActionAllowed(bytes4 selector, address protocol) external view returns (bool);
```

**Size Estimate**: ~150 lines

---

### 7. UniswapV2Adapter.sol (Rewritten)

**Purpose**: Execute limit order swaps via Uniswap V2

**Key Differences from Current**:
- **Pulls tokens from TaskVault**, not creator
- **Vault pre-approves adapter** when task created
- **Slippage protection** enforced
- **Failed swap returns tokens to vault**

**Function**:
```solidity
function execute(
    address vault,
    bytes calldata params
) external onlyActionRegistry returns (bool success, bytes memory result);

struct SwapParams {
    address router;
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    address recipient;    // Where to send output tokens
}
```

**Execution Flow**:
1. Decode params
2. Validate router is approved
3. Pull tokens from vault (vault calls this adapter)
4. Check current price via router.getAmountsOut()
5. If price condition not met, return false + tokens to vault
6. Approve router
7. Execute swap
8. If swap fails, return tokens to vault
9. If swap succeeds, send output tokens to recipient

**Size Estimate**: ~200 lines

---

### 8. ExecutorHub.sol

**Purpose**: Manage executor lifecycle and coordination

**State Variables**:
```solidity
struct Executor {
    address addr;
    uint256 stakedAmount;      // TASK tokens staked
    uint256 registeredAt;
    uint256 totalExecutions;
    uint256 successfulExecutions;
    uint256 failedExecutions;
    uint256 reputationScore;   // 0-10000
    bool isActive;
    bool isSlashed;
}

mapping(address => Executor) public executors;

// Execution locks (prevent double-execution)
mapping(uint256 => ExecutionLock) public taskLocks;

struct ExecutionLock {
    address executor;
    uint256 lockedAt;
    bytes32 commitment;  // commit-reveal for fairness
}

uint256 public minStakeAmount;
uint256 public lockDuration;
```

**Key Functions**:
```solidity
function registerExecutor(uint256 stakeAmount) external;
function unregisterExecutor() external;
function addStake(uint256 amount) external;
function withdrawStake(uint256 amount) external;

function requestExecution(uint256 taskId, bytes32 commitment) external returns (bool locked);
function executeTask(uint256 taskId, bytes32 reveal, ...) external;

function recordExecution(uint256 taskId, address executor, bool success, uint256 gasUsed) external onlyTaskLogic;

function slashExecutor(address executor, uint256 amount, string calldata reason) external onlyOwner;
```

**Execution Coordination**:
1. Executor calls `requestExecution(taskId, commit(nonce))` → locks task
2. Wait 1 block for commit to be mined
3. Executor calls `executeTask(taskId, reveal(nonce), ...)`
4. TaskLogic validates reveal matches commitment
5. If valid, execution proceeds

**Size Estimate**: ~250 lines

---

### 9. RewardManager.sol

**Purpose**: Calculate and distribute rewards

**Key Functions**:
```solidity
function calculateReward(
    uint256 baseReward,
    address executor,
    uint256 gasUsed
) external view returns (
    uint256 executorReward,
    uint256 platformFee,
    uint256 gasReimbursement
);

function distributeReward(
    address vault,
    address executor,
    uint256 baseReward,
    uint256 gasUsed
) external onlyTaskLogic;

// Platform fees
function collectFees(address recipient) external onlyOwner;

// TASK token rewards
function mintExecutorRewards(address executor, uint256 tier) external onlyExecutorHub;
```

**Reward Calculation**:
```
executorReward = baseReward * reputationMultiplier
gasReimbursement = gasUsed * tx.gasprice * 1.2 (20% buffer)
platformFee = baseReward * platformFeeRate
totalFromVault = executorReward + gasReimbursement + platformFee
```

**Size Estimate**: ~200 lines

---

## Security Model

### Access Control Hierarchy

```
┌──────────────────────────────────────────┐
│  Multi-Sig Admin (Timelock)              │
│  - Upgrade contracts                     │
│  - Set system parameters                 │
│  - Emergency pause                       │
└────────────┬─────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────┐
│  Protocol Contracts                      │
│  - TaskFactory, ExecutorHub, etc.        │
└────────────┬─────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────┐
│  Task Instances (Creator owns)           │
│  - TaskCore, TaskVault, TaskLogic        │
└────────────┬─────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────┐
│  Executors (Staked + Reputation)         │
│  - Can execute tasks                     │
│  - Earn rewards                          │
└──────────────────────────────────────────┘
```

### Security Measures

#### 1. **Fund Security**
- ✅ Isolated vaults per task (no shared pool)
- ✅ Only TaskLogic can release funds
- ✅ Creator can cancel and withdraw only if task is CANCELLED
- ✅ SafeERC20 for all token operations
- ✅ Reentrancy guards on all fund transfers
- ✅ Pull payment pattern for rewards

#### 2. **Execution Security**
- ✅ Commit-reveal scheme prevents front-running
- ✅ Seed commitment prevents unauthorized execution
- ✅ Task locks prevent double-execution
- ✅ Gas limits on all external calls
- ✅ Validated oracle responses
- ✅ Slippage protection on swaps

#### 3. **Oracle Security**
- ✅ Only approved Chainlink feeds
- ✅ Stale price detection
- ✅ Custom oracles must be whitelisted
- ✅ All oracle calls are view (read-only)
- ✅ Gas-limited external calls

#### 4. **Upgradability**
- ✅ UUPS proxy pattern for core contracts
- ✅ Task instances are NOT upgradeable (immutable once deployed)
- ✅ 48-hour timelock on upgrades
- ✅ Multi-sig required for upgrades

#### 5. **Emergency Controls**
- ✅ Global pause (stops new task creation and execution)
- ✅ Per-task pause (creator can pause their task)
- ✅ Blacklist malicious executors
- ✅ Disable malicious adapters
- ✅ Multi-sig for emergency actions

---

## Gas Optimization Strategies

### 1. **Storage Optimization**

**Pack variables**:
```solidity
// Before (3 slots)
uint256 reward;      // slot 0
address creator;     // slot 1
uint256 createdAt;   // slot 2

// After (2 slots)
uint128 reward;      // slot 0 (left)
uint128 createdAt;   // slot 0 (right)
address creator;     // slot 1
```

**Use mappings instead of arrays**:
```solidity
// Before
uint256[] public taskIds; // Expensive iteration

// After
mapping(uint256 => bool) public taskExists;
// Off-chain: Track task IDs via events
```

**Minimize struct size**:
```solidity
// Store hash of large data, not data itself
bytes32 public actionsHash;  // 32 bytes
// vs
Action[] public actions;     // Unbounded
```

### 2. **Computation Optimization**

**Off-chain indexing**:
- Don't iterate on-chain to find executable tasks
- Use events + subgraph to index tasks
- Front-end queries subgraph, not contract

**Lazy evaluation**:
- Don't check conditions on-chain if price data shows it won't pass
- Off-chain keeper checks condition first, only executes if likely to succeed

**Batch operations**:
```solidity
function batchCreateTasks(TaskParams[] calldata tasks) external {
    // More efficient than multiple transactions
}
```

### 3. **Call Optimization**

**Use interfaces, not low-level calls**:
```solidity
// Before (expensive)
(bool success, bytes memory data) = target.call(abi.encodeWithSignature("foo()"));

// After (cheaper)
ITarget(target).foo();
```

**Minimize external calls**:
```solidity
// Cache external call results
uint256 price = oracle.getPrice(token); // 1 call
// Use price multiple times locally
```

**Use immutable where possible**:
```solidity
address public immutable factory;  // Cheaper than storage
```

### 4. **Event Optimization**

**Index important fields**:
```solidity
event TaskExecuted(
    uint256 indexed taskId,
    address indexed executor,
    bool indexed success,  // Max 3 indexed
    uint256 gasUsed        // Non-indexed
);
```

**Don't emit large structs**:
```solidity
// Before
emit TaskCreated(task); // Expensive

// After
emit TaskCreated(task.id, task.creator, task.reward); // Cheaper
```

### 5. **Gas Estimation**

| Operation | Current | Optimized | Savings |
|-----------|---------|-----------|---------|
| Create Task | ~500k | ~200k | 60% |
| Execute Task | ~300k | ~150k | 50% |
| Cancel Task | ~100k | ~50k | 50% |
| Register Executor | ~150k | ~80k | 47% |

---

## User Flows

### Flow 1: Create Uniswap Limit Order Task

**User Story**: Alice wants to swap 1000 USDC for ETH when ETH price drops to $1800

**Steps**:

1. **Off-chain: Alice prepares parameters**
   ```javascript
   const taskParams = {
       reward: ethers.utils.parseEther("0.01"), // 0.01 ETH per execution
       maxExecutions: 1, // One-time task
       expiresAt: Date.now() + 30 * 24 * 60 * 60, // 30 days
       recurringInterval: 0
   };

   const condition = {
       type: ConditionType.PRICE_BELOW,
       params: encodePriceCondition({
           token: WETH_ADDRESS,
           targetPrice: 1800,
           priceFeed: CHAINLINK_ETH_USD_FEED
       })
   };

   const action = {
       adapter: UNISWAP_ADAPTER,
       params: encodeSwapParams({
           router: UNISWAP_V2_ROUTER,
           tokenIn: USDC_ADDRESS,
           tokenOut: WETH_ADDRESS,
           amountIn: 1000 * 1e6, // 1000 USDC
           minAmountOut: 0.5 * 1e18, // At least 0.5 ETH
           recipient: alice.address
       })
   };
   ```

2. **On-chain: Alice approves USDC and creates task**
   ```solidity
   // Approve factory to pull USDC
   USDC.approve(taskFactory, 1000e6);

   // Create task
   (uint256 taskId, address taskCore, address taskVault) = taskFactory.createTaskWithTokens{
       value: 0.01 ether // Reward
   }(
       taskParams,
       condition,
       [action],
       [TokenDeposit(USDC_ADDRESS, 1000e6)] // Escrow USDC in vault
   );
   ```

3. **Behind the scenes**:
   - TaskFactory deploys TaskCore + TaskVault clones
   - TaskFactory transfers 0.01 ETH (reward) to vault
   - TaskFactory pulls 1000 USDC from Alice → vault
   - Vault approves UniswapAdapter to spend USDC
   - TaskFactory registers task in GlobalRegistry
   - Event emitted: `TaskCreated(taskId, alice, ...)`

4. **Off-chain: Indexer picks up event**
   - Subgraph indexes the new task
   - Executors can now query for executable tasks

### Flow 2: Execute the Task

**User Story**: Bob (executor) sees ETH price hit $1800 and executes Alice's task

**Steps**:

1. **Off-chain: Bob queries executable tasks**
   ```graphql
   query {
       tasks(where: { status: ACTIVE, expiresAt_gt: $now }) {
           id
           reward
           condition
       }
   }
   ```

2. **Off-chain: Bob checks condition locally**
   ```javascript
   const ethPrice = await chainlink.getPrice(WETH);
   if (ethPrice <= 1800) {
       // Condition met! Prepare to execute
   }
   ```

3. **On-chain: Bob commits to execution**
   ```solidity
   // Generate random nonce
   bytes32 nonce = keccak256(abi.encode(block.timestamp, bob.address, taskId));
   bytes32 commitment = keccak256(abi.encode(nonce));

   // Request execution lock
   executorHub.requestExecution(taskId, commitment);
   ```

4. **Wait 1 block for commit to finalize**

5. **On-chain: Bob executes task**
   ```solidity
   executorHub.executeTask(
       taskId,
       nonce, // Reveal
       conditionProof, // Merkle proof of condition params
       actionsProof    // Merkle proof of action params
   );
   ```

6. **Behind the scenes**:
   - ExecutorHub validates Bob is registered and not blacklisted
   - ExecutorHub validates reveal matches commitment
   - ExecutorHub calls TaskLogic.executeTask()
   - TaskLogic validates task is executable
   - TaskLogic calls ConditionOracle.checkCondition(PRICE_BELOW, ETH, 1800)
   - ConditionOracle calls Chainlink → price = $1795 → PASS
   - TaskLogic calls vault.executeTokenAction(USDC, UniswapAdapter, 1000e6, swapParams)
   - Vault pulls 1000 USDC from its balance
   - Vault calls UniswapAdapter.execute(vault, swapParams)
   - UniswapAdapter pulls USDC from vault
   - UniswapAdapter checks Uniswap price: 1000 USDC → 0.526 ETH (> 0.5 min)
   - UniswapAdapter executes swap on Uniswap
   - Uniswap sends 0.526 WETH to Alice
   - UniswapAdapter returns success
   - TaskLogic calls RewardManager.distributeReward(vault, bob, 0.01 ETH, gasUsed)
   - RewardManager calculates: reward = 0.01 ETH * 1.05 (Bob's multiplier) = 0.0105 ETH
   - RewardManager adds gas reimbursement: 0.002 ETH
   - RewardManager deducts platform fee: 0.01 * 0.01 = 0.0001 ETH
   - Total paid to Bob: 0.0105 + 0.002 = 0.0125 ETH
   - Vault sends 0.0125 ETH to Bob
   - TaskCore increments executionCount to 1
   - TaskCore sets status to COMPLETED (maxExecutions = 1)
   - Event emitted: `TaskExecuted(taskId, bob, true, gasUsed, reward)`

7. **Post-execution**:
   - Bob earned 0.0125 ETH
   - Alice got 0.526 WETH for her 1000 USDC at desired price
   - Protocol earned 0.0001 ETH fee
   - Bob's reputation increased

### Flow 3: Cancel Task

**User Story**: Alice changes her mind and cancels the task before execution

**Steps**:

1. **On-chain: Alice cancels**
   ```solidity
   ITaskCore(taskCore).cancel();
   ```

2. **Behind the scenes**:
   - TaskCore validates Alice is creator
   - TaskCore sets status to CANCELLED
   - TaskCore calls vault.withdrawAll()
   - Vault calculates refund: 1000 USDC + 0.01 ETH (unused reward)
   - Vault transfers 1000 USDC → Alice
   - Vault transfers 0.01 ETH → Alice
   - Event emitted: `TaskCancelled(taskId, refundedUSDC, refundedETH)`

---

## Migration Path

### Phase 1: Deploy New Contracts (Week 1-2)

1. Deploy core infrastructure:
   - AccessControl
   - GlobalRegistry
   - ConditionOracle
   - ActionRegistry
   - RewardManager
   - ExecutorHub

2. Deploy implementations:
   - TaskCore implementation
   - TaskVault implementation
   - TaskLogic implementation

3. Deploy factory:
   - TaskFactory (with references to implementations)

4. Deploy adapters:
   - UniswapV2Adapter
   - (Other adapters as needed)

5. Configure system:
   - Register adapters in ActionRegistry
   - Set Chainlink price feeds in ConditionOracle
   - Set platform fees in RewardManager
   - Configure AccessControl roles

### Phase 2: Testing (Week 3-4)

1. Unit tests (100% coverage)
2. Integration tests
3. Testnet deployment
4. Security audit
5. Bug bounty program

### Phase 3: Migration (Week 5-6)

1. Deploy to mainnet
2. Pause old contracts
3. Provide migration tool for users:
   - Cancel old tasks
   - Withdraw funds
   - Recreate tasks on new system
4. Liquidity migration for any protocol-owned liquidity

### Phase 4: Sunset Old Contracts (Week 7-8)

1. Give users 30 days to migrate
2. After 30 days, emergency withdraw any remaining funds to a recovery contract
3. Disable old contracts permanently

---

## Implementation Guidelines

### Development Standards

**1. Use OpenZeppelin libraries**:
```solidity
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
```

**2. Follow CEI pattern** (Checks-Effects-Interactions):
```solidity
function withdraw() external {
    // Checks
    require(balance[msg.sender] > 0, "No balance");

    // Effects
    uint256 amount = balance[msg.sender];
    balance[msg.sender] = 0;

    // Interactions
    (bool success, ) = msg.sender.call{value: amount}("");
    require(success, "Transfer failed");
}
```

**3. Use custom errors** (gas efficient):
```solidity
error InsufficientBalance(uint256 available, uint256 required);

function withdraw(uint256 amount) external {
    if (balance[msg.sender] < amount) {
        revert InsufficientBalance(balance[msg.sender], amount);
    }
    // ...
}
```

**4. Comprehensive NatSpec**:
```solidity
/// @notice Executes a task if conditions are met
/// @dev Validates executor, checks conditions, executes actions, distributes rewards
/// @param taskId The ID of the task to execute
/// @param executor The address of the executor
/// @return success Whether the execution succeeded
/// @return gasUsed The amount of gas consumed
function executeTask(uint256 taskId, address executor)
    external
    returns (bool success, uint256 gasUsed);
```

**5. Thorough testing**:
- Unit tests for each contract (100% coverage)
- Integration tests for user flows
- Fuzzing for edge cases
- Gas benchmarks
- Upgrade tests for proxies

**6. Security practices**:
- Slither static analysis
- Mythril symbolic execution
- Manual audit by 2+ auditors
- Bug bounty before mainnet
- Gradual rollout with caps

### Code Structure

```
contracts/
├── core/
│   ├── TaskFactory.sol
│   ├── TaskCore.sol
│   ├── TaskVault.sol
│   ├── TaskLogic.sol
│   ├── ExecutorHub.sol
│   └── GlobalRegistry.sol
├── support/
│   ├── ConditionOracle.sol
│   ├── ActionRegistry.sol
│   └── RewardManager.sol
├── adapters/
│   ├── UniswapV2Adapter.sol
│   ├── AaveAdapter.sol
│   └── GenericAdapter.sol
├── interfaces/
│   ├── ITaskFactory.sol
│   ├── ITaskCore.sol
│   ├── ITaskVault.sol
│   ├── ITaskLogic.sol
│   ├── IExecutorHub.sol
│   ├── IConditionOracle.sol
│   └── IActionAdapter.sol
├── libraries/
│   ├── TaskLib.sol
│   ├── ConditionLib.sol
│   └── ActionLib.sol
├── utils/
│   ├── AccessControl.sol
│   └── Pausable.sol
└── token/
    └── PlatformToken.sol

test/
├── unit/
│   ├── TaskFactory.test.ts
│   ├── TaskCore.test.ts
│   └── ...
├── integration/
│   ├── CreateAndExecute.test.ts
│   ├── UniswapLimitOrder.test.ts
│   └── ...
└── fuzzing/
    └── TaskExecution.fuzz.ts

scripts/
├── deploy/
│   ├── 01_DeployCore.ts
│   ├── 02_DeploySupport.ts
│   └── 03_DeployAdapters.ts
└── tasks/
    ├── createTask.ts
    └── executeTask.ts
```

---

## Gas Cost Estimates

### Optimized Gas Costs

| Operation | Gas Cost | ETH @ 50 gwei | USD @ $2000 |
|-----------|----------|---------------|-------------|
| **Task Creation** | | | |
| Create basic task | 180,000 | 0.009 | $18 |
| Create task + token escrow | 220,000 | 0.011 | $22 |
| Create recurring task | 200,000 | 0.010 | $20 |
| **Task Execution** | | | |
| Execute (simple condition) | 120,000 | 0.006 | $12 |
| Execute (price oracle) | 150,000 | 0.0075 | $15 |
| Execute + Uniswap swap | 280,000 | 0.014 | $28 |
| **Task Management** | | | |
| Cancel task | 45,000 | 0.00225 | $4.50 |
| Pause/resume | 30,000 | 0.0015 | $3 |
| Update reward | 50,000 | 0.0025 | $5 |
| **Executor Operations** | | | |
| Register executor | 75,000 | 0.00375 | $7.50 |
| Stake tokens | 50,000 | 0.0025 | $5 |
| Claim rewards | 40,000 | 0.002 | $4 |

### Comparison with Current

| Operation | Current | Optimized | Improvement |
|-----------|---------|-----------|-------------|
| Create task | ~500k | ~200k | **60%** |
| Execute task | ~300k | ~150k | **50%** |
| Cancel task | ~100k | ~50k | **50%** |

---

## Security Checklist

### Pre-Deployment

- [ ] All contracts have 100% test coverage
- [ ] Slither shows no high/medium issues
- [ ] Manual audit completed by 2+ auditors
- [ ] All issues from audit resolved
- [ ] Testnet deployment successful
- [ ] Integration tests pass on testnet
- [ ] Gas benchmarks meet targets
- [ ] Emergency pause tested
- [ ] Upgrade mechanism tested
- [ ] Multi-sig configured correctly
- [ ] Timelock configured (48 hours minimum)
- [ ] Access control roles assigned properly

### Post-Deployment

- [ ] Verify all contracts on block explorer
- [ ] Bug bounty program launched
- [ ] Monitoring alerts configured
- [ ] Emergency response plan documented
- [ ] Team multi-sig tested
- [ ] Initial deposit caps set (e.g., max 10 ETH per task)
- [ ] Gradual rollout: whitelisted users first
- [ ] Public documentation published
- [ ] User guide created
- [ ] SDK/API for integration ready

---

## Conclusion

This redesigned architecture addresses all critical vulnerabilities and design flaws in the current system. Key improvements:

### Security
- ✅ Isolated vaults prevent fund mixing
- ✅ Interface-driven design eliminates low-level call risks
- ✅ Proper escrow for both ETH and ERC20 tokens
- ✅ Commit-reveal prevents front-running
- ✅ Gas limits prevent DoS
- ✅ Upgradeable via secure proxy pattern

### Architecture
- ✅ Small, focused contracts (<300 lines each)
- ✅ Factory pattern for scalable task deployment
- ✅ Separation of concerns: metadata, funds, execution
- ✅ Pluggable adapters for protocol integrations
- ✅ Off-chain indexing for gas efficiency

### Gas Efficiency
- ✅ 50-60% reduction in gas costs
- ✅ Storage-optimized structs
- ✅ Minimal on-chain computation
- ✅ Events for off-chain tracking

### User Experience
- ✅ Clear task creation flow
- ✅ Pre-escrowed funds = guaranteed execution
- ✅ Slippage protection on swaps
- ✅ Reputation-based rewards
- ✅ Easy task cancellation

### Next Steps

1. Review this document with team
2. Approve architecture
3. Begin Phase 1 implementation (core contracts)
4. Set up CI/CD with automated tests
5. Deploy to testnet
6. Security audit
7. Mainnet launch

**Estimated Timeline**: 8 weeks from approval to mainnet

**Estimated Audit Cost**: $50k - $100k (2 firms)

**Estimated Deployment Cost**: ~5-10 ETH (including all contract deployments and setup)

---

## Appendix: Example Task Scenarios

### Scenario 1: DCA (Dollar Cost Averaging)

**Goal**: Buy $100 worth of ETH every week for 10 weeks

**Implementation**:
```javascript
const task = {
    reward: 0.005 ETH per execution,
    maxExecutions: 10,
    recurringInterval: 7 days,
    expiresAt: now + 100 days,
    condition: { type: TIME_BASED, interval: 7 days },
    action: {
        adapter: UniswapAdapter,
        params: {
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: 100 * 1e6,
            minAmountOut: 0 (market order),
            recipient: user
        }
    },
    deposits: [{ token: USDC, amount: 1000 * 1e6 }] // 10 x $100
};

const totalCost = 1000 USDC (for swaps) + 0.05 ETH (for rewards);
```

### Scenario 2: Stop-Loss

**Goal**: Sell 10 ETH if price drops below $1500

**Implementation**:
```javascript
const task = {
    reward: 0.01 ETH,
    maxExecutions: 1,
    expiresAt: 0 (no expiry),
    condition: {
        type: PRICE_BELOW,
        params: { token: WETH, targetPrice: 1500, feed: CHAINLINK_ETH_USD }
    },
    action: {
        adapter: UniswapAdapter,
        params: {
            tokenIn: WETH,
            tokenOut: USDC,
            amountIn: 10 * 1e18,
            minAmountOut: 14500 * 1e6, // Min $1450 (3% slippage)
            recipient: user
        }
    },
    deposits: [{ token: WETH, amount: 10 * 1e18 }]
};
```

### Scenario 3: Aave Liquidation Protection

**Goal**: If health factor drops below 1.2, repay debt

**Implementation**:
```javascript
const task = {
    reward: 0.02 ETH,
    maxExecutions: 1,
    condition: {
        type: CUSTOM_ORACLE,
        params: {
            oracle: AaveHealthOracle,
            method: "getHealthFactor(address)",
            threshold: 1.2,
            operator: LESS_THAN
        }
    },
    action: {
        adapter: AaveAdapter,
        params: {
            action: REPAY,
            asset: DAI,
            amount: 5000 * 1e18,
            onBehalfOf: user
        }
    },
    deposits: [{ token: DAI, amount: 5000 * 1e18 }]
};
```

### Scenario 4: Yield Harvesting

**Goal**: Claim and compound Compound rewards daily

**Implementation**:
```javascript
const task = {
    reward: 0.003 ETH per execution,
    maxExecutions: 365, // 1 year
    recurringInterval: 1 day,
    condition: { type: TIME_BASED },
    actions: [
        {
            adapter: CompoundAdapter,
            params: { action: CLAIM_COMP, recipient: vault }
        },
        {
            adapter: UniswapAdapter,
            params: {
                tokenIn: COMP,
                tokenOut: USDC,
                amountIn: balance, // Dynamic
                recipient: vault
            }
        },
        {
            adapter: CompoundAdapter,
            params: { action: SUPPLY, asset: USDC, amount: balance }
        }
    ],
    deposits: [] // No upfront deposit needed
};
```

---

## Document Version

- **Version**: 1.0
- **Date**: 2025-01-15
- **Author**: TaskerOnchain Development Team
- **Status**: Proposed Architecture
- **Next Review**: After team feedback

---

**END OF DOCUMENT**
