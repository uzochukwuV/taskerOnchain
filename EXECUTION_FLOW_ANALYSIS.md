# TaskerOnchain Execution Flow Analysis

This document provides detailed execution flow diagrams and state transition analysis for the TaskerOnchain protocol, including vulnerable paths identified during the audit.

---

## Table of Contents
1. [Normal Execution Flow](#normal-execution-flow)
2. [Task Creation Flow](#task-creation-flow)
3. [Task Execution Flow](#task-execution-flow)
4. [Reward Distribution Flow](#reward-distribution-flow)
5. [Token Action Execution Flow](#token-action-execution-flow)
6. [Vulnerable Execution Paths](#vulnerable-execution-paths)
7. [State Transition Diagrams](#state-transition-diagrams)

---

## Normal Execution Flow

### Overview
```
┌──────────┐
│   User   │
└────┬─────┘
     │ 1. createTask()
     v
┌─────────────────┐
│  TaskFactory    │
│  - Validate     │
│  - Deploy Core  │
│  - Deploy Vault │
│  - Fund Vault   │
└────┬────────────┘
     │ 2. Task Created
     │
     v
┌─────────────────┐     ┌──────────────┐
│   TaskCore      │────▶│  TaskVault   │
│  - Metadata     │     │  - Funds     │
│  - Lifecycle    │     │  - Isolated  │
└─────────────────┘     └──────────────┘
     │
     │ 3. registerTask()
     v
┌─────────────────┐
│ GlobalRegistry  │
│  - Index tasks  │
└─────────────────┘
     │
     │ 4. executeTask()
     v
┌──────────────┐
│ ExecutorHub  │ ─────▶ Anyone can execute (testnet)
└──────┬───────┘
       │ 5. executeTask()
       v
┌────────────────────┐
│   TaskLogicV2      │
│  - Verify proofs   │
│  - Execute actions │
│  - Distribute $$   │
└──────┬─────────────┘
       │ 6. executeTokenAction()
       v
┌──────────────┐      ┌────────────────┐
│  TaskVault   │─────▶│    Adapter     │
│  - Approve   │      │  - Uniswap     │
│  - Call      │      │  - Aave, etc   │
└──────┬───────┘      └────────────────┘
       │
       │ 7. distributeReward()
       v
┌────────────────┐
│ RewardManager  │
│  - Calculate   │
│  - Pay executor│
│  - Take fees   │
└────────────────┘
```

---

## Task Creation Flow

### Detailed Steps

```solidity
// Step-by-step execution trace

1. User calls TaskFactory.createTask()
   └─▶ Input: TaskParams, ActionParams[], ETH value

2. TaskFactory._validateTaskParams()
   ├─▶ Check: rewardPerExecution >= minTaskReward
   ├─▶ Check: expiresAt is valid
   ├─▶ Check: actions.length between 1-10
   └─▶ ⚠️  BUG: No validation for fees + gas + multipliers

3. TaskFactory calculates totalReward
   ├─▶ if maxExecutions == 0:
   │   └─▶ totalReward = rewardPerExecution (ONLY 1 execution!)
   │       ⚠️  BUG: Unlimited tasks underfunded
   └─▶ else:
       └─▶ totalReward = rewardPerExecution * maxExecutions

4. TaskFactory checks funding
   ├─▶ providedValue = msg.value - creationFee
   ├─▶ require(providedValue >= totalReward)
   └─▶ ⚠️  BUG: Doesn't account for fees/gas/multipliers

5. TaskFactory deploys TaskCore (minimal proxy)
   └─▶ taskCore = taskCoreImplementation.clone()

6. TaskFactory deploys TaskVault (minimal proxy)
   └─▶ taskVault = taskVaultImplementation.clone()

7. TaskFactory initializes TaskCore
   ├─▶ TaskCore.initialize(taskId, creator, vault, logic, metadata)
   └─▶ Sets: initialized = true, status = ACTIVE

8. TaskFactory initializes TaskVault
   └─▶ TaskVault.initialize(taskCore, creator, rewardManager)

9. TaskFactory funds TaskVault
   ├─▶ TaskVault.depositNative{value: providedValue}()
   └─▶ nativeBalance += providedValue

10. TaskFactory deposits ERC20 tokens (if provided)
    ├─▶ For each deposit:
    │   ├─▶ Pull tokens from user
    │   ├─▶ Approve vault
    │   ├─▶ TaskVault.depositToken()
    │   └─▶ Clear approval
    └─▶ tokenBalances[token] += amount

11. TaskFactory stores task info
    └─▶ tasks[taskId] = DeployedTask{...}

12. TaskFactory registers with GlobalRegistry
    ├─▶ GlobalRegistry.registerTask()
    └─▶ Updates indices: tasksByCreator, tasksByStatus, allTaskIds

13. Emit TaskCreated event
    └─▶ Event: TaskCreated(taskId, creator, taskCore, taskVault, ...)

RESULT: Task is created and ready for execution
```

### State After Creation

```
TaskCore State:
  ├─ initialized: true
  ├─ taskId: <unique ID>
  ├─ creator: <user address>
  ├─ vault: <vault address>
  ├─ logic: <logic address>
  └─ metadata:
      ├─ status: ACTIVE
      ├─ createdAt: <timestamp>
      ├─ expiresAt: <timestamp or 0>
      ├─ maxExecutions: <count or 0 for unlimited>
      ├─ executionCount: 0
      ├─ lastExecutionTime: 0
      ├─ recurringInterval: <seconds or 0>
      ├─ rewardPerExecution: <ETH amount>
      ├─ actionsHash: <keccak256 of actions>
      └─ seedCommitment: <commitment or 0>

TaskVault State:
  ├─ initialized: true
  ├─ taskCore: <core address>
  ├─ creator: <user address>
  ├─ rewardManager: <manager address>
  ├─ taskLogic: <logic address>
  ├─ nativeBalance: <ETH deposited>
  ├─ nativeReserved: 0
  ├─ tokenBalances: {token => amount}
  └─ tokenReserved: {token => 0}

GlobalRegistry State:
  ├─ tasks[taskId]: TaskInfo{...}
  ├─ tasksByCreator[creator]: [..., taskId]
  ├─ tasksByStatus[ACTIVE]: [..., taskId]
  └─ allTaskIds: [..., taskId]
```

---

## Task Execution Flow

### Normal Execution Path

```
┌─────────────────────────────────────────────────────────┐
│ Phase 1: Execution Request                              │
└─────────────────────────────────────────────────────────┘

Executor calls ExecutorHub.executeTask(taskId, actionsProof)
  ├─▶ Check: isRegistered? (TESTNET: NO CHECK)
  ├─▶ Check: isBlacklisted? (TESTNET: NO CHECK)
  └─▶ Create ExecutionParams:
      ├─ taskId
      ├─ executor
      ├─ seed: bytes32(0) (TESTNET: no commit-reveal)
      └─ actionsProof

┌─────────────────────────────────────────────────────────┐
│ Phase 2: Execution Validation                           │
└─────────────────────────────────────────────────────────┘

ExecutorHub → TaskLogicV2.executeTask(params)
  ├─▶ Modifier: onlyExecutorHub ✓
  ├─▶ Modifier: whenNotPaused ✓
  ├─▶ Modifier: nonReentrant ✓
  └─▶ Record startGas = gasleft()

TaskLogicV2._loadTask(taskId)
  ├─▶ Call: taskRegistry.getTaskAddresses(taskId)
  ├─▶ Return: (taskCore, taskVault)
  └─▶ Validate: taskCore != address(0)

TaskLogicV2 gets metadata
  └─▶ ITaskCore(taskCore).getMetadata()

TaskLogicV2 verifies seed commitment (if any)
  ├─▶ if metadata.seedCommitment != bytes32(0):
  │   ├─▶ providedCommitment = keccak256(abi.encode(params.seed))
  │   └─▶ require(providedCommitment == metadata.seedCommitment)
  └─▶ else: skip

┌─────────────────────────────────────────────────────────┐
│ Phase 3: Task State Update                              │
└─────────────────────────────────────────────────────────┘

TaskLogicV2 → TaskCore.executeTask(executor)
  ├─▶ Modifier: onlyLogic ✓
  ├─▶ Check: metadata.status == ACTIVE
  ├─▶ Check: isExecutable() returns true
  │   ├─▶ Check: status == ACTIVE
  │   ├─▶ Check: not expired
  │   ├─▶ Check: not reached maxExecutions
  │   └─▶ Check: recurringInterval satisfied
  ├─▶ Update: metadata.status = EXECUTING
  └─▶ Emit: TaskStatusChanged(ACTIVE → EXECUTING)

┌─────────────────────────────────────────────────────────┐
│ Phase 4: Action Verification & Execution                │
└─────────────────────────────────────────────────────────┘

TaskLogicV2._verifyAndExecuteActions(vault, actionsHash, actionsProof)
  │
  ├─▶ Decode: (actions, merkleProof) = abi.decode(actionsProof)
  │
  ├─▶ if merkleProof.length > 0:
  │   │   // Multiple actions
  │   ├─▶ Build leaves array
  │   ├─▶ Compute merkle root
  │   ├─▶ Verify: merkleProof.verify(actionsHash, computedRoot)
  │   └─▶ if invalid: revert ActionsFailed
  │
  └─▶ else:
      │   // Single action
      ├─▶ computedHash = keccak256(abi.encode(actions))
      └─▶ if computedHash != actionsHash: revert ActionsFailed

For each action in actions:
  └─▶ TaskLogicV2._executeAction(vault, action)
      │
      ├─▶ Get adapter from ActionRegistry
      │   └─▶ adapterInfo = registry.getAdapter(action.selector)
      │
      ├─▶ Check: adapterInfo.isActive
      ├─▶ Check: protocol is approved
      │
      ├─▶ Get token requirements
      │   └─▶ (tokens, amounts) = adapter.getTokenRequirements(params)
      │
      └─▶ Execute via vault
          └─▶ TaskVault.executeTokenAction(token, adapter, amount, actionData)

┌─────────────────────────────────────────────────────────┐
│ Phase 5: Vault Token Action (VULNERABLE PATH)           │
└─────────────────────────────────────────────────────────┘

TaskVault.executeTokenAction(token, adapter, amount, actionData)
  ├─▶ Modifier: onlyTaskLogic ✓
  ├─▶ Modifier: nonReentrant ✓
  │
  ├─▶ Check: tokenBalances[token] >= amount
  │
  ├─▶ ⚠️  UPDATE STATE BEFORE EXTERNAL CALL:
  │   ├─▶ tokenBalances[token] -= amount
  │   └─▶ tokenReserved[token] += amount
  │
  ├─▶ Approve adapter
  │   └─▶ IERC20(token).approve(adapter, amount)
  │
  ├─▶ ⚠️  EXTERNAL CALL TO ADAPTER:
  │   └─▶ (bool callSuccess, bytes returnData) = adapter.call(actionData)
  │       │
  │       └─▶ Adapter can:
  │           ├─▶ Pull tokens via transferFrom(vault, ...)
  │           ├─▶ Execute action (swap, deposit, etc.)
  │           └─▶ Return (success, result)
  │
  ├─▶ Decode response
  │   └─▶ (success, result) = abi.decode(returnData, (bool, bytes))
  │
  ├─▶ Clear approval
  │   └─▶ IERC20(token).approve(adapter, 0)
  │
  ├─▶ Unreserve tokens
  │   └─▶ tokenReserved[token] -= amount
  │
  └─▶ ⚠️  BUG: Token recovery logic (lines 169-178)
      │
      ├─▶ if success == false:
      │   │
      │   ├─▶ currentBalance = IERC20(token).balanceOf(address(this))
      │   ├─▶ expectedBalance = tokenBalances[token] + tokenReserved[token]
      │   │
      │   └─▶ if currentBalance > expectedBalance:
      │       └─▶ tokenBalances[token] += (currentBalance - expectedBalance)
      │
      └─▶ ⚠️  VULNERABILITY:
          If adapter pulls tokens but returns false:
          ├─▶ currentBalance = original - amount (adapter kept tokens)
          ├─▶ expectedBalance = (original - amount) + 0 = original - amount
          ├─▶ currentBalance > expectedBalance? NO
          └─▶ No recovery! Tokens lost permanently.

┌─────────────────────────────────────────────────────────┐
│ Phase 6: Reward Distribution (VULNERABLE PATH)          │
└─────────────────────────────────────────────────────────┘

TaskLogicV2 calculates gas
  └─▶ gasUsed = startGas - gasleft()
      ⚠️  NOTE: Doesn't include reward distribution gas

TaskLogicV2._distributeReward(vault, executor, baseReward, gasUsed)
  │
  └─▶ RewardManager.distributeReward(vault, executor, baseReward, gasUsed)
      │
      ├─▶ Calculate reward breakdown:
      │   ├─▶ multiplier = getReputationMultiplier(executor)
      │   │   └─▶ Range: 10000 (100%) to 12500 (125%)
      │   │
      │   ├─▶ executorReward = (baseReward * multiplier) / 10000
      │   │   ⚠️  Can be 125% of baseReward!
      │   │
      │   ├─▶ platformFee = (baseReward * 100) / 10000
      │   │   └─▶ 1% of baseReward
      │   │
      │   └─▶ gasReimbursement = (gasUsed * tx.gasprice * 120) / 100
      │       └─▶ 120% of gas cost
      │
      ├─▶ totalFromVault = executorReward + platformFee + gasReimbursement
      │
      ├─▶ ⚠️  Check vault balance:
      │   ├─▶ available = TaskVault.getAvailableForRewards()
      │   │   └─▶ returns: nativeBalance - nativeReserved
      │   │
      │   └─▶ if available < totalFromVault:
      │       └─▶ revert InsufficientVaultBalance
      │           ⚠️  THIS IS WHERE UNDERFUNDED TASKS FAIL!
      │
      ├─▶ Release executor reward + gas:
      │   └─▶ TaskVault.releaseReward(executor, executorTotal)
      │       │
      │       ├─▶ Check: nativeBalance >= amount
      │       ├─▶ nativeBalance -= amount
      │       ├─▶ nativeReserved += amount
      │       │
      │       ├─▶ ⚠️  UNSAFE ETH TRANSFER:
      │       │   └─▶ (bool success, ) = executor.call{value: amount}("")
      │       │       └─▶ Unbounded gas, can be griefed!
      │       │
      │       └─▶ nativeReserved -= amount
      │
      └─▶ Release platform fee:
          └─▶ TaskVault.releaseReward(address(this), platformFee)

┌─────────────────────────────────────────────────────────┐
│ Phase 7: Task Completion                                │
└─────────────────────────────────────────────────────────┘

TaskLogicV2 → TaskCore.completeExecution(true)
  ├─▶ Modifier: onlyLogic ✓
  ├─▶ Check: metadata.status == EXECUTING
  │
  ├─▶ Update execution counts:
  │   ├─▶ metadata.executionCount++
  │   └─▶ metadata.lastExecutionTime = block.timestamp
  │
  ├─▶ Check if task completed:
  │   └─▶ if maxExecutions > 0 && executionCount >= maxExecutions:
  │       └─▶ _setStatus(COMPLETED)
  │           ⚠️  Funds locked forever, no refund mechanism!
  │
  └─▶ else:
      └─▶ _setStatus(ACTIVE)

TaskLogicV2 returns ExecutionResult
  └─▶ result = {success: true, gasUsed, rewardPaid}

ExecutorHub updates executor stats (if registered)
  ├─▶ executor.totalExecutions++
  ├─▶ executor.successfulExecutions++
  └─▶ _updateReputation(executor, true)

Emit ExecutionCompleted event
  └─▶ Event: ExecutionCompleted(taskId, executor, success)

RESULT: Task executed successfully
```

---

## Vulnerable Execution Paths

### Path 1: Insufficient Funding Attack

```
ATTACKER STRATEGY: Build high reputation, drain underfunded tasks

[Task Creation Phase]
Victim creates task:
  ├─ rewardPerExecution: 1 ETH
  ├─ maxExecutions: 10
  └─ Funds: 10 ETH (victim thinks this is enough)

Factory validation:
  ├─ totalReward = 1 ETH * 10 = 10 ETH
  ├─ providedValue = 10 ETH - 0 (no creation fee) = 10 ETH
  ├─ 10 ETH >= 10 ETH ✓ PASSES
  └─ ⚠️  BUG: Doesn't check for fees + gas + multipliers

[Reputation Building Phase]
Attacker executes 500+ tasks successfully:
  └─▶ reputationScore: 10000 (max)
  └─▶ multiplier: 12500 (125%)

[Attack Phase]
Attacker executes victim's task:

Execution 1:
  ├─ baseReward: 1 ETH
  ├─ executorReward: 1 ETH * 1.25 = 1.25 ETH
  ├─ platformFee: 1 ETH * 0.01 = 0.01 ETH
  ├─ gasReimbursement: ~0.1 ETH (estimated)
  ├─ totalFromVault: 1.36 ETH
  ├─ Vault balance: 10 ETH → 8.64 ETH ✓
  └─ Result: SUCCESS

Execution 2-7: Same pattern
  └─▶ Vault balance decreases by ~1.36 ETH each time

Execution 7:
  ├─ Vault balance before: ~0.48 ETH
  ├─ totalFromVault: 1.36 ETH
  ├─ available < totalFromVault
  └─ Result: REVERT("InsufficientVaultBalance")

[Impact]
  ├─ Task completed only 7/10 executions
  ├─ Victim paid for 10 but got 7
  ├─ Remaining 0.48 ETH locked in vault
  └─ No refund mechanism available

RESULT: Victim loses 3 execution slots + 0.48 ETH locked
```

### Path 2: Token Recovery Bug Exploit

```
ATTACKER STRATEGY: Deploy malicious adapter to steal tokens

[Setup Phase]
Attacker deploys MaliciousAdapter:

contract MaliciousAdapter {
    function execute(address vault, bytes calldata params) external
        returns (bool, bytes memory)
    {
        (address token, uint256 amount) = abi.decode(params, (address, uint256));

        // ATTACK: Pull tokens from vault
        IERC20(token).transferFrom(vault, attacker, amount);

        // ATTACK: Return false (pretend failure)
        return (false, "Operation failed");
    }
}

Attacker registers adapter (via compromised owner OR exploits existing adapter):
  └─▶ ActionRegistry.registerAdapter(selector, maliciousAdapter, ...)

[Task Creation Phase]
Victim creates task:
  ├─ Actions: Use malicious adapter
  ├─ Deposits: 10,000 USDC
  └─ Task created successfully

Vault state:
  ├─ tokenBalances[USDC]: 10,000
  ├─ Actual balance: 10,000 USDC
  └─ tokenReserved[USDC]: 0

[Attack Phase]
Attacker executes task:

TaskVault.executeTokenAction(USDC, maliciousAdapter, 1000, ...)
  │
  ├─ Line 141: tokenBalances[USDC] -= 1000 → 9,000
  ├─ Line 142: tokenReserved[USDC] += 1000 → 1,000
  │
  ├─ Line 145: Approve malicious adapter for 1000 USDC
  │
  ├─ Line 148: adapter.call(actionData)
  │   │
  │   └─▶ MaliciousAdapter.execute():
  │       ├─▶ transferFrom(vault, attacker, 1000) ✓
  │       │   └─▶ Vault actual balance: 10,000 → 9,000 USDC
  │       │       Attacker balance: 0 → 1,000 USDC
  │       │
  │       └─▶ return (false, "Failed")
  │
  ├─ Line 151: success = false (decoded)
  │
  ├─ Line 163: IERC20(USDC).approve(adapter, 0) ✓
  │
  ├─ Line 166: tokenReserved[USDC] -= 1000 → 0
  │
  └─ Line 169: success == false, enter recovery logic:
      │
      ├─ Line 171: currentBalance = IERC20(USDC).balanceOf(vault)
      │             = 9,000 USDC (actual balance)
      │
      ├─ Line 172: expectedBalance = tokenBalances[USDC] + tokenReserved[USDC]
      │             = 9,000 + 0 = 9,000 USDC
      │
      ├─ Line 174: if (9,000 > 9,000) ? NO
      │
      └─ ⚠️  NO RECOVERY PERFORMED!

[Result]
Vault state after attack:
  ├─ tokenBalances[USDC]: 9,000 (internal accounting)
  ├─ Actual balance: 9,000 USDC (actual balance)
  ├─ Missing: 1,000 USDC (stolen by attacker)
  └─ ⚠️  Vault thinks it has 9,000 available, but lost 1,000

Attacker can repeat:
  └─▶ Each execution steals 1,000 USDC
  └─▶ After 10 executions: 10,000 USDC stolen

RESULT: Vault loses all tokens to malicious adapter
```

### Path 3: Unlimited Execution Underfunding

```
ATTACKER STRATEGY: N/A (victim self-inflicted)

[Task Creation Phase]
Victim creates unlimited recurring task:
  ├─ rewardPerExecution: 1 ETH
  ├─ maxExecutions: 0 (unlimited!)
  ├─ recurringInterval: 1 day
  ├─ expiresAt: now + 365 days
  └─ Funds: 1 ETH (victim expects many executions)

Factory validation:
  ├─ Line 114: totalReward = maxExecutions == 0 ? rewardPerExecution : ...
  │            = 1 ETH (ONLY 1 execution worth!)
  │
  ├─ Line 119: require(providedValue >= totalReward)
  │            require(1 ETH >= 1 ETH) ✓ PASSES
  │
  └─ ⚠️  BUG: Task funded for 1 execution but can run unlimited times

[Execution Phase]
Day 1 - First execution:
  ├─ Check: isExecutable()
  │   ├─ maxExecutions == 0, no limit check
  │   ├─ recurringInterval satisfied (first run)
  │   └─ Returns: true ✓
  │
  ├─ Execute action
  ├─ Distribute reward: ~1.36 ETH (with fees/gas/multiplier)
  ├─ Vault balance: 1 ETH → ~-0.36 ETH (insufficient!)
  └─ Result: SUCCESS (barely)

Day 2 - Second execution:
  ├─ Check: isExecutable()
  │   ├─ status: ACTIVE ✓
  │   ├─ expiresAt: not expired ✓
  │   ├─ maxExecutions: 0 (no limit) ✓
  │   ├─ recurringInterval: 1 day passed ✓
  │   └─ Returns: true ✓ (MISLEADING!)
  │
  ├─ TaskLogic.executeTask() called
  ├─ RewardManager.distributeReward()
  │   ├─ available = vault.getAvailableForRewards() = ~0 ETH
  │   ├─ totalFromVault = ~1.36 ETH
  │   ├─ available < totalFromVault
  │   └─ revert("InsufficientVaultBalance") ❌
  │
  └─ Result: EXECUTION FAILS

[Impact]
Task state:
  ├─ status: ACTIVE (still shows as active!)
  ├─ isExecutable(): true (still shows as executable!)
  ├─ executionCount: 1
  ├─ Vault balance: ~0 ETH
  └─ ⚠️  Task looks executable but always fails

Victim cannot:
  ├─ Cancel (not in PAUSED status)
  ├─ Recover funds (no refund for ACTIVE tasks)
  └─ Add more funds (no mechanism)

RESULT: Task permanently broken after 1 execution
        Victim paid for unlimited recurring task but got only 1 execution
```

---

## State Transition Diagrams

### TaskStatus State Machine

```
                    ┌─────────────────┐
                    │    CREATED      │
                    └────────┬────────┘
                             │
                             │ initialize()
                             v
                    ┌─────────────────┐
          ┌────────▶│     ACTIVE      │◀──────────┐
          │         └────┬───┬────┬───┘           │
          │              │   │    │               │
          │   pause()    │   │    │ resume()      │
          │              │   │    │               │
          │              v   │    v               │
    ┌─────┴──────┐          │   ┌──────────┐     │
    │   PAUSED   │          │   │EXECUTING │     │
    └─────┬──────┘          │   └────┬─────┘     │
          │                 │        │            │
          │ cancel()        │        │ complete   │
          │                 │        │            │
          │                 │        └────────────┘
          │                 │
          │                 │ cancel()
          │                 │
          │                 v
          │        ┌────────────────┐
          └───────▶│   CANCELLED    │
                   └────────────────┘
                             ▲
                             │
                             │ expires
                             │
                    ┌────────┴────────┐
                    │    EXPIRED      │
                    └─────────────────┘
                             ▲
                             │
                             │ maxExecutions reached
                             │
                    ┌────────┴────────┐
                    │   COMPLETED     │
                    └─────────────────┘

State Transitions:
- ACTIVE → EXECUTING: executeTask() called
- EXECUTING → ACTIVE: execution completes (success or failure)
- EXECUTING → COMPLETED: execution completes AND maxExecutions reached
- ACTIVE → PAUSED: pause() called by creator
- PAUSED → ACTIVE: resume() called by creator
- ACTIVE → CANCELLED: cancel() called by creator
- PAUSED → CANCELLED: cancel() called by creator
- ACTIVE → EXPIRED: block.timestamp > expiresAt (implicit)

⚠️  VULNERABILITIES:
1. No automatic transition to EXPIRED (must be manually checked)
2. COMPLETED/EXPIRED tasks have no refund mechanism
3. ACTIVE tasks can fail execution but remain ACTIVE
```

### Vault Balance State Machine

```
                    ┌──────────────────┐
                    │  Initial State   │
                    │  balance: 0      │
                    │  reserved: 0     │
                    └────────┬─────────┘
                             │
                             │ depositNative()
                             │ depositToken()
                             v
                    ┌──────────────────┐
          ┌────────▶│   Funded State   │
          │         │  balance: X      │◀────────┐
          │         │  reserved: 0     │         │
          │         └────────┬─────────┘         │
          │                  │                   │
          │                  │ executeTokenAction()
          │                  v                   │
          │         ┌──────────────────┐         │
          │         │ Reserved State   │         │
          │         │  balance: X-A    │         │
          │         │  reserved: A     │         │
          │         └────────┬─────────┘         │
          │                  │                   │
          │                  │ adapter.call()    │
          │                  │                   │
          │         ┌────────┴─────────┐         │
          │         │                  │         │
          │         v                  v         │
          │  ┌──────────┐      ┌──────────┐     │
          │  │ Success  │      │  Failure │     │
          │  │ balance: │      │ balance: │     │
          │  │  X-A     │      │  X-A     │     │
          │  │ reserved:│      │ reserved:│     │
          │  │   0      │      │   0      │     │
          │  └────┬─────┘      └────┬─────┘     │
          │       │                 │            │
          │       │                 │ recovery   │
          │       │                 │ (BUGGY!)   │
          │       │                 │            │
          │       └─────────┬───────┘            │
          │                 │                    │
          │                 v                    │
          │         ┌──────────────────┐         │
          │         │ Available State  │         │
          │         │  balance: X-A    │         │
          │         │  reserved: 0     │         │
          │         │  available: X-A  │         │
          │         └────────┬─────────┘         │
          │                  │                   │
          │                  │ releaseReward()   │
          │                  v                   │
          │         ┌──────────────────┐         │
          └─────────│  Updated State   │─────────┘
                    │  balance: X-A-R  │
                    │  reserved: 0     │
                    └──────────────────┘

⚠️  VULNERABLE TRANSITION:
Reserved State → Failure → Available State

If adapter pulls tokens but returns false:
  ├─ Reserved State: balance=X-A, reserved=A, actual=X-A
  ├─ After adapter call: balance=X-A, reserved=A, actual=X-A-A (adapter kept A tokens)
  ├─ Unreserve: balance=X-A, reserved=0, actual=X-A-A
  ├─ Recovery check:
  │   ├─ currentBalance = X-A-A (actual balance)
  │   ├─ expectedBalance = (X-A) + 0 = X-A
  │   ├─ currentBalance > expectedBalance? (X-A-A > X-A)? NO
  │   └─ No recovery performed
  └─ RESULT: A tokens lost permanently!
```

---

## Execution Metrics

### Gas Consumption Analysis

```
Operation                           | Gas Cost (estimated)
------------------------------------|---------------------
TaskFactory.createTask()            | 500,000 - 800,000
  - Deploy TaskCore (proxy)         |   45,000
  - Deploy TaskVault (proxy)        |   45,000
  - Initialize TaskCore             |   80,000
  - Initialize TaskVault            |   60,000
  - Fund vault                      |   30,000
  - Register with GlobalRegistry    |  200,000
  - Other overhead                  |   40,000

ExecutorHub.executeTask()           | 300,000 - 2,000,000 (varies)
  - Validation                      |   10,000
  - Call TaskLogic                  |  290,000+

TaskLogicV2.executeTask()           | 250,000 - 1,500,000 (varies)
  - Load task                       |   20,000
  - Verify proofs                   |   50,000 - 200,000
  - Execute actions (each)          |  100,000 - 800,000
  - Distribute rewards              |   80,000

TaskVault.executeTokenAction()      | 100,000 - 800,000 (varies)
  - Approve adapter                 |   46,000
  - Call adapter                    |   50,000 - 700,000
  - Clear approval                  |    5,000
  - Recovery logic                  |   10,000

RewardManager.distributeReward()    | 80,000 - 150,000
  - Calculate rewards               |   10,000
  - Call vault.releaseReward() 2x   |   60,000
  - Update fee counters             |   10,000

Total per execution                 | 400,000 - 2,200,000
Average                             | ~800,000

With gas price = 30 gwei:
  - Average execution cost: 0.024 ETH
  - With 120% reimbursement: 0.0288 ETH
```

### Storage Costs

```
Contract          | Storage Slots Used | Cost at Creation
------------------|-------------------|------------------
TaskCore          | 8-10              | ~160,000 gas
TaskVault         | 12-15             | ~240,000 gas
GlobalRegistry    | +3 per task       | ~60,000 gas
ActionRegistry    | +2 per adapter    | ~40,000 gas
ExecutorHub       | +5 per executor   | ~100,000 gas

Total per task: ~400,000 gas just for storage
```

---

## Conclusion

This execution flow analysis reveals:

1. **Complex Interactions**: Multiple contracts with intricate state dependencies
2. **Multiple Vulnerable Paths**: At least 3 critical exploit scenarios
3. **Gas Intensive**: High gas costs for task creation and execution
4. **State Management Issues**: No automatic expiration, no refunds for completed tasks

**Key Takeaways:**
- Funding validation must account for ALL costs (fees + gas + multipliers)
- Token recovery logic needs to track actual balances, not just expected
- State transitions need cleanup mechanisms (refunds, auto-expiration)
- Gas optimization opportunities exist throughout

---

**Document Version:** 1.0
**Last Updated:** 2025-11-18
**Status:** Complete
