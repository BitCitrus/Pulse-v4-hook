# 测试与验证

行为定义见 [SPEC](../SPEC.md)。本文记录当前测试范围、复现命令与结论的边界。

## 环境与入口

Foundry **v1.5.1**、Solidity **0.8.26**、Cancun、via IR、optimizer 200 runs、fuzz 1000 runs。

```sh
git submodule update --init --recursive
forge fmt --check src test script
forge build --skip test
forge build --sizes --skip test --skip script
forge test -vv
```

测试使用**真实 PoolManager**(v4-core `Deployers`)、v4-core 测试路由器、原生币和普通 ERC20 执行交换。
部分测试只模拟 ERC20 拒绝转账,用于确认收费不触发转账、提现失败会完整回滚。
公共 fixture 为 [PulseV4HookFixture](../test/utils/PulseV4HookFixture.sol)。

## 当前结果

下表 Hook 回归测试为 **81 项通过,0 失败,0 跳过。** Hook 部署尺寸 **8,046 字节**(上限 24,576)。
该结果不包含 `test/script/` 部署预检套件及 `test/fork/` 目标链演练。
完整本地运行结果为 **106 通过、0 失败、2 跳过**：81 项 Hook 回归、25 项部署与价格测试；两个 fork 套件未配置 RPC 时在 setUp 跳过。单独启用 Robinhood fork 的结果为 **4 通过、0 失败、0 跳过**，
覆盖低层结算与正式 Universal Router、PositionManager、Permit2 的完整调用流程。
未设置 RPC 时两个 fork 套件在 setUp 跳过，默认本地检查不依赖外部网络。
工程验证区块、真实 ETH/USDG 合约地址、操作编码与运行方法见 [Robinhood 上线验证](robinhood.md)。

部署测试在同一环境变量用例中验证超宽输入、空字段、反向报价及预检/部署的一致性，避免
Foundry 进程级环境变量的并行串扰。价格测试覆盖 18/6 小数位、极小原始比例、超过 256 位的平方中间值、
反向报价与不同小数位的随机往返验证。`PRICE_E18` 不校验市场公允价。
| 套件 | 数量 | 覆盖 |
|---|---:|---|
| `PulseV4HookTest` | 15 | 每区块费率刷新、块内冻结、四种交换组合在无小费和不同小费下的准确收费、额外费封顶、暂停语义、多池收入隔离、hookData 免责探针 |
| `FeePolicyTest` | 5 | gas price 等于 base fee 时收 1bp、小数比例与金额取整、封顶边界、极端 gas 值、零 base fee、合法 gas price 范围内收费边界与单调性的模糊测试 |
| `NativeProtocolFeeTest` | 10 | 原生币池四种收费方向、原生与代币收入同时提取、直接转入原生币被拒、提取失败后 claim 与记账完整还原、recipient 重入无法二次提取、暂停与零 basefee 下的结算 |
| `VolumeDecayLibTest` | 10 | 整小时衰减、90 小时截断、Q96 乘方边界 |
| `FeeModuleTest` | 11 | 成交量守恒、整点衰减不可被频繁交易推迟、局部权重窗口、**正常未饱和状态下的 `C / 3` 原始费率地板及规模不变性** |
| `TickLibTest` | 8 | 可用 tick 向负无穷取整,含模糊测试 |
| `ProtocolClaimsTest` | 6 | claim 计提不向 Hook 转移代币、提取权限与零地址校验、伪造 unlockCallback 被拒、第二个币种转账失败时两侧完整回滚、**超过 int128 上限的累积收入可分块提取** |
| `FeeSafetyRegressionTest` | 4 | 构造参数校验、静态费池被拒、成交量只计入最终 tick |
| `VolumeGasExistingTest` / `FreshTest` | 4 | gas 测量,见 [Gas 说明](../test/gas/README.md) |
| `HookDeploymentTest` | 2 | CREATE2 挖矿与部署使用同一工厂、缺少工厂时提前失败 |
| `ReviewBoundariesTest` | 2 | `int128.min` 输入在收费与不收费两种模式下正确结算 |
| `ReviewExpectedBehaviorTest` | 2 | 两种基础币下的交换记账与钱包实际变化一致 |
| `BlacklistingTokenTest` | 1 | 拉黑 Hook 的代币无法瘫痪池子交易 |
| `EndToEndRevenueTest` | 1 | 8 个交易者在 3 个共享币种的池中执行 300 次交换,持续验证 claim 与收入账本一致,逐池提现后继续收取收入 |

