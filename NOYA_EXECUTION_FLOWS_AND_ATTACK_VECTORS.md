# NOYA Protocol - Execution Flows & Attack Vectors

## Comprehensive Execution Flow Analysis

---

## 1. DEPOSIT FLOW - Complete Analysis

### 1.1 Normal Deposit Flow

```
┌─────────────┐
│    User     │
└─────┬───────┘
      │ 1. deposit(receiver, amount, referrer)
      │    - Checks: amount > minDepositAmount
      │    - Checks: receiver != address(0)
      │    - Checks: vault not paused
      ↓
┌─────────────────────────┐
│  AccountingManager      │
├─────────────────────────┤
│ 2. Transfer baseToken   │←─── User sends tokens
│    from user to vault   │
│                         │
│ 3. Check limits:        │
│    - depositLimitPer    │
│      Transaction        │
│    - totalAssets <      │
│      depositLimit       │
│      TotalAmount        │
│                         │
│ 4. Add to depositQueue: │
│    queue[last] = {      │
│      receiver,          │
│      timestamp,         │
│      amount,            │
│      shares: 0          │
│    }                    │
│                         │
│ 5. Increment:           │
│    - depositQueue.last  │
│    - totalAWFDeposit    │
└─────────────────────────┘
      │
      │ ⏱️ WAITING PERIOD (TVL must be updated)
      │
      ↓
┌─────────────────────────┐
│  Manager/Keeper         │
├─────────────────────────┤
│ 6. calculateDeposit     │
│    Shares(maxIter)      │
│                         │
│  For each deposit:      │
│    - Check recordTime   │
│      <= oldestUpdate    │
│    - shares = preview   │
│      Deposit(amount)    │
│    - Update calc time   │
│                         │
│  Share calculation:     │
│  shares = amount *      │
│    (totalSupply+1) /    │
│    (totalAssets+1)      │
└─────────────────────────┘
      │
      │ ⏱️ WAITING PERIOD (depositWaitingTime = 30 min)
      │
      ↓
┌─────────────────────────┐
│  Manager/Keeper         │
├─────────────────────────┤
│ 7. executeDeposit(      │
│    maxI, connector,     │
│    addLPdata)           │
│                         │
│  For each deposit:      │
│    - Check calcTime +   │
│      waitTime passed    │
│    - Mint shares to     │
│      receiver           │
│    - Update totals      │
│                         │
│ 8. Call connector.      │
│    addLiquidity()       │
│    - Transfer tokens    │
│      to connector       │
│    - Connector deploys  │
│      to protocol        │
└─────────────────────────┘
      │
      ↓
┌─────────────────────────┐
│  User receives shares   │
└─────────────────────────┘
```

### 1.2 ETH Deposit Flow (Additional Path)

```
┌─────────────┐
│    User     │
└─────┬───────┘
      │ 1. ETHDepositContract.deposit{value: ETH}(vaultId, referrer)
      │    ⚠️ NO PAUSE CHECK!
      ↓
┌────────────────────────────┐
│  ETHDepositContract        │
├────────────────────────────┤
│ 2. Convert ETH to WETH:    │
│    IWETH.deposit{value}()  │
│                            │
│ 3. Verify vault baseToken  │
│    == WETH                 │
│                            │
│ 4. Approve accounting      │
│    manager for WETH        │
│                            │
│ 5. Call                    │
│    AccountingManager.      │
│    deposit()               │
└────────────────────────────┘
      │
      ↓
    [Continues with normal deposit flow]
```

### 1.3 Deposit Attack Vectors

#### Attack Vector 1: First Depositor Inflation
```
Initial State:
- totalSupply = 0
- totalAssets = 0

Attacker deposits 1 wei:
- shares = 1 * (0+1) / (0+1) = 1 share
- totalSupply = 1
- totalAssets = 1

Attacker directly transfers 1000 ETH to vault:
- totalSupply = 1
- totalAssets = 1000 ETH + 1 wei

Victim deposits 100 ETH:
- shares = 100 * (1+1) / (1000+1) = 0.2 shares (rounds down to 0!)
- Victim gets 0 shares for 100 ETH
- OR if doesn't round to 0, gets much fewer shares than deserved
```

#### Attack Vector 2: Price Manipulation Between Record and Calculate
```
Time T0: User deposits 100 USDC
- TVL = 1000 USDC
- Expected shares = 100 * 1000 / 1000 = 100

Time T1: Attacker manipulates TVL before calculateDepositShares
- Drains connector (if possible)
- TVL drops to 500 USDC

Time T2: calculateDepositShares called
- shares = 100 * 1000 / 500 = 200 shares
- User gets 2x shares, diluting other holders

OR reverse:
- Attacker inflates TVL to 2000
- shares = 100 * 1000 / 2000 = 50 shares
- User gets half the shares they deserve
```

