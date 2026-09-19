# 实现状态与上线事项

当前行为以 [SPEC](SPEC.md) 为准，测试结果和复现命令见[测试说明](docs/testing.md)。

## 工程能力

- [x] 动态 LP 费按成交量分布计算，按合约可见 `block.number` 缓存；成交量按 UTC 整点减半。
- [x] 协议费按 `gasprice/basefee` 计算，普通无小费交易收 1 bp，总上限 30 bp；零 base fee 不收。
- [x] 协议收入在 PoolManager 中以 ERC-6909 claim 累积，支持原生币、共享币种的多池记账和分批提现。
- [x] 暂停只停收协议费，交换、LP 费率计算和成交量更新继续运行。
- [x] Preflight 与 Deploy 共用配置、整数边界检查、价格换算、CREATE2 地址和真实 PoolId 检查。
- [x] 预检与实际部署入口覆盖空可选字段、超宽整数、价格边界、反向报价及重复部署。
- [x] Robinhood 正式 Universal Router、PositionManager 和 Permit2 的 fork 集成测试。
- [x] 双向 exact-input / exact-output、含协议费滑点限额、收入提取、LP 增加及全部撤出测试。
- [x] 中英文 README、部署指南、CI 本地检查和可手动运行的 Robinhood fork 检查。

## 小额实盘前

- [ ] 确认真实管理员、部署账户、投入金额、LP 区间、实时初始价及不可变费率参数。
- [ ] 确认接受 Robinhood 合约可见 L1 块号的缓存周期；若要逐 L2 块刷新，另行改实现和测试。
- [ ] 使用最终配置重新预检与演练，随后部署、验证源码并保存地址和交易记录。
- [ ] 用小额真实资金完成加仓、交易、协议费提取与撤仓闭环，建立收入和交易异常监测。

## 公开吸引 LP 资金前

- [ ] 用 ETH/USDG 市场数据校准 `C`、`MIN_FEE`、`MAX_FEE` 和 tick spacing。
- [ ] 量化跨缓存区间刷量对费率、操纵成本和 LP 净收益的影响。
- [ ] 评估上限触发频率：C=300、MAX_FEE=3000 时，加权 `local/L <= 10%` 即达到上限。
- [ ] 补充动态费率的性质测试与经济模拟；当前信号不会直接区分普通交易和套利。
- [ ] 对最终源码及配置进行独立安全审查。
- [ ] 按 [Uniswap Hook 路由要求](https://support.uniswap.org/hc/en-us/articles/48291859140621-Routing-for-hooked-pools)申请接入；合约可调用不等于前端自动路由。

目标链事实、fork 范围与未验证项目见 [Robinhood 上线验证](docs/robinhood.md)。
