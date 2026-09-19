# 架构说明

当前行为以 [SPEC](../SPEC.md) 为准。部署步骤见[部署与接入](launch.md)。

## 模块职责

合约按"状态 → 策略 → 接口"分三层,共 9 个源文件。

| 文件 | 职责 |
|---|---|
| [HookBase.sol](../src/HookBase.sol) | 共享状态:PoolManager 引用、每池初始化标记、暂停开关、每池协议收入 |
| [FeeModule.sol](../src/FeeModule.sol) | 成交量记账、费率计算与每区块缓存、协议费收取 |
| [PulseV4Hook.sol](../src/PulseV4Hook.sol) | IHooks 回调面、构造校验、owner 操作、收入兑换回调、view 查询 |
| [lib/FeePolicy.sol](../src/lib/FeePolicy.sol) | 纯函数:动态费公式与协议费公式 |
| [lib/VolumeDecayLib.sol](../src/lib/VolumeDecayLib.sol) | 纯函数:整小时 `0.5^h` 衰减,Q96 二进制乘方 |
| [lib/TickLib.sol](../src/lib/TickLib.sol) | 纯函数:向负无穷取整的可用 tick 换算 |
| [lib/HookConstants.sol](../src/lib/HookConstants.sol) | 协议费常量与 v4 费率标志 |
| [lib/PulseV4HookErrors.sol](../src/lib/PulseV4HookErrors.sol) | 错误定义 |
| [lib/PulseV4HookEvents.sol](../src/lib/PulseV4HookEvents.sol) | 事件定义 |

主合约为 `PulseV4Hook is IHooks, IUnlockCallback, Ownable, FeeModule`,其中 `FeeModule is HookBase`。

## 为什么把公式抽成纯函数库

`FeePolicy` 和 `VolumeDecayLib` 不读任何存储,因此可以直接做单元测试和模糊测试,
不需要搭 PoolManager。费率公式是这个项目现在唯一的核心逻辑,把它和存储解耦是有意的。

## 一次交换如何完成

```text
PoolManager.swap
  └─ beforeSwap(key, ...)
       ├─ 校验 msg.sender == PoolManager,该池已初始化
       ├─ _feeForSwap: 本区块已刷新则读缓存,否则重算并写入
       └─ 返回 fee | OVERRIDE_FEE_FLAG,覆盖池子的 LP 费

     (core 执行交换)

  └─ afterSwap(key, params, delta, ...)
       ├─ _collectProtocolFee: 暂停或 basefee == 0 则为 0;
       │    否则 mint 未指定币种的 ERC-6909 claim,计入该池 protocolRevenue
       ├─ _updateVolume: 按交易结束后的可用 tick 更新全局桶和该 tick 桶
       └─ 返回正的 hookDeltaUnspecified
```

Hook 不调用 `swap`,收费时通过 `mint` 把协议费留在 PoolManager 内,不触发实际代币转账。
owner 提现先清零该池收入,再调用 `unlock`;PoolManager 回调 Hook 的 `unlockCallback`,
按币种执行 `burn` + `take`,底层 ERC20 或原生币直接付给 recipient。
兑换按 `int128.max` 分批,每批 delta 配平后才继续。任一转账失败将回滚整个提现。
`IUnlockCallback` 只用于这一条路径。

## 为什么用 ERC-6909 claim 而不是 take

早期实现在 `afterSwap` 里调用 `POOL_MANAGER.take(currency, address(this), fee)`,
把手续费当场转成真实代币放进 Hook。问题在于:**这让代币的 `transfer` 逻辑握着整个池子的生杀大权。**

USDC、USDT 这类可冻结账户的代币,只要把 Hook 地址拉黑,`take` 就会 revert——
而它在 `afterSwap` 里,于是**该池所有交易全部失败**,包括跟这个 Hook 的收入毫无关系的
普通交易者和普通 LP。转账税代币、带回调的代币同理。

改用 `mint` 之后,收费只是 manager 内部的一次记账,交换路径上不再调用任何代币。
代币再古怪也只能影响 owner 什么时候能把钱取出来,影响不了别人能不能交易。

这个决策的依据是**活性,不是 gas**。实测在简单代币上每笔交换只省约 446 gas:

| | take | mint |
|---|---:|---:|
| 同 tick、同一小时交换 | 162,525 | 162,079 |

回归测试 [BlacklistingToken.t.sol](../test/integration/BlacklistingToken.t.sol) 钉住了这个性质:
把 `mint` 换回 `take`,该测试立刻以 `BLACKLISTED` 失败。改动收费路径前请先看这个测试。

顺带的结果是 Hook 不需要 `receive()`:提取时代币由 manager 直接发给 recipient,
原生币从不经过 Hook。

## 关键取舍

**按合约可见块号刷新。** `block.number` 变化后的首笔交换重算费用，其余交换复用缓存。
Robinhood 上它是估算的 L1 块号，多个 L2 区块可以共享费率；成交量衰减独立使用时间戳。
同一缓存区间内刷量不会立即改变交易费率，跨区间操纵仍需经济分析。

**暂停不阻断交易。** `afterSwap` 中 revert 会瘫痪整个池子。暂停因此只让协议费归零。

**不实现 `beforeSwapReturnDelta`。** 协议费从 `afterSwap` 的 `hookDeltaUnspecified` 收取,
附加费由返回 delta 计入交易者的结算金额，路由器需将其纳入滑点限额。

**提取路径会打开 manager 锁。** 把 claim 换回真实代币必须 `burn` + `take`,两者都要求 manager 处于
unlocked 状态,因此 Hook 保留了 `unlockCallback`。这是合约里唯一会开锁的地方,且是 `onlyOwner`。
代价见 [SPEC §5.1](../SPEC.md#51-提取流程)。

## 与早期版本的差异

早期版本包含共享窄区间流动性金库、ERC721 份额凭证、keeper 奖励池和再平衡引擎,
共 21 个源文件、2085 行。这些**全部已移除**,原因见 [审查记录](../REVIEW-2026-09-13.md)。

移除后消失的不只是代码,还有整类失败模式:没有金库可被强制在操纵价格上换币,
没有份额可被稀释,没有结算预算可被跨池串用,没有需要被激励的维护工作。

早期代码可从 git 历史恢复。金库的存储布局、接口和事件与当前版本完全不兼容。