#### Attack Vector 3: ETH Deposit During Pause
```
Time T0: Exploit detected, vault paused

Time T1: User doesn't notice, deposits 10 ETH via ETHDepositContract
- ETH → WETH conversion succeeds
- WETH approved to AccountingManager
- AccountingManager.deposit() REVERTS (vault paused)
- But ETH already converted and approved
- User's WETH stuck in ETHDepositContract
- NO REFUND MECHANISM
```

---

## 2. WITHDRAWAL FLOW - Complete Analysis

### 2.1 Normal Withdrawal Flow

```
┌─────────────┐
│    User     │
└─────┬───────┘
      │ 1. withdraw(share, receiver)
      │    - Check: share > minWithdrawalAmount
      │    - Check: balance >= share + locked shares
      ↓
┌──────────────────────────────┐
│  AccountingManager           │
├──────────────────────────────┤
│ 2. Lock shares:              │
│    withdrawRequests          │
│    ByAddress[user] += share  │
│                              │
│ 3. Add to withdrawQueue:     │
│    queue[last] = {           │
│      owner: user,            │
│      receiver,               │
│      timestamp,              │
│      shares,                 │
│      amount: 0               │
│    }                         │
│                              │
│ 4. Increment:                │
│    withdrawQueue.last        │
└──────────────────────────────┘
      │
      │ ⏱️ WAITING PERIOD (TVL update)
      │
      ↓
┌──────────────────────────────┐
│  Manager/Keeper              │
├──────────────────────────────┤
│ 5. calculateWithdrawShares   │
│    (maxIterations)           │
│                              │
│  For each withdrawal:        │
│    - assets = previewRedeem  │
│      (shares)                │
│    - Update amount           │
│    - processedShares +=      │
│      shares                  │
│    - assetsNeeded +=         │
│      assets                  │
│                              │
│  Asset calculation:          │
│  assets = shares *           │
│    (totalAssets+1) /         │
│    (totalSupply+1)           │
│                              │
│ 6. Update:                   │
│    currentWithdrawGroup.     │
│    totalCBAmount +=          │
│    assetsNeeded              │
└──────────────────────────────┘
      │
      ↓
┌──────────────────────────────┐
│  Manager/Keeper              │
├──────────────────────────────┤
│ 7. startCurrentWithdraw      │
│    Group()                   │
│                              │
│  Set:                        │
│    - isStarted = true        │
│    - lastId = queue.middle   │
│    - Locks further calcs     │
└──────────────────────────────┘
      │
      │ 🏦 GATHER FUNDS PERIOD
      │
      ↓
┌──────────────────────────────┐
│  Manager/Keeper              │
├──────────────────────────────┤
│ 8. retrieveTokensFor         │
│    Withdraw(retrieveData[])  │
│                              │
│  For each connector:         │
│    - balanceBefore =         │
│      baseToken.balanceOf()   │
│    - connector.sendTokens    │
│      ToTrustedAddress()      │
│    - balanceAfter check      │
│    - amountAskedFor          │
│      Withdraw += amount      │
│                              │
│  ⚠️ CRITICAL: Connector may  │
│  return less than requested  │
│  due to losses/slippage      │
└──────────────────────────────┘
      │
      ↓
┌──────────────────────────────┐
│  Manager/Keeper              │
├──────────────────────────────┤
│ 9. fulfillCurrentWithdraw    │
│    Group()                   │
│                              │
│  Check:                      │
│    amountAskedForWithdraw    │
│    >= totalCBAmount          │
│                              │
│  Calculate available:        │
│    availableAssets =         │
│      balance -               │
│      depositQueue.totalAWF   │
│                              │
│  ⚠️ CRITICAL DECISION:       │
│  if (available >=            │
│      totalCBAmount) {        │
│    totalABAmount =           │
│      totalCBAmount           │
│  } else {                    │
│    totalABAmount =           │
│      availableAssets         │
│  }                           │
│                              │
│  Set isFullfilled = true     │
└──────────────────────────────┘
      │
      │ ⏱️ WAITING (withdrawWaitingTime = 6 hours)
      │
      ↓
┌──────────────────────────────┐
│  Manager/Keeper              │
├──────────────────────────────┤
│ 10. executeWithdraw          │
│     (maxIterations)          │
│                              │
│  For each withdrawal:        │
│    ⚠️ PROPORTIONAL:          │
│    baseTokenAmount =         │
│      amount *                │
│      totalABAmount /         │
│      totalCBAmountFullfilled │
│                              │
│    - Unlock shares           │
│    - Burn shares             │
│    - Calculate fee           │
│    - Transfer tokens         │
│      (with error handling)   │
│                              │
│  If transfer fails:          │
│    - Send to ErrorHandler    │
│    - Mark as failed          │
└──────────────────────────────┘
      │
      ↓
┌─────────────────────────────┐
│  User receives tokens       │
│  (possibly < expected due   │
│   to shortfall)             │
└─────────────────────────────┘
```

