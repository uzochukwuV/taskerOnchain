# NOYA Protocol - Additional Critical Findings

## CRITICAL SEVERITY ISSUES (Continued)

---

### 🔴 CRITICAL-6: Watchers Contract Has No Validation Logic

**Location:** `Watchers.sol:verifyRemoveLiquidity()` (line 8)

**Description:**
The `Watchers` contract is supposed to verify and validate withdrawal operations, but the critical `verifyRemoveLiquidity` function is completely empty and performs NO validation whatsoever.

**Vulnerable Code:**
```solidity
function verifyRemoveLiquidity(uint256 withdrawAmount, uint256 sentAmount, bytes memory data) external view {
    // COMPLETELY EMPTY - NO VALIDATION!
}
```

**Context:**
This function is called from `BaseConnector.sendTokensToTrustedAddress()`:
```solidity
// BaseConnector.sol lines 116-127
if (msg.sender == accountingManager) {
    (, , , , address watcherContract, ) = registry.getGovernanceAddresses(vaultId);

    (uint256 newAmount, bytes memory newData) = abi.decode(data, (uint256, bytes));
    Watchers(watcherContract).verifyRemoveLiquidity(
        amount,
        newAmount,
        newData
    );  // ← This does NOTHING!

    IERC20(token).safeTransfer(address(accountingManager), newAmount);
    amount = newAmount;
}
```

**Attack Scenario:**
1. Accounting Manager requests withdrawal of 1000 tokens from connector
2. Calls `sendTokensToTrustedAddress` with amount=1000
3. Watchers.verifyRemoveLiquidity() is called to validate the withdrawal
4. **Function does nothing and returns immediately**
5. Malicious or compromised accounting manager can withdraw any amount
6. No validation of:
   - Is withdrawal amount reasonable?
   - Is it within allowed limits?
   - Is TVL check performed?
   - Any fraud detection?

**Impact:**
- Complete bypass of withdrawal validation
- Unlimited, unmonitored withdrawals from connectors
- No fraud detection or prevention
- Critical security layer is non-functional

**Severity:** CRITICAL

**Recommendation:**
```solidity
function verifyRemoveLiquidity(uint256 withdrawAmount, uint256 sentAmount, bytes memory data) external view {
    // 1. Verify sentAmount <= withdrawAmount (no inflation)
    require(sentAmount <= withdrawAmount, "Sent amount exceeds requested");

    // 2. Verify sentAmount is within acceptable slippage
    uint256 maxSlippage = withdrawAmount * 50 / 1000; // 5%
    require(withdrawAmount - sentAmount <= maxSlippage, "Excessive slippage");

    // 3. Check rate limits or withdrawal caps
    // 4. Decode and validate 'data' parameter
    // 5. Check connector health and TVL
}
```

**Status:** CRITICAL - MUST FIX BEFORE DEPLOYMENT

---

### 🔴 CRITICAL-7: Morpho Slippage Calculation Inverted

**Location:** `MorphoBlueConnector.sol:withdraw()` (lines 62-65)

**Description:**
The slippage check in Morpho withdraw function has inverted logic that allows MORE slippage instead of preventing it.

**Vulnerable Code:**
```solidity
if (assets < (amount - (amount * BASIC_POINT_DIVISOR / slippageTolerance))) {
    revert IConnector_SlippageExceedsTolerance();
}
```

**Mathematical Analysis:**
- `BASIC_POINT_DIVISOR = 10,000`
- `slippageTolerance` default = `2,000,000` (from BaseConnector)
- Calculation: `amount * 10000 / 2000000 = amount / 200`
- So it checks: `assets < (amount - amount/200)`
- This means: `assets < 99.5% of amount`

**Problem:**
- This ALLOWS 0.5% slippage when it should be checking against user's tolerance
- The calculation is inverted - dividing by slippageTolerance instead of multiplying
- Should be: `(amount * slippageTolerance) / PRECISION`
- With slippageTolerance = 2,000,000 (meant to be 0.5%), this creates 200x error

**Attack Scenario:**
1. User sets slippageTolerance thinking 2,000,000 = 0.5% (2M / 4M precision)
2. Actual check allows only 0.5% deviation (inverted calculation)
3. OR if slippageTolerance is set correctly to 5000 (0.5% in 1M precision):
4. Check becomes: `amount * 10000 / 5000 = 2 * amount`
5. This would allow NEGATIVE assets (impossible, always passes)

**Impact:**
- Slippage protection is broken or inverted
- Users lose funds to excessive slippage
- MEV extraction possible

**Severity:** CRITICAL

