# 🎯 Trading Adapters Guide

## Overview

Your Task Automation System now includes **5 powerful trading adapters** that enable users to create sophisticated trading strategies without writing code.

---

## 📊 Available Adapters

### 1. **UniswapLimitOrderAdapter** ✅
**Status**: Already deployed

**Use Case**: Place limit orders that execute when price reaches target

**Example**: "Buy WGLMR when it reaches 1.5 USDC"

```typescript
const action = {
    protocol: STELLASWAP_ROUTER,
    selector: "0x38ed1739",
    params: ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "address", "uint256", "uint256", "address", "address"],
        [
            USDC_ADDRESS,      // tokenIn
            WGLMR_ADDRESS,     // tokenOut
            amount In,         // Amount to spend
            minAmountOut,      // Minimum WGLMR to receive
            user.address,      // Recipient
            user.address       // Creator
        ]
    ),
    value: 0
};
```

---

### 2. **StopLossAdapter** 🛡️ NEW!
**Status**: Ready to deploy

**Use Case**: Automatically sell when price drops below threshold

**Example**: "Sell my WGLMR if price drops below 1.2 USDC"

**How it works**:
- Monitors token price continuously
- Triggers sell when price ≤ stop loss threshold
- Protects against major losses

**Parameters**:
```solidity
(
    address tokenToSell,      // WGLMR
    address tokenToReceive,   // USDC
    uint256 amountToSell,     // Amount to sell
    uint256 stopLossPrice,    // Trigger price (e.g., 1.2 USDC)
    address recipient,        // Where to send USDC
    address creator           // Token owner
)
```

**Example Task**:
```typescript
// Sell 100 WGLMR if price drops to 1.2 USDC or lower
await taskRegistry.createTask(
    { conditionType: 0, conditionData: "0x" }, // ALWAYS (adapter checks price)
    [{
        protocol: STELLASWAP_ROUTER,
        selector: "0x00000000",
        params: encodeStopLossParams(
            WGLMR, USDC,
            ethers.parseEther("100"),
            ethers.parseUnits("1.2", 6) // 1.2 USDC
        ),
        value: 0
    }],
    ethers.parseEther("0.1"), // Reward
    0, 1, 0,
    { value: ethers.parseEther("0.1") }
);
```

---

### 3. **TakeProfitAdapter** 🎯 NEW!
**Status**: Ready to deploy

**Use Case**: Automatically sell when price reaches profit target

**Example**: "Sell my WGLMR when it reaches 2.0 USDC"

**How it works**:
- Monitors token price continuously
- Triggers sell when price ≥ target
- Locks in profits automatically

**Parameters**: Same as StopLoss but triggers on price increase

**Example Task**:
```typescript
// Sell 100 WGLMR when price reaches 2.0 USDC
await taskRegistry.createTask(
    { conditionType: 0, conditionData: "0x" },
    [{
        protocol: STELLASWAP_ROUTER,
        selector: "0x00000000",
        params: encodeTakeProfitParams(
            WGLMR, USDC,
            ethers.parseEther("100"),
            ethers.parseUnits("2.0", 6) // 2.0 USDC
        ),
        value: 0
    }],
    ethers.parseEther("0.1"),
    0, 1, 0,
    { value: ethers.parseEther("0.1") }
);
```

---

### 4. **TrailingStopAdapter** 📈 NEW!
**Status**: Ready to deploy

**Use Case**: Dynamic stop loss that follows price upward

**Example**: "Sell if price drops 10% from its peak"

**How it works**:
1. Tracks highest price reached (**peak**)
2. Updates peak as price rises
3. Triggers sell when price drops X% from peak
4. Maximizes profits while protecting downside

**Parameters**:
```solidity
(
    address tokenToSell,
    address tokenToReceive,
    uint256 amountToSell,
    uint256 trailingPercent,  // Drop % from peak (e.g., 1000 = 10%)
    address recipient,
    address creator
)
```

