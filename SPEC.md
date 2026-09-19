# 行为规范

本文对应当前源码。操作步骤见[部署与接入](docs/launch.md),实现结构见[架构说明](docs/refactor.md)。
早期版本(含已移除的金库)的审查结论保留在[历史归档](docs/history/),不作为当前接口说明。

## 1. 标识、单位与固定参数

`PoolKey` 由 `currency0`、`currency1`、`fee`、`tickSpacing`、`hooks` 五个字段构成;`PoolId` 是它的标识。
同一 Hook 可服务多个池,每池独立记录成交量、缓存费率和协议收入。

| 名称 | 单位或含义 |
|---|---|
| `amount0`、`amount1` | 代币最小单位,不统一成 18 位精度 |
| `sqrtPriceX96` | `sqrt(currency1 原始数量 / currency0 原始数量) × 2^96` |
| `tickSpacing` | 可用 tick 的间隔 |
| 费率 pips | 分母为 1,000,000;100 pips = 1bp = 0.01% |
| 时间 | Unix 秒;成交量按 UTC 整点划分 |

构造参数包括 PoolManager、owner、基础币选择、`MIN_FEE`、`MAX_FEE`、`FEE_CONSTANT_C`。
后三项及 `BASE_TOKEN_IS_TOKEN0` 对该 Hook 的所有池统一生效,**且不可修改**。
要求 manager 地址存在代码、owner 非零、`MIN_FEE <= MAX_FEE < 1_000_000`、`C <= uint128.max`。

Hook 地址低 14 位必须恰为 `0x10C4`,启用 `afterInitialize`、`beforeSwap`、`afterSwap` 和
`afterSwapReturnDelta`。构造时验证地址权限;初始化仅接受动态费池 `fee = 0x800000`。
初始化后该池缓存费率为 `MIN_FEE`,刷新区块为初始化区块。

## 2. 资金归属

本 Hook **不托管用户资金**。它唯一的权益是自己收取的协议费,而这笔钱**不以代币形式存放在 Hook 里**,
而是留在 PoolManager 中,以 **ERC-6909 claim** 的形式记在 Hook 名下。

```text
PoolManager.balanceOf(hook, currency.toId())  =  Σ 各池该币种的 protocolRevenue
Hook 自身的 ERC20 余额                        =  0
```

currency id 就是代币地址本身(`uint160(address)`),原生币的 id 为 `0`。
两个池共用同一代币时,它们共享同一份 claim 余额,但各自的 `protocolRevenue` 记账独立;
提空一个池不影响另一个池的可提取额。

