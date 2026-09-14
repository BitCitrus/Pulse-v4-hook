# PulseFee Hook

[English](README.md) | **简体中文**

PulseFee 是一个 **Uniswap v4 动态手续费 Hook**。它根据近期成交量在不同价格 tick 上的分布调整池子的 LP 费率：成交量集中在当前价格附近时，费率通常较低；集中在其他位置时，费率较高。

Hook 还会收取一笔归项目所有的独立附加费，支持 ERC20/ERC20 和原生币/ERC20 池。LP 通过标准 Uniswap v4 接口管理仓位，费率更新则随交换自动执行。

## 功能概览

| 部分 | 行为 |
|---|---|
| 成交量记录 | 每笔交换更新池子的全局成交量，以及交换结束时所在的可用 tick 桶，以配置的基础币计量。 |
| 动态 LP 费 | 读取附近五个 tick 桶，中心桶的权重为三。 |
| 费率刷新 | 初始化时使用 `MIN_FEE`，此后每个新区块的第一笔交换重新计算，同区块内后续交换复用缓存费率。 |
| 收入记账 | 在 PoolManager 内累积 ERC-6909 claim，按池、按币种分别记录收入。 |
| 收入提取 | owner 兑换累计 claim，由 PoolManager 将底层资产直接转给收款人。 |
| 暂停开关 | owner 可以停止收取 Hook 附加费，LP 费率计算和交换功能仍保持开启。 |

## 动态 LP 费

设 `c` 为当前可用 tick，`s` 为池子的 `tickSpacing`，`V[t]` 为 tick 桶 `t` 中衰减后的成交量，`L` 为衰减后的全局成交量：

```text
local = V[c-2s] + V[c-s] + 3*V[c] + V[c+s] + V[c+2s]

L == 0          -> MIN_FEE
L > 0, local=0  -> MAX_FEE
otherwise       -> clamp(floor(L * C / local), MIN_FEE, MAX_FEE)
```

每笔交换取选定基础币数量的绝对值，计入全局桶和交易结束时所在的可用 tick 桶。可用 tick 为 `floor(currentTick / tickSpacing) * tickSpacing`，负数同样向下取整。跨越多个 tick 的交易，其成交量记录在最终桶中。

成交量每经过一个 UTC 整点边界减半，在更新和读取时按需计算衰减；相隔 90 小时及以上时明确归零。例如，10:59 记录的成交量在 11:00 就会经过第一次衰减。存储的成交量达到 `uint128.max` 时采用饱和处理。

这个信号衡量的是**相对集中程度**。除取整、饱和和截断等边界影响外，把全部成交量同比放大不会改变比例。当近期所有成交量都集中在中心桶时，未裁剪费率为 `floor(C / 3)`。

### 示例配置

[`.env.example`](.env.example) 中的默认值为：

| 参数 | 数值 | 含义 |
|---|---:|---|
| `MIN_FEE` | 100 pips | LP 费率下限为 1 bp / 0.01% |
| `MAX_FEE` | 3,000 pips | LP 费率上限为 30 bp / 0.30% |
| `FEE_CONSTANT_C` | 300 | 缩放动态费率公式 |
| `TICK_SPACING` | 30 | 建池时选定的 tick 间距 |
| `BASE_TOKEN_IS_TOKEN0` | `true` | 使用按地址排序后的 token0 计量成交量 |

一个 pip 为百万分之一；**100 pips = 1 bp = 0.01%**。当 `C = 300` 且全部成交量位于中心桶时，费率为 `300 / 3 = 100` pips。费率上下限、`C` 和基础币选择在 Hook 部署后不可修改，由该 Hook 服务的各池共用。

## Hook 附加费

这笔费用独立于 LP 费和 Uniswap core 自己的协议费。收费开启且 `block.basefee > 0` 时：

```text
hookFeePips = 100 + min(3000, floor(100 * tx.gasprice / block.basefee))
hookFee     = floor(abs(unspecifiedDelta) * hookFeePips / 1_000_000)
```