### 2.2 Withdrawal Attack Vectors

#### Attack Vector 1: Withdrawal Front-Running
```
Scenario: Shortfall Situation
- totalCBAmount = 1000 USDC (what users should get)
- totalABAmount = 600 USDC (what's actually available)
- Shortfall = 400 USDC (40% loss)

Queue:
1. Alice: 100 shares → should get 100 USDC
2. Bob:   200 shares → should get 200 USDC
3. Carol: 300 shares → should get 300 USDC
4. Dave:  400 shares → should get 400 USDC

executeWithdraw processes in order:
1. Alice: 100 * 600 / 1000 = 60 USDC (40% loss)
2. Bob:   200 * 600 / 1000 = 120 USDC (40% loss)
3. Carol: 300 * 600 / 1000 = 180 USDC (40% loss)
4. Dave:  400 * 600 / 1000 = 240 USDC (40% loss)

Everyone suffers equal proportional loss - FAIR

BUT if early execution before all funds gathered:
Time T0: totalABAmount = 200 (only partial funds)
- Alice executes early: 100 * 200 / 1000 = 20 USDC
  Wait... this is STILL proportional

ACTUAL ATTACK:
What if fulfillCurrentWithdrawGroup is called multiple times?
OR what if some users are processed before group is fulfilled?

The code prevents this with:
- Line 424: if (!isFullfilled) revert
- Line 434: while (lastId > first...)

So proportional distribution IS enforced.

HOWEVER: Attack exists in retrieveTokensForWithdraw:
- Manager can selectively retrieve from lossy connectors first
- Some connectors return less due to losses
- If manager cherry-picks which connectors to withdraw from
- Can engineer situations where certain users get more/less
```

#### Attack Vector 2: WithdrawErrorHandler Exploitation
```
Time T0: Alice's withdrawal of 1000 USDC fails
- Tokens sent to WithdrawErrorHandler
- errorBalances[USDC] = 1000
- errors[0] = {token: USDC, from: Alice, amount: 1000}

Time T1: Manager handles error correctly
- Sends 1000 USDC to Alice
- errorBalances[USDC] = 0
- delete errors[0] → array[0] now zero-struct

Time T2: Bob's withdrawal fails
- 500 USDC sent to ErrorHandler
- errorBalances[USDC] = 500
- errors[1] = {token: USDC, from: Bob, amount: 500}

Time T3: Attacker directly sends 10,000 USDC to ErrorHandler
- Actual balance = 10,500 USDC
- errorBalances[USDC] = 500
- 10,000 USDC stuck with no recovery method!

Time T4: Try to handle Bob's error:
- handleWithdrawalErrors(1, bob_address)
- Transfers 500 USDC successfully
- errorBalances[USDC] = 0
- 10,000 USDC still stuck!

withdrawalError check:
- balance < amount + errorBalances
- 10,000 < amount + 0
- Any new error > 10,000 will revert
- Funds permanently stuck
```

#### Attack Vector 3: Share Lock Bypass
```
User has 100 shares total

Time T0: Request withdraw of 60 shares
- withdrawRequestsByAddress[user] = 60
- Locked: 60, Free: 40

Time T1: Try to transfer 50 shares to another address
- _update() checks: balanceOf(from) < amount + locked
- 100 < 50 + 60 = 100 < 110 = TRUE
- Transfer REVERTS ✓ (correctly blocked)

Time T2: Try to request another withdrawal of 50 shares
- Check: balanceOf >= share + withdrawRequests
- 100 >= 50 + 60 = 100 >= 110 = FALSE
- Second withdrawal REVERTS ✓ (correctly blocked)

But what if contract has reentrancy?
- During _burn in executeWithdraw
- If _burn has callback (ERC777 style)
- User could re-enter and request new withdrawal
- But ERC20 from OpenZeppelin doesn't have callbacks
- Protected by nonReentrant anyway ✓

Lock mechanism appears SECURE.
```

