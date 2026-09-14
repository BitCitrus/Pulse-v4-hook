# PulseFee Hook

PulseFee 是一个 **Uniswap v4 动态手续费 Hook**。它根据最近成交量在价格轴上的**集中程度**
决定池子的 LP 费率:交易活动聚集在当前价格附近时收低费,活动都发生在别处时收高费。
同时它对外部交易收取一笔小额协议费,按池记账,由 owner 提取。

**这个 Hook 不托管任何用户资金,不持有任何仓位,也没有需要维护的状态。**
它不调用 `swap`;协议费以 PoolManager 内的 ERC-6909 claim 累积,只有提现时才调用 `unlock` 兑换。
普通用户照常向池子提供流动性和交易,不需要通过本合约做任何事。
支持 ERC20/ERC20 和原生币/ERC20 池;提现由 PoolManager 直接转给收款人,Hook 无需接收原生币。

## 项目如何工作

| 部分 | 行为 |
|---|---|
| 动态 LP 费 | 按交易结束后的 tick 记录衰减成交量,由中心桶及相邻四个桶的相对分布计算费率,覆盖池子的 LP 费 |
| 费率刷新 | **每个区块的第一笔交易自动重算**并缓存,同区块内后续交易复用。无需任何人维护 |
| 协议收入 | 对外部交易收取额外协议费并铸造 ERC-6909 claim,按池独立记账,由 owner 兑换提取 |
| 暂停开关 | owner 可停止收取协议费。**不会阻断任何交易** |

费率公式(`c` 为当前可用 tick,`s` 为 tickSpacing,`L` 为衰减后全局成交量):

```text
local = V[c-2s] + V[c-s] + 3×V[c] + V[c+s] + V[c+2s]

L == 0           -> MIN_FEE          无任何近期成交,没有逆向选择信号
L > 0, local = 0 -> MAX_FEE          有成交但全部远离当前价格
其他             -> clamp(L × C / local, MIN_FEE, MAX_FEE)
```

## 交换路径上没有代币转账

协议费通过 `POOL_MANAGER.mint` 计提为 claim,而不是当场 `take` 成真实代币。
这意味着**代币自身的转账逻辑无法影响池子里任何一笔交易能否成交**。

如果按旧写法在 `afterSwap` 里 `take`,一个会拒绝转账给 Hook 的代币
(USDC、USDT 都能冻结任意地址)就会让**该池所有交易全部 revert**——
包括跟这个 Hook 的收入毫无关系的普通交易者和普通 LP。

这个性质由 [BlacklistingToken.t.sol](test/integration/BlacklistingToken.t.sol) 钉住。
决策依据与实测数据见[架构说明](docs/refactor.md#为什么用-erc-6909-claim-而不是-take)。

## 费用边界

动态 LP 费作用于同池所有 LP,由 `MIN_FEE`、`MAX_FEE`、`FEE_CONSTANT_C` 三个不可变构造参数约束。

额外协议费在 `block.basefee > 0` 时为 1bp 加最多 30bp 的 gas-price 项,
**合计最多 31bp(0.31%)**;`block.basefee == 0` 时整个额外协议费为零。

成交量信号衡量的是交易在价格区间上的**相对**集中程度:把所有成交量按同一倍数放大不改变费率。
把成交量集中到中心桶时,未裁剪费率趋近 `C / 3`——**这就是刷量者能把费率压到的实际地板**,
选 `C` 时必须考虑这一点。

## 历史:曾经的金库已被移除

早期版本包含一个共享窄区间流动性金库(NTick)。它已被**完整移除**,原因是实测发现:

- 金库的再平衡会在**调用者操纵出来的价格上强制换币**,可被单笔交易零风险套取 TVL 的 2.8%
- 即便修掉原子套利,维护本身在趋势行情里是**亏钱的**:同一条价格路径上,
  开启 keeper 的 LP 只保住 HODL 价值的 42%,关闭 keeper 则保住 99.8%

详细的测量与结论见[审查记录](REVIEW-2026-09-13.md)。金库相关代码可从 git 历史恢复,
但**不建议在没有解决上述经济问题前重新引入**。

## 开始阅读

| 文档 | 用途 |
|---|---|
| [SPEC.md](SPEC.md) | 单位、费率公式、协议费、权限与当前保证的边界 |
| [架构说明](docs/refactor.md) | 模块职责、调用边界与关键取舍 |
| [部署与接入](docs/launch.md) | 环境参数、部署流程、前端与索引器接入 |
| [测试与验证](docs/testing.md) | 可复现命令、工具链与当前测试记录 |
| [Gas 测量](test/gas/README.md) | 测量方法与实测数据 |
| [后续工作](TODO.md) | 已完成工作与上线前尚需完成的验证 |
| [历史归档](docs/history/) | 早期审查、金库回归记录与奖励池设计草案,仅供理解背景 |

## 本地构建

使用 Foundry **v1.5.1**、Solidity **0.8.26**,编译配置为 Cancun、via IR、optimizer 200 runs。

```sh
git submodule update --init --recursive
forge fmt --check src test script
forge build --skip test
forge build --sizes --skip test --skip script
forge test -vv
```

最新本地回归为 **76 项通过,0 失败、0 跳过**,Hook 部署尺寸 **8,051 字节**(上限 24,576)。
这些记录覆盖本地模型,不包含目标链部署、所有代币行为或费率参数的经济验证。