精确输入交换从输出币收取，精确输出交换从输入币收取。当 `tx.gasprice == block.basefee` 时，附加费为 **2 bp**；最高为 **31 bp / 0.31%**。暂停收费或 `block.basefee == 0` 时，这笔附加费为零。

报价模拟与实际执行需要考虑 Gas 价格依赖，因为不同的交易环境可能产生不同的附加费。

## 收入保管与权限

交换过程中，Hook 调用 `PoolManager.mint` 铸造 ERC-6909 claim。底层资产留在 PoolManager 内，Hook 返回的 delta 向交易者收取对应费用。对每种币，Hook 持有的 claim 为各池该币种的累计收入提供兑换凭证。

owner 调用 `withdrawProtocolRevenue` 提取收入。Hook 清空对应池的收入记录，打开 PoolManager 的 unlock 回调，销毁 claim，再将底层资产直接转给收款人。提现失败会回滚相应的账本与 claim 变更。

因此，收费时无需在交换过程中向 Hook 转移代币。正常交换结算和收入提现仍然依赖代币自身的转账行为。[BlacklistingToken.t.sol](test/integration/BlacklistingToken.t.sol) 覆盖了代币仅拒绝向 Hook 地址转账时，claim 收费仍能工作的场景。

owner 可以暂停或恢复附加费、提取累计收入，以及转移或放弃所有权。Hook 没有升级机制，不持有 LP 仓位，也没有供 owner 提取 LP 本金的函数。交换回调接受空 `hookData`。

## 构建与测试

使用 **Foundry v1.5.1** 和 **Solidity 0.8.26**。仓库以 Cancun 为目标，启用 via IR，优化器运行次数为 200，每项模糊测试运行 1,000 次。

在仓库根目录执行：

```sh
git submodule update --init --recursive
forge fmt --check src test script
forge build --skip test
forge build --sizes --skip test --skip script
forge test -vv
```

当前验证结果为 **76 项测试通过，0 失败、0 跳过**。Hook 部署后的字节码为 **8,051 字节**，低于 24,576 字节上限。测试覆盖原生币结算、claim 与收入账本的一致性、提现回滚、带符号金额边界，以及三个共享币种的池中执行 300 次交换后提取收入的完整流程。

[GitHub Actions](.github/workflows/contracts.yml) 会在 push 和 PR 时执行格式、构建、尺寸及测试检查。详细结果见[测试说明](docs/testing.md)与 [Gas 测量](test/gas/README.md)。

## 部署与接入

从 [`.env.example`](.env.example) 和[部署指南](docs/launch.md)开始，填写目标链的 PoolManager、管理员与代币地址，并核对初始价格和费率参数。

部署脚本通过 CREATE2 搜索 Hook 地址并初始化池子。地址的**最低 14 位必须满足权限掩码 `0x10C4`**，池子必须使用动态费用标志 **`0x800000`**。流动性需在初始化后另外添加。

## 模型适用范围

费率由当前价格附近的成交量分布决定，不会直接区分普通交易与套利交易，也尚未证明 LP 净收益优于固定费率池。tick 间距、成交量分布与衰减都会影响信号，示例参数仍需通过市场数据验证。

本地测试覆盖上述行为。目标链配置、路由接入和非标准代币行为需要分别验证。[行为规范](SPEC.md)和[后续工作](TODO.md)记录了当前范围。

## 延伸阅读

以下详细文档目前以中文提供。

| 文档 | 内容 |
|---|---|
| [行为规范](SPEC.md) | 单位、费率公式、权限与行为边界 |
| [架构说明](docs/refactor.md) | 模块、调用边界与设计取舍 |
| [部署与接入](docs/launch.md) | 参数配置、部署、前端与索引器接入 |
| [测试与验证](docs/testing.md) | 命令、覆盖范围与结果 |
| [Gas 测量](test/gas/README.md) | 测量方法与结果 |
| [后续工作](TODO.md) | 待完成的实现与验证工作 |