---

## 3. FLASH LOAN FLOW - Complete Analysis

### 3.1 Flash Loan Execution Flow

```
┌──────────────────────┐
│  Keeper/Manager      │
└──────┬───────────────┘
       │ 1. makeFlashLoan(tokens[], amounts[], userData)
       │    - Set caller = msg.sender
       ↓
┌────────────────────────────────┐
│  BalancerFlashLoan             │
├────────────────────────────────┤
│ 2. Call Balancer:              │
│    vault.flashLoan(            │
│      this,                     │
│      tokens,                   │
│      amounts,                  │
│      userData                  │
│    )                           │
└────────────────────────────────┘
       │
       │ Balancer sends tokens and calls back
       ↓
┌────────────────────────────────┐
│  BalancerFlashLoan             │
│  .receiveFlashLoan()           │
├────────────────────────────────┤
│ 3. Verify caller:              │
│    - msg.sender == vault ✓     │
│    - caller == keeperContract ✓│
│                                │
│ 4. Decode userData:            │
│    (vaultId, receiver,         │
│     destConnectors[],          │
│     callingData[],             │
│     gas[])                     │
│                                │
│ 5. Verify receiver:            │
│    registry.isAnActive         │
│    Connector(receiver) ✓       │
│                                │
│ 6. Transfer tokens to          │
│    receiver connector          │
│    amounts[i] += feeAmounts[i] │
│                                │
│ 7. ⚠️ EXECUTE ARBITRARY        │
│    CALLS:                      │
│    for each destConnector:     │
│      - Verify is active ✓      │
│      - call{gas: gas[i]}       │
│        (callingData[i])        │
│      - require(success)        │
│                                │
│ 8. Retrieve tokens back:       │
│    receiver.sendTokensTo       │
│    TrustedAddress()            │
│                                │
│ 9. Repay Balancer:             │
│    tokens[i].safeTransfer(     │
│      vault,                    │
│      amounts[i]                │
│    )                           │
└────────────────────────────────┘
       │
       ↓
┌────────────────────────────────┐
│  Flash loan complete           │
│  caller = address(0)           │
└────────────────────────────────┘
```

### 3.2 Flash Loan Attack Vectors

#### Attack Vector 1: Reentrancy via Malicious Connector
```
Setup:
- Attacker controls ConnectorX (added by compromised maintainer)
- ConnectorX is marked as active connector

Attack:
1. Keeper calls makeFlashLoan with:
   - userData.receiver = ConnectorX
   - userData.destConnectors = [ConnectorX]
   - userData.callingData = <malicious data>

2. receiveFlashLoan executes:
   - Transfers flash loaned tokens to ConnectorX ✓
   - Calls ConnectorX with malicious callingData

3. ConnectorX.fallback() receives call:
   - Re-enters AccountingManager.withdraw()
   - Or re-enters Registry.updateHoldingPosition()
   - Or manipulates TVL calculations
   - Or re-enters another flashLoan (if possible)

4. State manipulation while holding flash loan
   - Changes share prices
   - Manipulates TVL
   - Drains other positions

5. Returns from call successfully
6. Repays flash loan
7. Profit from manipulated state

Current Protection:
- makeFlashLoan has nonReentrant ✓
- BUT receiveFlashLoan does NOT!
- Arbitrary calls in step 7 can re-enter OTHER contracts
- AccountingManager has nonReentrant on most functions ✓
- BUT flash loan can still manipulate state via:
  - Registry functions (not all nonReentrant)
  - Other connector functions
  - Oracle updates
```

#### Attack Vector 2: Gas Griefing
```
Attack:
1. Keeper initiates flash loan with:
   - gas[0] = 1,000,000 (set high)
   - callingData[0] = complex operations

2. In receiveFlashLoan:
   - Line 85: call{gas: gas[i]}(callingData[i])
   - Malicious connector consumes 999,999 gas
   - Leaves 1 gas for remaining operations

3. Remaining operations fail:
   - Can't retrieve tokens back
   - Can't repay flash loan
   - Entire transaction reverts

4. Keeper wasted gas
5. Repeat to DOS the protocol

Protection:
- Should limit max gas per call
- Should reserve gas for cleanup operations
```

