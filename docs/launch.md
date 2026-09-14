# 部署与接入

行为定义见 [SPEC](../SPEC.md),模块结构见[架构说明](refactor.md)。

## 1. 准备环境

需要 Foundry **v1.5.1**(Solidity 0.8.26、Cancun、via IR、optimizer 200 runs)。

```sh
git submodule update --init --recursive
forge build --skip test
forge test
```

目标链上必须已存在:

- Uniswap v4 **PoolManager**
- 确定性 CREATE2 代理 `0x4e59b44847b379578588920cA78FbF26c0B4956C`(部署脚本会检查)

## 2. 配置参数

复制 `.env.example` 为 `.env` 并填写。所有费率参数**部署后不可修改**,选错只能重新部署。

| 变量 | 说明 |
|---|---|
| `POOL_MANAGER_ADDRESS` | 目标链的 v4 PoolManager |
| `ADMIN_ADDRESS` | Hook owner。可暂停协议费、提取收入 |
| `MIN_FEE` / `MAX_FEE` | LP 费率下限与上限,pips。要求 `MIN_FEE <= MAX_FEE < 1000000` |
| `FEE_CONSTANT_C` | 费率公式系数,`<= 2^128 - 1` |
| `BASE_TOKEN_IS_TOKEN0` | 成交量以哪一侧计量。**指排序后的 token0** |
| `TOKEN0_ADDRESS` / `TOKEN1_ADDRESS` | 脚本会自动按地址大小排序 |
| `TICK_SPACING` | 池子 tick 间距 |
| `INITIAL_SQRT_PRICE` | 初始价格,`sqrtPriceX96` 格式 |

### 选 C 的注意事项

把成交量集中到当前 tick 时,未裁剪费率趋近 **`C / 3`**。这是刷量者能把费率压到的实际地板。
`MIN_FEE` 只在"近期任何地方都没有成交"(`L == 0`)这一种退化情况下生效,所以
**实际生效的下限是 `max(MIN_FEE, C / 3)`**。把 `MIN_FEE` 设在 `C / 3` 之下不会有任何效果;
要抬高交易中的实际下限,只能提高 `C`,或把 `MIN_FEE` 提到 `C / 3` 以上。

中心桶的 `3×` 权重就是这个地板的来源:它让 `local` 最多只能到 `L` 的三倍。改动权重会直接移动地板,
`test_rawFeeFloorIsCOverThreeAndScaleInvariant` 会在权重变化时立刻失败。

`1:1` 价格对应 `INITIAL_SQRT_PRICE=79228162514264337593543950336`(即 `2^96`)。
注意排序会改变哪个代币是 token0,`BASE_TOKEN_IS_TOKEN0` 必须按**排序后**的结果填写。

## 3. 部署

```sh
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
```

脚本会:

1. 用 `HookMiner` 挖出低 14 位为 `0x10C4` 的 CREATE2 salt
2. 通过确定性代理部署 Hook,并校验实际地址与预测一致
3. 以 `fee = LPFeeLibrary.DYNAMIC_FEE_FLAG` 初始化池子

池子的 `fee` 字段**必须**是动态费标志 `0x800000`,否则 `afterInitialize` 会以
`DynamicFeeRequired` 回退。构造函数会调用 `Hooks.validateHookPermissions`,
salt 挖错会在部署时立即失败,而不是等到初始化时。

同一个 Hook 可以服务多个池:对新池直接调用 `PoolManager.initialize` 即可,
无需重新部署 Hook。每池的成交量、缓存费率和协议收入相互独立。

## 4. 交易者与 LP 接入

**不需要任何接入工作。** 这个 Hook 不托管资金、没有存取款接口。

- 交易者照常通过任意 v4 路由器交换
- LP 照常通过 `PoolManager.modifyLiquidity` 或 position manager 提供流动性
- 实际支付的 LP 费率由 Hook 在 `beforeSwap` 覆盖,可用 `computeFee(key)` 预估

**不需要 keeper。** 费率由每个区块的第一笔交易自动重算,没有需要定时调用的函数。

## 5. 索引器与前端

| 读取项 | 接口 |
|---|---|
| 当前实时费率 | `computeFee(key)` — 只读重算,不写缓存 |
| 本区块生效费率 | `cachedFee(poolId)` |
| 上次刷新区块 | `lastFeeRefreshBlock(poolId)` |
| 缓存与实时对比 | `getFeeInfo(key)` 返回 `(cached, computed)` |
| 成交量 | `globalVolume(poolId)`、`tickVolume(poolId, tick)` — **返回锚点处的存储值,未按当前时间衰减** |
| 锚点时间 | `globalVolumeTimestamp`、`tickVolumeTimestamp` |
| 协议收入 | `protocolRevenue0(poolId)`、`protocolRevenue1(poolId)` |
| 按币种合计 claim | `PoolManager.balanceOf(hook, currencyId)`,currencyId 为币种地址转 uint256,原生币为 0 |

展示成交量时若要显示衰减后的值,需要在链下用 `0.8^h` 自行计算,`h` 为当前时间与锚点相隔的**整小时数**,
`h >= 90` 时归零。直接展示 getter 返回值会高估近期活跃度。

## 6. 运营

| 操作 | 命令 |
|---|---|
| 暂停协议费 | owner 调用 `setPaused(true)`。交易不受影响 |
| 提取收入 | owner 调用 `withdrawProtocolRevenue(key, recipient)`,按池执行 |

协议费以 ERC-6909 claim 保存在 PoolManager。提现需在 PoolManager 未解锁时发起,
由 Hook 在回调中兑换并直接付给 recipient;原生币收款人需要能够接收 ETH。任一币种转账失败则整笔回滚。
收入查询和事件接口保持不变,但集成方应读取 claim 余额,不再以 Hook 的 ERC20/ETH 余额表示可提收入。

owner 无法修改费率参数、无法阻断交易、无法触碰 LP 的资金——Hook 里没有 LP 的资金。