**Recommendation:**
```solidity
// Correct slippage check
uint256 minAcceptable = amount * (1e6 - slippageTolerance) / 1e6;
if (assets < minAcceptable) {
    revert IConnector_SlippageExceedsTolerance();
}
```

**Status:** VULNERABLE

---

### 🔴 CRITICAL-8: WithdrawErrorHandler Balance Tracking Can Be Exploited

**Location:** `WithdrawErrorsHandler.sol` (lines 36-57)

**Description:**
The error handler tracks balances separately from actual balances, creating opportunity for accounting manipulation and stuck funds.

**Vulnerable Code:**
```solidity
function withdrawalError(address token, address to, uint256 amount, string memory reason)
    external
    onlyRole(ACCOUNTING_ROLE)
    nonReentrant
{
    uint256 balance = IERC20(token).balanceOf(address(this));
    if (balance < amount + errorBalances[token]) {
        revert InsufficientBalance(balance, amount);
    }
    errorBalances[token] += amount;  // Tracked separately
    errors.push(Error(token, to, amount, block.timestamp));
}

function handleWithdrawalErrors(uint256 errorId, address to) external onlyRole(MANAGER_ROLE) nonReentrant {
    Error memory error = errors[errorId];
    IERC20(error.token).safeTransfer(to, error.amount);
    errorBalances[error.token] -= error.amount;
    delete errors[errorId];  // Leaves gap in array!
}
```

**Issues:**

1. **Array Gap Problem:**
   - `delete errors[errorId]` sets array element to zero but doesn't remove it
   - Array becomes sparse with deleted entries
   - Impossible to iterate through all errors
   - Lost track of pending errors

2. **Balance Mismatch:**
   - `errorBalances[token]` tracks promised amounts
   - Actual balance can drift from tracked balance
   - If tokens are sent directly to contract, they become stuck
   - If tokens are withdrawn by manager, tracking is wrong

3. **No Expiration:**
   - Errors never expire
   - Old errors can accumulate forever
   - Funds locked indefinitely

**Attack Scenario:**
1. Withdrawal fails for user A, 100 tokens sent to error handler
2. errorBalances[token] = 100
3. Manager handles error, sends to correct address
4. errorBalances[token] = 0
5. Another error occurs, 50 tokens sent
6. errorBalances[token] = 50
7. Attacker directly sends 1000 tokens to contract
8. Actual balance = 1050, errorBalances = 50
9. 1000 tokens stuck with no way to recover
10. Manager can't access them (InsufficientBalance check fails)

**Impact:**
- Funds permanently stuck in error handler
- Accounting errors
- Lost user funds
- No recovery mechanism

**Severity:** CRITICAL

**Recommendation:**
```solidity
// Use mapping instead of array
mapping(uint256 => Error) public errors;
uint256 public errorCount;
mapping(uint256 => bool) public errorHandled;

// Add sweep function for excess tokens
function sweepExcess(address token, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
    uint256 balance = IERC20(token).balanceOf(address(this));
    uint256 excess = balance - errorBalances[token];
    require(excess > 0, "No excess");
    IERC20(token).safeTransfer(to, excess);
}

// Add expiration
if (block.timestamp > error.timestamp + 30 days) {
    // Allow admin to recover expired errors
}
```

**Status:** VULNERABLE

---

## HIGH SEVERITY ISSUES (Continued)

### 🟠 HIGH-8: OmniChain TVL Manipulation via Unauthorized Updates

**Location:** `OmnichainManagerBaseChain.sol:updateTVL()` (lines 33-44)

**Description:**
The `updateTVL` function only checks if `msg.sender == lzHelper` but doesn't validate the TVL data or source chain authenticity.

**Vulnerable Code:**
```solidity
function updateTVL(uint256 chainId, uint256 tvl, uint256 updateTime) external nonReentrant {
    if (msg.sender != lzHelper) revert IConnector_InvalidSender();
    // No validation of:
    // - Is chainId legitimate?
    // - Is tvl value reasonable?
    // - Is updateTime in valid range?
    // - Is this update authorized?

    registry.updateHoldingPostionWithTime(
        vaultId,
        registry.calculatePositionId(address(this), OMNICHAIN_POSITION_ID, abi.encode(chainId)),
        "",
        abi.encode(tvl),
        tvl <= DUST_LEVEL,
        updateTime
    );
}
```

**Attack Scenario:**
1. Compromised or malicious LZ Helper calls updateTVL
2. Reports inflated TVL from fake chainId
3. Base chain TVL calculation includes fake value
4. Share price artificially inflated
5. Attacker deposits and gets more shares than deserved
6. Or attacker who already holds shares withdraws more than they should