#### Attack Vector 3: Flash Loan Fee Manipulation
```
Observation:
- Line 78: amounts[i] = amounts[i] + feeAmounts[i]

What if:
1. Flash loan 1000 tokens, fee = 5 tokens
2. amounts[0] = 1005 after line 78
3. Execute operations
4. Line 90: receiver.sendTokensToTrustedAddress(1005)
5. But receiver only has 1000 + profits
6. If profits < 5, transaction reverts

This is actually CORRECT behavior - prevents borrowing if can't pay fee.

But what if receiver maliciously returns less?
- sendTokensToTrustedAddress can return different amount
- But line 90 doesn't check return value
- Assumes receiver sends full amount
- If receiver sends only 1000:
- Line 97: safeTransfer(vault, 1005) REVERTS (insufficient balance)
- Attack fails, flash loan reverts ✓

So this is protected.
```

---

## 4. BRIDGE TRANSACTION FLOW - Complete Analysis

### 4.1 Normal Bridge Flow

```
┌──────────────────────────────┐
│  Manager/Watcher             │
└──────┬───────────────────────┘
       │ 1. updateBridgeTransactionApproval(txHash)
       │    - If approved, delete approval
       │    - If not approved, set timestamp
       ↓
┌────────────────────────────────┐
│  OmnichainLogic                │
├────────────────────────────────┤
│ 2. Store approval:             │
│    approvedBridgeTXN[txHash] = │
│    block.timestamp             │
└────────────────────────────────┘
       │
       │ ⏱️ WAITING (bridgeWaitingTime = 30 min)
       │
       ↓
┌────────────────────────────────┐
│  Manager                       │
└──────┬───────────────────────┘
       │ 3. startBridgeTransaction(bridgeRequest)
       ↓
┌────────────────────────────────┐
│  OmnichainLogic                │
├────────────────────────────────┤
│ 4. Hash request:               │
│    txn = keccak256(            │
│      bridgeRequest             │
│    )                           │
│                                │
│ 5. Verify approval:            │
│    ⚠️ ISSUE:                   │
│    if (approved == 0 ||        │
│        approved + waitTime     │
│        > block.timestamp)      │
│      revert                    │
│    Should be >= not > !        │
│                                │
│ 6. Verify request:             │
│    - from == address(this) ✓   │
│    - destChainAddress[         │
│      destChainId] set ✓        │
│    - matches receiver ✓        │
│                                │
│ 7. Clear approval:             │
│    approvedBridgeTXN[txn] = 0  │
│                                │
│ 8. Execute bridge:             │
│    swapHandler.executeBridge   │
│    {value}(bridgeRequest)      │
│                                │
│ 9. Update registry:            │
│    _updateTokenInRegistry()    │
└────────────────────────────────┘
       │
       ↓
┌────────────────────────────────┐
│  SwapAndBridgeHandler          │
├────────────────────────────────┤
│ 10. Verify route:              │
│     - Route exists ✓           │
│     - Route is enabled ✓       │
│     - Route isBridge = true ✓  │
│                                │
│ 11. Execute bridge:            │
│     ISwapAndBridge             │
│     Implementation.            │
│     performBridgeAction()      │
└────────────────────────────────┘
       │
       ↓
┌────────────────────────────────┐
│  Tokens bridged to dest chain  │
└────────────────────────────────┘
```

### 4.2 Bridge Attack Vectors

#### Attack Vector 1: Time Window Off-By-One
```
Approval time: T0 = 1000
Waiting time: 30 minutes = 1800 seconds
Expected executable time: T0 + 1800 = 2800

Code check (Line 70):
  if (approved + waitTime > block.timestamp) revert

At block.timestamp = 2800:
  if (1000 + 1800 > 2800) revert
  if (2800 > 2800) revert
  FALSE → Transaction SUCCEEDS ✓

At block.timestamp = 2799:
  if (1000 + 1800 > 2799) revert
  if (2800 > 2799) revert
  TRUE → Transaction REVERTS ✓

So the check works BUT is inconsistent:
- Documentation says "30 minutes"
- Code requires STRICTLY MORE than 30 minutes
- Transaction can't execute AT EXACTLY 30 minutes
- Must wait for 30 minutes + 1 second

Attack implications:
- Front-runners know exact timestamp
- Can prepare transaction to execute at T0+1800
- Or can grief by executing at T0+1800-1 (will fail)
- Or can delay valid transactions by blocking at T0+1800

Should be:
  if (approved + waitTime >= block.timestamp) revert

This allows execution AT OR AFTER the waiting period.
```