## 几个值得单独说明的测试

**`NativeProtocolFeeTest`** 固定原生币协议费的完整收取与提现路径。原生币费用铸造成 ID 为 0 的 claim,
收费时 Hook 的 ETH 余额保持为零;提现时由 PoolManager 直接转给收款人。
测试同时验证钱包变化、claim 与收入记账、拒收时回滚,以及 owner 收款人重入不能重复提取收入。

**`ProtocolClaimsTest`** 在禁止 ERC20 向 Hook 转账的条件下执行真实交换并累积收费;
提现第二币种失败时,第一币种已执行的转账和全部 claim 销毁也必须回滚。
极大累计收入测试通过真实存款为 claim 提供足额底层资产,只将按池账本设置为模拟的长期累计值,
验证超过 `int128.max` 时仍能分批完整兑换。

**`test_feeIsFrozenForTheRestOfTheBlock`** 是安全性质测试,不是行为测试:它固定"同一区块内先刷量
改变成交量信号、再据此低价交易"这条路走不通。改动费率缓存逻辑时必须保证这条仍然通过。

**`test_pausedStopsProtocolFeeButNotSwaps`** 固定暂停语义:暂停只让协议费归零,
交易、费率覆盖和成交量记账全部照常。如果哪次改动让暂停开始 revert 交易,这条会失败。

**`test_swap_arbitraryHookDataBuysNoExemption`** 用三种探针数据(旧版的内部 swap sentinel 常量、
Hook 自身地址、空字节)验证没有任何 `hookData` 能免除协议费或跳过成交量记账。
早期版本曾因为把公开常量当作"内部交换"标记而存在这个漏洞。

**`test_multiPool_sharedToken_revenueStaysSeparatelyRedeemable`** 验证两个池共用 token0 收入时,
提空一个池不影响另一个池的可提取额——Hook 只持有一份 token0 claim 余额,记账必须能覆盖两者。

**`ReviewBoundariesTest`** 使用[分次结算路由器](../test/utils/SplitSettlementRouter.sol):
core 的单次正向结算受 int128 范围约束,需要拆分还款才能真正验证 `2^127` 输入。
这个结果不代表任意外部路由器都支持同样的极值。

## 结论的边界

本地回归覆盖的是**本地模型**。以下**未被覆盖**:

- 费率参数(`MIN_FEE`、`MAX_FEE`、`C`)的经济合理性,没有用真实市场数据校准
- 刷量操纵费率的盈亏边界。结构性上费率地板趋近 `C / 3`,但没有量化模型,也没有模糊测试
- `MAX_FEE` 触发阈值(C=300、MAX_FEE=3000 时加权 local/L <= 10%)对诚实交易者的影响
- 非标准代币行为(转账税、rebase、回调)
- 真实管理员配置、真实资金交易及报价服务；Robinhood 正式路由器、PositionManager、Permit2、
  PoolManager、CREATE2 工厂及 USDG 有 fork 覆盖，但本地 EVM 不完整模拟 ArbOS
- 外部安全审计

早期版本曾有不变量测试套件和 512,000 次 handler 调用,那些针对的是已移除的金库份额与偿付性,
记录保留在[历史归档](history/)。当前应重点验证共享币种的 claim 总额与分池收入始终一致，现有端到端测试覆盖了这些记账关系。