**Impact:**
- TVL manipulation across chains
- Share price manipulation
- Unfair share distribution
- Cross-chain accounting errors

**Severity:** HIGH

**Recommendation:**
- Add whitelist of valid chainIds
- Implement max TVL bounds per chain
- Add sanity checks for sudden TVL changes (> 50% change)
- Require multi-sig approval for large TVL updates
- Add staleness checks for updateTime
- Implement TVL change rate limits

**Status:** VULNERABLE

---

### 🟠 HIGH-9: Keepers Signature Malleability

**Location:** `Keepers.sol:execute()` (lines 84-118)

**Description:**
The multisig execution uses ECDSA.recover which is vulnerable to signature malleability attacks if not properly validated.

**Vulnerable Code:**
```solidity
address recovered = ECDSA.recover(totalHash, sigV[i], sigR[i], sigS[i]);
require(recovered > lastAdd && isOwner[recovered]);
```

**Issues:**
1. Uses address comparison `recovered > lastAdd` to prevent duplicates
2. This assumes addresses are ordered, but doesn't validate:
   - Signature (v, r, s) validity
   - EIP-2 signature malleability protection
3. OpenZeppelin's ECDSA.recover does have protections, but ordering check is insufficient

**Attack Scenario:**
1. Valid transaction with threshold=3 signatures collected
2. Attacker observes transaction in mempool
3. Creates malleable signature by flipping s value: s' = n - s (where n is secp256k1 order)
4. Malleable signature has same signer but different hash
5. Could bypass nonce check if used incorrectly
6. Front-run or replay with modified signatures

**Note:** OpenZeppelin's ECDSA library does prevent s-value malleability by checking `s <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0`, but the ordering check alone is still weak.

**Impact:**
- Potential transaction replay
- Signature reuse
- Front-running possibilities

**Severity:** HIGH (mitigated by OpenZeppelin but still risky pattern)

**Recommendation:**
- Validate signatures more thoroughly
- Add explicit malleability checks
- Use EIP-712 domain separator correctly (already implemented)
- Add additional nonce tracking per signer
- Consider using Safe's signature validation

**Status:** MEDIUM-HIGH (partially mitigated)

---

### 🟠 HIGH-10: No ETH Deposit Pause Mechanism

**Location:** `ETHDepositContract.sol:deposit()` (lines 24-47)

**Description:**
The ETH deposit contract has no pause mechanism and continues accepting deposits even if vault is paused.

**Vulnerable Code:**
```solidity
function deposit(uint256 vaultId, address referrer) external payable {
    // No pause check!
    // No vault state check!

    IWETH(WETH).deposit{value: msg.value}();
    // ...
    AccountingManager(accountingManager).deposit(msg.sender, msg.value, referrer);
}
```

**Issues:**
1. No check if vault is paused in registry
2. No circuit breaker for emergencies
3. ETH can get stuck if AccountingManager.deposit() reverts
4. No refund mechanism if deposit fails

**Attack Scenario:**
1. Vault is paused due to exploit detection
2. Users still deposit ETH through ETHDepositContract
3. ETH is converted to WETH
4. AccountingManager.deposit() reverts (vault paused)
5. User's ETH is stuck in contract
6. No automatic refund

**Impact:**
- User funds stuck during emergencies
- Cannot stop deposits when vault is compromised
- No emergency response capability

**Severity:** HIGH

**Recommendation:**
```solidity
function deposit(uint256 vaultId, address referrer) external payable {
    // Add pause check
    require(!PositionRegistry(registry).isVaultPaused(vaultId), "Vault paused");

    // Wrap ETH
    IWETH(WETH).deposit{value: msg.value}();

    // Approve and deposit with try-catch
    IERC20(WETH).forceApprove(accountingManager, msg.value);

    try AccountingManager(accountingManager).deposit(msg.sender, msg.value, referrer) {
        // Success
    } catch {
        // Refund on failure
        IWETH(WETH).withdraw(msg.value);
        payable(msg.sender).transfer(msg.value);
        revert("Deposit failed");
    }
}
```

**Status:** VULNERABLE

---

## MEDIUM SEVERITY ISSUES (Continued)

### 🟡 MEDIUM-9: Morpho Health Factor Edge Cases

**Location:** `MorphoBlueConnector.sol:getHealthFactor()` (lines 128-136)

**Description:**
Health factor calculation has edge cases that could lead to incorrect risk assessment.