选择 claim 而非在交换中 `take()` 真实代币,是为了让**交换路径上不出现任何代币外部调用**,
理由见[架构说明](docs/refactor.md#为什么用-erc-6909-claim-而不是-take)。

Hook 在**交换路径上**从不调用 `POOL_MANAGER.swap` 或 `POOL_MANAGER.unlock`,也不持有任何流动性仓位。
唯一会打开 manager 锁的地方是 owner 提取收入(见 §5)。

Hook 没有 `receive()`,**直接向它转原生币会 revert**。直接转入的 ERC20 不会被任何记账识别,
也没有救援函数,将永久滞留——不要向 Hook 地址转账。

## 3. 成交量与动态 LP 费

代码:[FeeModule](src/FeeModule.sol)、[VolumeDecayLib](src/lib/VolumeDecayLib.sol)、[FeePolicy](src/lib/FeePolicy.sol)。

外部交换后,从 manager 提供的 swap delta 取基础币数量的绝对值。基础币为 token0 或 token1,由构造参数决定。
取负前扩宽到 int256,因此 `int128.min` 可表示为正的 `2^127`。

当测得数量大于零时,只更新该池两个桶:全局桶,以及交易结束后所在的可用 tick 桶。
可用 tick 为 `floor(currentTick / spacing) × spacing`,负数也向负无穷取整。
跨越多个 tick 的交易全部归入最后一个桶,不沿途分摊,也不复制到相邻桶。

每个桶存储 uint128 数量和 uint48 小时锚点。更新前先衰减旧值,再加新值;超过 uint128 上限时饱和为上限。
锚点是本次更新所在 UTC 小时的起点。衰减按整小时使用 **`0.5^h`**,以 Q96 乘方并向下取整;
相隔 **90 小时或以上直接归零**,这是明确的截断规则(0.5 下 27 小时后已不足 1e-8,截断点只是保守上界)。

**半衰期恰好 1 小时**,费率实际参考的是最近约 3~6 小时的成交分布,更早的活动几乎不影响结果:

| 经过 | 剩余 |
|---:|---:|
| 1 小时 | 50% |
| 3 小时 | 12.5% |
| 6 小时 | 1.6% |
| 12 小时 | 0.024% |

整点划分意味着 10:59:59 的交易,到 11:00:00 即跨过一个衰减边界。
`globalVolume`、`tickVolume` 返回锚点处的存储值;费率计算才按当前时间读取衰减后的值。
独立桶的取整和饱和不保证全局存储值严格等于逐桶相加。

设当前可用 tick 为 `c`,间距为 `s`,衰减后的全局量为 `L`:

```text
local = V[c - 2s] + V[c - s] + 3 × V[c] + V[c + s] + V[c + 2s]

L == 0          -> MIN_FEE
L > 0, local=0  -> MAX_FEE
其他            -> clamp(floor(L × C / local), MIN_FEE, MAX_FEE)
```

成交量同比放大时,比例原则上不变;舍入、桶龄、饱和和截断会影响边界结果。
所有量集中在中心桶时,未裁剪费率约为 `C / 3`,并非交易越多费率必然越高。

### 3.1 每区块刷新

`beforeSwap` 调用 `_feeForSwap`:

- 若该池 `lastFeeRefreshBlock == block.number`,直接使用缓存值
- 否则重算、写入缓存、记录当前区块号,并发出 `FeeRefreshed`

这里的区块指合约可见的 `block.number`；Robinhood 上为估算的 L1 块号，多个 L2 区块可以共享缓存。
成交量衰减独立使用 `block.timestamp`。该块号变化后的第一笔交易重算，后续交易使用同一费率。
没有外部刷新入口或 keeper；同一缓存区间内改变成交量不会立刻改变交易使用的费率。
这一规则不保证抵抗跨缓存区间的成交量操纵。

`computeFee` 是只读计算,不更新缓存;未初始化池返回 `MIN_FEE`。

## 4. Hook 额外协议费

这项费用独立于动态 LP 费,也不包含 Uniswap core 自己可能收取的协议费。

```text
paused == true:
    hookFee = 0

basefee == 0:
    hookFee = 0

否则:
    totalPips = min(3000, floor(tx.gasprice × 100 / block.basefee))
    hookFee = floor(abs(unspecifiedDelta) × totalPips / 1_000_000)
```

协议费总上限为 **3000 pips / 30bp / 0.30%**。gas price 等于 base fee 时,小费为零,
费率为 100 pips / 1bp / 0.01%;小费等于 base fee 时,总费率为 200 pips / 2bp / 0.02%。
费率随 gas price 与 base fee 的比例增加,gas price 达到 base fee 的 30 倍时封顶。
示例 LP 费率上限为 30bp,与协议费的标示费率合计最高为 60bp;两项费用分别按各自计费金额计算和取整。

| 交换方式 | `zeroForOne` | 额外收费币种 |
|---|---|---|
| 精确输入 | true | token1,输出侧 |
| 精确输入 | false | token0,输出侧 |
| 精确输出 | true | token0,输入侧 |
| 精确输出 | false | token1,输入侧 |

Hook 用 `mint` 为自己铸造该币种的等额 claim,并返回正的 `hookDeltaUnspecified`。
铸造产生的负 delta 与 Hook 返回的正 delta 抵消;持久保存的是 claim,每次 unlock 结束前临时 delta 必须归零。
用户最终 delta 是 manager 原始 swap delta
再扣除该币种的 Hook 费用。成交量基于原始 swap delta,不把额外协议费再次当作成交量。

原生币池的 `currency0` 为零地址。token1 换原生币的精确输入交易,以及原生币换 token1 的精确输出交易,
均以原生币收取协议费:PoolManager 为 Hook 铸造 ID 为 0 的 claim,记入 `protocolRevenue0`,由 owner 按池兑换。

`hookData` 完全由调用者控制,**Hook 从不对它分支**:没有任何可填入的值能免除协议费或跳过成交量记账。

## 5. 权限与暂停

| 操作 | 权限 | 效果 |
|---|---|---|
| `setPaused(bool)` | owner | 暂停时**不收取协议费**;不影响任何交易、不影响费率覆盖、成交量照常记录 |
| `withdrawProtocolRevenue(key, recipient)` | owner | 把该池的 token0/token1 收入赎回为真实代币,发给 `recipient`,并清零记账 |

除 owner 外,没有任何人能对本合约调用会改变状态的函数——其余状态变更只能由 PoolManager
通过 hook 回调触发。owner 无法修改费率参数、无法阻断交易、无法触碰 LP 的资金
(Hook 里没有 LP 的资金)。

**暂停刻意不会 revert 交易回调。** `afterSwap` 中 revert 会让该池所有交易失败,
把与本 Hook 收入无关的普通交易者和普通 LP 一并锁死,因此暂停采取"不收费"而非"不放行"。

### 5.1 提取流程

```text
withdrawProtocolRevenue(key, recipient)         onlyOwner
  ├─ 读取并清零 protocolRevenue0/1[poolId]      ← 先清账,后交互
  └─ POOL_MANAGER.unlock(...)
       └─ unlockCallback                        ← 只接受来自 PoolManager 的调用
            └─ 对两个币种各自:
                 while (剩余 > 0):
                   burn(hook, currency.toId(), chunk)   → delta +chunk
                   take(currency, recipient, chunk)     → delta −chunk,代币直达 recipient
```

分块是必需的:`protocolRevenue` 累积在 uint256 中,而 PoolManager 的每次 delta 记账受 `int128` 约束。
每块的 `burn`/`take` 配对在进入下一块前完成结算,因此任意金额都能提取。

代币**直接从 PoolManager 发给 `recipient`,不经过 Hook**。原生币同理,所以 Hook 不需要 `receive()`。

两点需要注意:

- 若 `recipient` 无法接收该币种(被代币拉黑、合约无 `receive()`),整笔提取回退,
  claim 与记账**完整还原**,可改用其他地址重试。
- 这是合约里**唯一会打开 manager 锁**的路径。v4 的锁是全局的,锁开着时 `recipient` 的回调
  可以操作 manager。当前是安全的:`take` 先记 delta 再外部转账,重入时 Hook 的 delta 已为 0;
  记账也已清零。但这确实把提取路径的攻击面从"一次代币转账"扩大到"一个开放的 unlock 窗口",
  选 `recipient` 时应当知道这一点。

## 6. 事件与错误

| 事件 | 触发 |
|---|---|
| `FeeRefreshed(poolId, newFee)` | 每区块首次重算费率时 |
| `VolumeUpdated(poolId, tick, volumeAmount)` | 记录成交量时 |
| `ProtocolFeeCollected(poolId, isToken0, feeAmount)` | 协议费已铸造为 claim 并计入该池收入时 |
| `ProtocolRevenueWithdrawn(poolId, recipient, amount0, amount1)` | owner 提取收入 |
| `Paused(bool)` | 开关变更 |

| 错误 | 条件 |
|---|---|
| `NotPoolManager` | 启用的 hook 回调或 `unlockCallback` 的调用者不是 PoolManager |
| `NotInitialized` | 该池未经本 Hook 初始化 |
| `AlreadyInitialized` | 重复初始化同一池 |
| `DynamicFeeRequired` | 初始化时 `fee != 0x800000` |
| `InvalidRecipient` | 提取收入时收款地址为零 |
| `InvalidPoolManager` / `InvalidFeeParameters` | 构造参数校验失败 |

## 7. 当前保证的范围

**成立的:**

- Hook 不托管用户资金、不持仓、不发起交换,没有可被操纵的执行路径
- **交换路径上没有任何代币外部调用**,因此代币的转账逻辑(黑名单、暂停、转账税)
  无法阻断池中的交易;协议费以 ERC-6909 claim 计提,失败只会推迟提取,不会影响成交
- 暂停或任何内部状态都不会使池中交易失败
- 同池的协议收入与其它池互相隔离,提空一个池不影响另一个池的可提取额
- 合约可见块号变化后首笔交易重算费率；块内冻结不保证抵抗跨块成交量操纵

**未验证的:**

- `MIN_FEE`、`MAX_FEE`、`C` 的经济合理性未用真实市场数据校准
- 刷量操纵费率的盈亏边界只有结构性分析(费率地板趋近 `C / 3`),没有量化模型
- **费率对交易毒性没有区分能力。** 实测同一时刻、同一 tick 上,良性双向成交与单边套利
  拿到的费率几乎相同(合成路径下分别为 490 与 459 pips,且方向倒挂)。原因是费率只由
  "价格在哪、周围历史成交多少"决定,`beforeSwap` 收到的 `zeroForOne` 与 `amountSpecified`
  未被使用。调整衰减率只改变费率水平,不改变这一点
- 费率对"窗口占全局成交量的比例"是**连续单调**的,`local == 0` 只是该曲线的极限,不是跳变;
  但当窗口只占全局成交量的一小部分时费率就已经贴上 `MAX_FEE`(C=300、MAX_FEE=3000 时，加权 local/L <= 10%),
  这意味着价格走进近期少有成交的区域时,下一个交易者就会被收满额。是否可取是设计选择,不是缺陷
- 未经外部安全审计
- 未在目标链用实际 PoolManager、代币和 CREATE2 工厂完成部署验证