#### Attack Vector 2: Bridge Approval Front-Running
```
Scenario:
1. Manager approves bridge of 1000 ETH at timestamp 1000
2. Waiting period = 30 minutes
3. Front-runner monitors approvals

Attack at timestamp 2800 (executable time):
4. Manager submits: startBridgeTransaction(legitRequest)
5. Front-runner sees transaction in mempool
6. Front-runner submits with higher gas:
   - Same bridgeRequest
   - Or modified bridgeRequest (if not hashed correctly)
7. Front-runner's transaction executes first
8. approvedBridgeTXN[txn] = 0 (cleared)
9. Manager's transaction reverts (approval already used)

Result:
- If front-runner used same request: DOS attack, bridge delayed
- If front-runner modified request: Depends on if hash matches

Protection analysis:
- txn = keccak256(abi.encode(bridgeRequest))
- BridgeRequest must match exactly
- Cannot modify without changing hash
- So attack can only DOS, not steal

But DOS is still problematic:
- Delays time-sensitive bridges
- Wasted gas fees
- Can repeat indefinitely
```

#### Attack Vector 3: Malicious Destination Chain Update
```
Setup:
- Compromised maintainer

Attack:
1. Maintainer calls updateChainInfo(fakeChainId, attackerAddress)
2. Manager (unaware) approves bridge to fakeChainId
3. startBridgeTransaction executes
4. Funds bridged to attackerAddress on fake chain
5. Funds lost

Current Protection:
- Only maintainer can update chain info
- Maintainer is time-locked role
- But if maintainer is compromised, no protection

Should add:
- Whitelist of valid chain IDs
- Multi-sig requirement for chain updates
- Sanity checks on addresses
```

---

## 5. TVL CALCULATION FLOW - Complete Analysis

### 5.1 TVL Calculation Flow

```
┌────────────────────────────────┐
│  Anyone (view function)        │
└──────┬─────────────────────────┘
       │ 1. Call TVLHelper.getTVL(vaultId, registry, baseToken)
       ↓
┌────────────────────────────────┐
│  TVLHelper                     │
├────────────────────────────────┤
│ 2. Get all positions:          │
│    positions = registry.       │
│    getHoldingPositions(        │
│      vaultId                   │
│    )                           │
│                                │
│ 3. Loop through positions:     │
│    ⚠️ NO GAS LIMIT CHECK!      │
│                                │
│    for (i = 0; i < positions.  │
│         length; i++)           │
└────────────────────────────────┘
       │
       │ For each position
       ↓
┌────────────────────────────────┐
│  IConnector(calculator         │
│  Connector)                    │
├────────────────────────────────┤
│ 4. Get position TVL:           │
│    tvl = connector.            │
│    getPositionTVL(             │
│      position,                 │
│      baseToken                 │
│    )                           │
│                                │
│  Each connector implements     │
│  differently:                  │
│                                │
│  - Aave: getUserAccountData    │
│  - Morpho: position shares     │
│  - Curve: LP tokens            │
│  - Pendle: market positions    │
│  - OmniChain: additionalData   │
│  - Basic: token balance        │
│                                │
│ 5. Check if debt:              │
│    isDebt = registry.          │
│    isPositionDebt(positionId)  │
│                                │
│ 6. Accumulate:                 │
│    if (isDebt)                 │
│      totalDebt += tvl          │
│    else                        │
│      totalTVL += tvl           │
└────────────────────────────────┘
       │
       ↓
┌────────────────────────────────┐
│  Return:                       │
│  totalTVL - totalDebt          │
│  (or 0 if debt > TVL)          │
└────────────────────────────────┘
```

### 5.2 TVL Attack Vectors

#### Attack Vector 1: Position Spam DOS
```
Attack:
1. Malicious connector creates 1000 positions
2. Each position requires:
   - External call to connector
   - Storage reads
   - Calculations
   - Oracle calls

3. TVL calculation:
   - Gas cost ≈ 100k gas per position
   - 1000 positions = 100M gas
   - Block gas limit ≈ 30M gas
   - TVL calculation REVERTS

4. Consequences:
   - Cannot calculate TVL
   - Cannot process deposits (needs TVL)
   - Cannot process withdrawals (needs TVL)
   - Protocol becomes unusable

Current Protection: NONE
- No max positions enforced strictly
- MAX_NUM_HOLDING_POSITIONS = 40, but not enforced in TVL
- Registry allows up to maxNumHoldingPositions = 20

But malicious connector can:
- Create position
- Remove position
- Create new position
- Repeat to evade limits

Should add:
- Pagination in TVL calculation
- Cache TVL results
- Lazy evaluation
- Emergency TVL override
```

