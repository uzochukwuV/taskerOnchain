# 🚀 Deployment Guide - Task Automation System

## Prerequisites

### 1. Get Testnet Tokens
- **Network**: Passet Hub Testnet (temporary)
- **RPC**: `https://testnet-passet-hub-eth-rpc.polkadot.io`
- **Faucet**: Get PAS tokens from [Polkadot Faucet](https://faucet.polkadot.io/)

### 2. Set Environment Variables

```bash
# Set your private key
npx hardhat vars set TEST_ACC_PRIVATE_KEY

# You'll be prompted to enter your private key
# IMPORTANT: Never commit your private key to git!
```

### 3. Verify Network Configuration

Your `hardhat.config.ts` is already configured for Passet Hub:

```typescript
polkadotHubTestnet: {
    polkavm: true,
    url: 'https://testnet-passet-hub-eth-rpc.polkadot.io',
    accounts: vars.has('TEST_ACC_PRIVATE_KEY') ? [vars.get('TEST_ACC_PRIVATE_KEY')] : [],
}
```

---

## Deployment Steps

### Step 1: Install Dependencies (✅ Done)

```bash
npm install
```

### Step 2: Compile Contracts

```bash
npx hardhat compile
```

**Expected Output**: Compiled 7 contracts successfully

### Step 3: Run Tests (Local Network)

```bash
npx hardhat test
```

**Expected**: All tests should pass

### Step 4: Deploy to Passet Hub Testnet

```bash
npx hardhat ignition deploy ignition/modules/TaskAutomationSystem.ts --network polkadotHubTestnet
```

**This will deploy all contracts in order:**
1. PaymentEscrow
2. ConditionChecker
3. ActionRouter
4. ExecutorManager
5. ReputationSystem
6. DynamicTaskRegistry
7. UniswapLimitOrderAdapter

**And configure them automatically:**
- Link all contracts together
- Set TaskRegistry as authorized updater
- Configure platform fee (1%)

### Step 5: Save Deployed Addresses

After deployment, addresses will be saved to:
```
ignition/deployments/<chain-id>/deployed_addresses.json
```

**Save these addresses** - you'll need them for:
- Frontend integration
- Executor scripts
- Task creation

---

## Post-Deployment Configuration

### 1. Approve Protocols

Before users can create tasks, you need to approve protocols:

```typescript
// Example: Approve StellaSwap on Moonbeam
await taskRegistry.approveProtocol(STELLASWAP_ROUTER_ADDRESS);

// Or batch approve multiple
await taskRegistry.batchApproveProtocols([
    STELLASWAP_ROUTER,
    BEAMSWAP_ROUTER,
    // ... other DEX routers
]);
```

### 2. Register DEX Routers in Adapter

```typescript
await uniswapAdapter.addRouter(STELLASWAP_ROUTER);
await actionRouter.registerAdapter(STELLASWAP_ROUTER, uniswapAdapter.address);
await actionRouter.approveProtocol(STELLASWAP_ROUTER);
```

### 3. Set Up Price Feeds (Optional)

For price-based conditions:

```typescript
// Example: GLMR/USD price feed
await conditionChecker.setPriceFeed(
    WGLMR_ADDRESS,
    CHAINLINK_GLMR_USD_FEED
);
```

---

## Testing Deployed Contracts

### Create Your First Task

```bash
npx hardhat run scripts/interactLimitOrder.ts --network polkadotHubTestnet
```

### Register as Executor

```typescript
const executorManager = await ethers.getContractAt(
    "ExecutorManager",
    EXECUTOR_MANAGER_ADDRESS
);

await executorManager.registerExecutor();
console.log("✅ Registered as executor!");
```

### Execute a Task

```typescript
await executorManager.attemptExecute(taskId);
console.log("✅ Task executed!");
```

---

## Common DEX Routers on Moonbeam/Passet Hub

### Moonbeam Mainnet
- **StellaSwap**: `0x70085a09D30D6f8C4ecF6eE10120d1847383BB57`
- **BeamSwap**: `0x96b244391D98B62D19aE89b1A4dCcf0fc56970C7`
- **SolarBeam**: `0xAA30eF758139ae4a7f798112902Bf6d65612045f`

### Passet Hub Testnet
- You'll need to find or deploy test DEX routers
- Consider deploying a mock Uniswap V2 router for testing

---

## Environment Variables Checklist

Create a `.env` file (optional, for scripts):

```env
# Deployment Account
TEST_ACC_PRIVATE_KEY=your_private_key_here

# Deployed Contract Addresses (fill after deployment)
TASK_REGISTRY_ADDRESS=0x...
EXECUTOR_MANAGER_ADDRESS=0x...
ACTION_ROUTER_ADDRESS=0x...
PAYMENT_ESCROW_ADDRESS=0x...
REPUTATION_SYSTEM_ADDRESS=0x...
CONDITION_CHECKER_ADDRESS=0x...
UNISWAP_ADAPTER_ADDRESS=0x...

# DEX Configuration
STELLASWAP_ROUTER=0x70085a09D30D6f8C4ecF6eE10120d1847383BB57
BEAMSWAP_ROUTER=0x96b244391D98B62D19aE89b1A4dCcf0fc56970C7

# Tokens (Moonbeam examples)
WGLMR=0xAcc15dC74880C9944775448304B263D191c6077F
USDC=0x931715FEE2d06333043d11F658C8CE934aC61D0c
USDT=0xeFAeeE334F0Fd1712f9a8cc375f427D9Cdd40d73

# Price Feeds (Chainlink)
GLMR_USD_FEED=0x...
```

---

## Gas Estimates

| Operation | Estimated Gas |
|-----------|--------------|
| Deploy All Contracts | ~8,000,000 |
| Create Task | ~150,000 |
| Execute Task (simple) | ~100,000 |
| Register Executor | ~50,000 |
| Cancel Task | ~60,000 |

**Estimated Total Deployment Cost**: ~0.8 - 1.0 PAS tokens (testnet)

---

## Troubleshooting

### Issue: "Compiler download failed"
**Solution**: Check internet connection or use cached compiler

### Issue: "Insufficient funds"
**Solution**: Get more PAS tokens from faucet

### Issue: "Protocol not approved"
**Solution**: Call `approveProtocol()` after deployment

### Issue: "Task locked by another executor"
**Solution**: Wait 30 seconds for lock to expire

---

## Next Steps After Deployment

1. ✅ Verify contracts on block explorer (if available)
2. ✅ Create documentation for users
3. ✅ Build frontend interface
4. ✅ Create executor bot
5. ✅ Set up monitoring/alerts
6. ✅ Plan mainnet migration when Passet Hub → Paseo Asset Hub

---

## Security Notes

⚠️ **Important Reminders:**

1. **Never share your private key**
2. **Test thoroughly on testnet** before mainnet
3. **Audit contracts** before handling real value
4. **Monitor for suspicious activity**
5. **Keep emergency functions available** (pause, blacklist)
6. **Set reasonable gas limits** to prevent DoS
7. **Whitelist protocols carefully**

---

## Support & Resources

- **Polkadot Docs**: https://docs.polkadot.com/
- **Hardhat Docs**: https://hardhat.org/
- **Moonbeam Docs**: https://docs.moonbeam.network/
- **Project README**: `TASK_AUTOMATION_README.md`

---

**Built with ❤️ on Polkadot**