**Example Task**:
```typescript
// Sell if WGLMR drops 10% from peak
// If peak is 2.0 USDC, sells at 1.8 USDC
// If peak rises to 3.0 USDC, sells at 2.7 USDC
await taskRegistry.createTask(
    { conditionType: 0, conditionData: "0x" },
    [{
        protocol: STELLASWAP_ROUTER,
        selector: "0x00000000",
        params: encodeTrailingStopParams(
            WGLMR, USDC,
            ethers.parseEther("100"),
            1000 // 10% trailing
        ),
        value: 0
    }],
    ethers.parseEther("0.15"), // Higher reward for complex task
    0, 1, 0,
    { value: ethers.parseEther("0.15") }
);
```

**Advanced Features**:
- `checkTrailingStop()` - View current peak and drop %
- `getTrailingStopData()` - Get full tracking data
- Automatically resets after execution

---

### 5. **DCAAdapter** 💰 NEW!
**Status**: Ready to deploy

**Use Case**: Dollar Cost Averaging - regular recurring buys

**Example**: "Buy $100 of WGLMR every week for 1 year"

**How it works**:
- Executes fixed-amount buys on schedule
- Averages out price volatility
- Perfect for long-term accumulation

**Parameters**:
```solidity
(
    address tokenToBuy,      // WGLMR
    address paymentToken,    // USDC
    uint256 amountToSpend,   // Fixed amount per buy (e.g., $100)
    uint256 minAmountOut,    // Slippage protection (optional)
    address recipient,       // Where to send purchased tokens
    address creator          // Payment token owner
)
```

**Example Task**:
```typescript
// Buy $100 USDC worth of WGLMR every week for 52 weeks
await taskRegistry.createTask(
    { conditionType: 0, conditionData: "0x" },
    [{
        protocol: STELLASWAP_ROUTER,
        selector: "0x00000000",
        params: encodeDCAParams(
            WGLMR, USDC,
            ethers.parseUnits("100", 6), // $100 per buy
            0 // Accept any amount (true DCA)
        ),
        value: 0
    }],
    ethers.parseEther("0.05"), // 0.05 GLMR per execution
    0,                         // No expiry
    52,                        // 52 executions (1 year)
    7 * 24 * 60 * 60,         // Every 7 days
    { value: ethers.parseEther("2.6") } // Fund all 52 executions
);
```

**DCA Statistics**:
- `getDCAStats(taskId)` - View execution history
- `calculateProfitLoss(taskId, currentPrice)` - Check performance
- Tracks average price paid
- Monitors total amount accumulated

---

## 🪙 Recommended Tokens

### **Initial Token Support** (Moonbeam/Passet Hub)

#### **Category 1: Stablecoins** (Highest Priority)
Essential for price pairs and DCA strategies

| Token | Address (Moonbeam) | Decimals | Use Case |
|-------|-------------------|----------|----------|
| **USDC** | `0x931715FEE2d06333043d11F658C8CE934aC61D0c` | 6 | Primary stablecoin |
| **USDT** | `0xeFAeeE334F0Fd1712f9a8cc375f427D9Cdd40d73` | 6 | Alternative stable |
| **DAI** | `0x14df360966a1c4582d2B18EDbdae432EA0A27575` | 18 | Decentralized stable |

#### **Category 2: Native & Wrapped**
Platform tokens and wrapped assets

| Token | Address (Moonbeam) | Decimals | Use Case |
|-------|-------------------|----------|----------|
| **GLMR** | Native | 18 | Gas & trading |
| **WGLMR** | `0xAcc15dC74880C9944775448304B263D191c6077F` | 18 | Wrapped GLMR |
| **WETH** | `0xab3f0245B83feB11d15AAffeFD7AD465a59817eD` | 18 | Ethereum bridge |
| **WBTC** | `0x1DC78Acda13a8BC4408B207c9E48CDBc096D95e0` | 8 | Bitcoin bridge |

#### **Category 3: DeFi Tokens**
Major DeFi protocol tokens

| Token | Type | Use Case |
|-------|------|----------|
| **STELLA** | DEX token | StellaSwap governance |
| **BEAM** | DEX token | BeamSwap rewards |
| **xcDOT** | Cross-chain | Polkadot bridge |

---

## 🚀 Token Registry Setup

After deployment, initialize the TokenRegistry:

```typescript
const tokenRegistry = await ethers.getContractAt("TokenRegistry", TOKEN_REGISTRY_ADDRESS);

// Add stablecoins
await tokenRegistry.batchAddTokens(
    [USDC_ADDRESS, USDT_ADDRESS, DAI_ADDRESS],
    ["USDC", "USDT", "DAI"],
    ["USD Coin", "Tether USD", "Dai Stablecoin"],
    [true, true, true], // isStablecoin
    [USDC_FEED, USDT_FEED, DAI_FEED], // Price feeds
    [0, 0, 0] // Category: STABLECOIN
);

// Add native/wrapped
await tokenRegistry.batchAddTokens(
    [WGLMR_ADDRESS, WETH_ADDRESS, WBTC_ADDRESS],
    ["WGLMR", "WETH", "WBTC"],
    ["Wrapped GLMR", "Wrapped Ether", "Wrapped Bitcoin"],
    [false, false, false],
    [GLMR_FEED, ETH_FEED, BTC_FEED],
    [2, 2, 2] // Category: WRAPPED
);
```

**Dynamic Expansion**:
```typescript
// Add new token anytime
await tokenRegistry.addToken(
    NEW_TOKEN_ADDRESS,
    "SYMBOL",
    "Token Name",
    false, // not stablecoin
    PRICE_FEED_ADDRESS, // optional
    3 // Category: DEFI
);

// Deactivate token if needed
await tokenRegistry.setTokenStatus(TOKEN_ADDRESS, false);
```

---

## 🤖 Executor Bot Integration

Use the **TaskChecker** contract to find executable tasks:

```typescript
const taskChecker = await ethers.getContractAt("TaskChecker", TASK_CHECKER_ADDRESS);

// Get top priority tasks
const [taskIds, rewards, priorities] = await taskChecker.getTopPriorityTasks(
    executor.address,
    10 // Get top 10 tasks
);

// Check specific task readiness
const [isReady, reason] = await taskChecker.isTaskReady(taskId, executor.address);

if (isReady) {
    await executorManager.attemptExecute(taskId);
}

// Get tasks by reward range
const highValueTasks = await taskChecker.getTasksByRewardRange(
    ethers.parseEther("0.1"), // Min reward
    ethers.parseEther("1"),   // Max reward
    20 // Limit
);
```

---

## 📊 Adapter Comparison

| Adapter | Complexity | Gas Cost | Best For |
|---------|-----------|----------|----------|
| **Limit Order** | Low | ~120k | Simple price triggers |
| **Stop Loss** | Low | ~130k | Risk management |
| **Take Profit** | Low | ~130k | Profit taking |
| **Trailing Stop** | Medium | ~160k | Maximum profit capture |
| **DCA** | Low | ~140k | Long-term accumulation |

---

## 🔒 Security Considerations

### **Stop Loss / Take Profit**
- ✅ Always set reasonable slippage (5-10%)
- ✅ Monitor DEX liquidity
- ⚠️ Large orders may have slippage

### **Trailing Stop**
- ✅ Recommended trailing: 10-20%
- ⚠️ Too tight (< 5%) may trigger on normal volatility
- ⚠️ Too loose (> 30%) defeats the purpose

### **DCA**
- ✅ Perfect for volatile markets
- ✅ Set reasonable buy amounts
- ⚠️ Ensure sufficient token approvals for all executions

---

## 💡 Strategy Examples

### **Conservative Strategy**
```
1. Buy token with DCA ($100/week)
2. Set stop loss at -20%
3. Set take profit at +50%
```

### **Aggressive Strategy**
```
1. Buy on limit order (specific price)
2. Set trailing stop at 15%
3. No take profit (ride the wave)
```

### **Balanced Strategy**
```
1. DCA weekly ($50/week)
2. Trailing stop at 10%
3. Take profit at +30%
```

---

## 📝 Next Steps

1. ✅ Deploy all adapters
2. ✅ Register adapters in ActionRouter
3. ✅ Approve DEX protocols
4. ✅ Initialize TokenRegistry with tokens
5. ✅ Deploy TaskChecker
6. ✅ Create example tasks
7. ✅ Build executor bot using TaskChecker

---

## 🆘 Troubleshooting

### "Price fetch failed"
- Check DEX liquidity
- Verify token pair exists
- Try different DEX router

### "Token transfer failed"
- Verify user approved adapter
- Check user balance
- Ensure task is properly funded

### "Swap failed"
- Slippage may be too tight
- DEX may have insufficient liquidity
- Check gas limits

---

**Happy Trading! 🚀**