#### Attack Vector 2: Malicious Connector TVL Inflation
```
Attack:
1. Malicious connector added by compromised maintainer
2. Connector's _getPositionTVL() returns:
   - return type(uint256).max;
   - Or inflated value

3. TVL calculation:
   - totalTVL += type(uint256).max
   - totalTVL overflows to very high value
   - Share price inflated

4. Attacker deposits small amount:
   - Gets very few shares (or zero due to rounding)
   - OR if overflow handled wrong, gets many shares

5. Result: Share price manipulation

Current Protection:
- Connector must be approved by maintainer
- If maintainer compromised, no protection

Should add:
- TVL sanity checks
- Maximum reasonable TVL per position
- Oracle cross-validation
```

#### Attack Vector 3: Oracle Manipulation in TVL
```
Each connector calls valueOracle.getValue():

Flow:
Position TVL (in connector terms)
  ↓
valueOracle.getValue(token, baseToken, amount)
  ↓
NoyaValueOracle._getValue()
  ↓
priceRoutes[token][baseToken] (controllable by maintainer!)
  ↓
Loop through price sources
  ↓
Final price

Attack:
1. Compromised maintainer updates price routes
2. Routes through manipulated oracles
3. TVL inflated/deflated
4. Share price manipulation
5. Profit from deposits/withdrawals at wrong prices

This is CRITICAL-2 from main report.
```

---

## 6. FEE CALCULATION FLOW - Complete Analysis

### 6.1 Performance Fee Flow

```
┌────────────────────────────────┐
│  Manager                       │
└──────┬─────────────────────────┘
       │ 1. recordProfitForFee()
       ↓
┌────────────────────────────────┐
│  AccountingManager             │
├────────────────────────────────┤
│ 2. Calculate profit:           │
│    profit = getProfit()        │
│    = (TVL +                    │
│       totalWithdrawn) -        │
│      totalDeposited            │
│                                │
│ 3. Store:                      │
│    storedProfitForFee =        │
│      profit                    │
│    profitStoredTime =          │
│      block.timestamp           │
│                                │
│ 4. If profit >                 │
│      totalProfitCalculated:    │
│                                │
│    newProfit =                 │
│      profit -                  │
│      totalProfitCalculated     │
│                                │
│    feeAmount =                 │
│      newProfit *               │
│      performanceFee /          │
│      FEE_PRECISION             │
│                                │
│    feeShares =                 │
│      previewDeposit(feeAmount) │
│                                │
│    preformanceFeeShares        │
│    WaitingForDistribution =    │
│      feeShares                 │
└────────────────────────────────┘
       │
       │ ⏱️ WAITING PERIOD (12-48 hours)
       │
       ↓
┌────────────────────────────────┐
│  Manager                       │
└──────┬─────────────────────────┘
       │ 5. collectPerformanceFees()
       ↓
┌────────────────────────────────┐
│  AccountingManager             │
├────────────────────────────────┤
│ 6. Checks:                     │
│    - feeShares > 0 ✓           │
│    - timestamp >= 12 hours ✓   │
│    - timestamp <= 48 hours ✓   │
│                                │
│ 7. Mint shares:                │
│    _mint(                      │
│      performanceFee            │
│      Receiver,                 │
│      feeShares                 │
│    )                           │
│                                │
│ 8. Update:                     │
│    totalProfitCalculated =     │
│      storedProfitForFee        │
│    feeShares = 0               │
└────────────────────────────────┘
```

### 6.2 Management Fee Flow

```
┌────────────────────────────────┐
│  Manager (daily/periodic)      │
└──────┬─────────────────────────┘
       │ collectManagementFees()
       ↓
┌────────────────────────────────┐
│  AccountingManager             │
├────────────────────────────────┤
│ 1. Check time passed:          │
│    if (block.timestamp -       │
│        lastFee < 1 day)        │
│      return (0, 0)             │
│                                │
│ 2. Calculate time:             │
│    timePassed =                │
│      block.timestamp -         │
│      lastFeeDistribution       │
│                                │
│    if (timePassed > 10 days)   │
│      timePassed = 10 days      │
│                                │
│ 3. Get current shares:         │
│    totalShares = totalSupply() │
│    currentFeeShares =          │
│      feeReceiver balances +    │
│      performanceFeeWaiting     │
│                                │
│ 4. Calculate fee:              │
│    managementFeeAmount =       │
│      (timePassed *             │
│       managementFee *          │
│       (totalShares -           │
│        currentFeeShares))      │
│      / FEE_PRECISION           │
│      / 365 days                │
│                                │
│ 5. Mint shares:                │
│    _mint(management            │
│      FeeReceiver,              │
│      managementFeeAmount)      │
│                                │
│ 6. Update timestamp:           │
│    lastFeeDistribution =       │
│      block.timestamp           │
└────────────────────────────────┘
```