**Issues:**
```solidity
function getHealthFactor(Id _id, Market memory _market) public view returns (uint256) {
    MarketParams memory market = morphoBlue.idToMarketParams(_id);
    Position memory p = morphoBlue.position(_id, address(this));
    uint256 borrowAmount = uint256(p.borrowShares).toAssetsUp(_market.totalBorrowAssets, _market.totalBorrowShares);

    if (borrowAmount == 0) return type(uint256).max;  // ← Issue 1: Max uint instead of specific value

    return market.lltv * convertCToL(p.collateral, market.oracle, market.collateralToken) / borrowAmount;
    // ← Issue 2: No check for zero collateral
    // ← Issue 3: Oracle price can be stale or manipulated
}
```

**Problems:**
1. Returns `type(uint256).max` when no borrow, could overflow in comparisons
2. Doesn't check if collateral is zero
3. No oracle staleness check
4. No bounds checking on health factor result
5. Division could result in very small or zero health factor being acceptable

**Impact:**
- Incorrect health assessments
- Positions incorrectly marked as safe
- Potential undercollateralized borrowing

**Severity:** MEDIUM

---

### 🟡 MEDIUM-10: OmniChain Decimal Conversion Precision Loss

**Location:** `OmnichainManagerNormalChain.sol:updateTVLInfo()` (lines 38-42)

**Description:**
Decimal conversion can lose precision when converting between chains with different decimals.

**Vulnerable Code:**
```solidity
function updateTVLInfo() external onlyManager {
    uint256 tvl = getTVL();
    tvl = tvl * BASE_CHAIN_DECIMAL / CURREVNT_CHAIN_DECIMAL;  // Precision loss!
    LZHelperSender(lzHelper).updateTVL(vaultId, tvl, block.timestamp);
}
```

**Example:**
- Current chain: 18 decimals
- Base chain: 6 decimals
- TVL = 1,234,567,890,123,456,789 (1.23 tokens with 18 decimals)
- Conversion: 1,234,567,890,123,456,789 * 1e6 / 1e18 = 1,234,567
- Lost: 890,123,456,789 in least significant digits
- For small amounts, could round to zero

**Impact:**
- Cross-chain TVL mismatch
- Small positions disappear
- Accumulated precision errors

**Severity:** MEDIUM

---

## Summary of Additional Findings

### New Critical Issues: 3
1. **CRITICAL-6**: Watchers validation completely bypassed
2. **CRITICAL-7**: Morpho slippage check inverted
3. **CRITICAL-8**: WithdrawErrorHandler balance tracking exploitable

### New High Severity: 3
1. **HIGH-8**: OmniChain TVL manipulation
2. **HIGH-9**: Keepers signature validation weaknesses
3. **HIGH-10**: No ETH deposit pause mechanism

### New Medium Severity: 2
1. **MEDIUM-9**: Morpho health factor edge cases
2. **MEDIUM-10**: OmniChain decimal precision loss

---

## Updated Risk Assessment

**Total Critical Issues:** 8 (was 5, +3)
**Total High Issues:** 10 (was 7, +3)
**Total Medium Issues:** 10 (was 8, +2)

**Overall Risk Level:** 🔴🔴 **CRITICAL**

The discovery of the completely non-functional Watchers validation is particularly concerning as it represents a fundamental security layer that is entirely absent. This, combined with the other critical issues, makes the protocol **UNSAFE FOR PRODUCTION DEPLOYMENT**.

---

## Immediate Action Required

### Must Fix Before ANY Deployment:

1. ✅ **Implement Watchers.verifyRemoveLiquidity()** - Cannot deploy without this
2. ✅ **Fix Morpho slippage calculation** - Math error that loses funds
3. ✅ **Fix WithdrawErrorHandler accounting** - Funds will get stuck
4. ✅ **Add proper validation to OmniChain TVL updates** - Cross-chain exploit vector
5. ✅ **Add pause mechanism to ETHDepositContract** - Cannot stop deposits in emergency

### Priority Fixes:

6. ⚠️ Fix all findings from main audit report (CRITICAL-1 through CRITICAL-5)
7. ⚠️ Implement comprehensive test suite covering all attack scenarios
8. ⚠️ External professional audit required
9. ⚠️ Bug bounty program before mainnet
10. ⚠️ Comprehensive monitoring and alerting system

---

## Conclusion

The NOYA protocol has significant security vulnerabilities that must be addressed before deployment. The most concerning finding is the completely non-functional Watchers contract, which is supposed to provide a critical security validation layer but does nothing.

**Recommendation:** **DO NOT DEPLOY** until all critical and high severity issues are resolved and the protocol undergoes professional security audit and extensive testing.