### 6.3 Fee Attack Vectors

#### Attack Vector 1: Performance Fee Gaming
```
Setup:
- Manager has performanceFee = 20% (200000 / 1000000)
- Current TVL = 1000 USDC
- totalDepositedAmount = 1000 USDC
- totalWithdrawnAmount = 0
- Profit = 0

Attack:
Time T0:
1. Manager executes large swaps
2. Temporarily inflates position values
3. TVL appears as 2000 USDC (fake profit)
4. Calls recordProfitForFee()
   - profit = 2000 + 0 - 1000 = 1000
   - feeAmount = 1000 * 0.2 = 200
   - feeShares = previewDeposit(200) ≈ 200 shares

Time T0 + 12 hours:
5. TVL still inflated at 2000 (maintains positions)
6. Calls collectPerformanceFees()
   - Mints 200 shares to fee receiver
   - totalProfitCalculated = 1000

Time T0 + 13 hours:
7. Unwinds inflated positions
8. TVL returns to 1000
9. Real profit = 0
10. But fee receiver has 200 shares

Result:
- Fee extracted on fake profit
- Dilutes other shareholders
- Can repeat monthly

Current Protection:
- checkIfTVLHasDroped() can burn waiting fees
- But only before collection
- After collection, shares are minted
- 12-hour window allows checking
- But manager can maintain fake profit for 12 hours
```

#### Attack Vector 2: Management Fee Precision Loss
```
Code (Line 552-553):
  managementFeeAmount = (timePassed * managementFee * (totalShares - currentFeeShares)) / FEE_PRECISION / 365 days

Issue: Multiple divisions cause precision loss

Example:
- timePassed = 1 day = 86400 seconds
- managementFee = 10000 (1%)
- totalShares = 100
- currentFeeShares = 0
- FEE_PRECISION = 1e6
- 365 days = 31536000 seconds

Calculation:
  = (86400 * 10000 * 100) / 1000000 / 31536000
  = 86400000000 / 1000000 / 31536000
  = 86400 / 31536000
  = 0.00273... → rounds to 0!

For small vaults or short times, fees round to zero.

Should use:
  = (timePassed * managementFee * totalShares) / (FEE_PRECISION * 365 days)
  = single division at end to preserve precision
```

#### Attack Vector 3: Fee Calculation Manipulation via Share Transfers
```
Observation:
Line 549-550:
  currentFeeShares = balanceOf(managementFeeReceiver) +
                      balanceOf(performanceFeeReceiver) +
                      preformanceFeeSharesWaitingForDistribution

Attack idea:
1. Fee receivers transfer shares to other addresses
2. currentFeeShares becomes 0
3. Management fee calculation:
   - Uses totalShares - currentFeeShares
   - If currentFeeShares = 0, denominator increases
   - Extracts more fees

Analysis:
  managementFeeAmount = (time * fee * (totalShares - currentFeeShares)) / precision / 365days

If currentFeeShares = 0:
  = (time * fee * totalShares) / precision / 365days
  = Maximum fee extraction

If currentFeeShares = totalShares/2:
  = (time * fee * totalShares/2) / precision / 365days
  = Half the fee

So transferring fee shares away INCREASES fees extracted!

This might be intentional design (fees on all shares including fee shares).
But could be exploited:
1. Fee receiver accumulates shares
2. Transfers to separate wallet
3. Extracts higher fees
4. Transfers back
5. Repeat

Should track cumulative fees differently, not based on current balances.
```

---

## SUMMARY OF CRITICAL EXECUTION FLOW VULNERABILITIES

### Critical Flow Issues:

1. **Flash Loan Flow**: No reentrancy protection in receiveFlashLoan()
2. **Withdrawal Flow**: Proportional distribution works, but shortfalls are unfair
3. **Bridge Flow**: Time window off-by-one, front-running possible
4. **TVL Flow**: Unbounded loops, DOS via position spam
5. **Fee Flow**: Precision loss, gaming possible
6. **Watchers Flow**: Completely non-functional validation
7. **ETH Deposit Flow**: No pause check, funds can get stuck

### Recommended Flow Improvements:

1. Add reentrancy guards to all callback functions
2. Implement pagination in TVL calculations
3. Add emergency pause to all entry points
4. Fix time window calculations (use >= not >)
5. Add slippage protection to all value conversions
6. Implement fee calculation with single division
7. Add comprehensive validation in Watchers
8. Add refund mechanisms to deposit contracts

