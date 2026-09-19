# Robinhood ETH/USDG 上线验证

目标为 Robinhood **主网**，交易对为原生 ETH / USDG。初始链上观测于
2026-09-14 完成，固定 L2 区块 `62684313`，区块哈希
`0x4e6916a3314779539357ab2b5b54020075b58512e5fb0e0eef2c6ade01f3f466`。
当前工程 fork 验证于 2026-09-16 完成，使用区块 `64331435`，详情见下文。Hook 尚未部署到主网，演练没有广播交易。

## 网络与资产

| 配置 | 值 |
| --- | --- |
| Chain ID | `4663` |
| 公共 RPC | `https://rpc.mainnet.chain.robinhood.com` |
| currency0 | 原生 ETH：`0x0000000000000000000000000000000000000000`，18 位 |
| currency1 | USDG：`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`，链上 `decimals()` 返回 6 |
| PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| CREATE2 工厂 | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| PositionManager | `0x58daec3116aae6d93017baaea7749052e8a04fa7` |
| Universal Router | `0x8876789976decbfcbbbe364623c63652db8c0904` |
| V4 Quoter | `0x8dc178efb8111bb0973dd9d722ebeff267c98f94` |
| StateView | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` |

网络参数来自 [Robinhood 网络文档](https://docs.robinhood.com/chain/add-network-to-wallet/)，
USDG 地址来自 [Robinhood 代币合约列表](https://docs.robinhood.com/chain/contracts/)，
Uniswap 地址来自 [官方 v4 部署列表](https://developers.uniswap.org/docs/protocols/v4/deployments)。
PoolManager 的代码及 `protocolFeeController()` 应答、CREATE2 工厂的代码和部署调用均已验证。
生产 Universal Router、PositionManager 和 Permit2 的交互已通过下述 fork 测试。Quoter、StateView 和链下报价服务未纳入本轮验证。

## 上线前需要明确的两处链差异

### 费用缓存使用的是 L1 块号

Robinhood 的 `block.number` 返回估算的 L1 块号，真实 L2 块号需调用
`ArbSys(0x0000000000000000000000000000000000000064).arbBlockNumber()`。
[官方说明](https://docs.robinhood.com/chain/differences-from-ethereum/)

实测连续三个 L2 区块 `62684312`、`62684313`、`62684314` 的 `l1BlockNumber` 均为
`25974649`；对中间区块执行 `NUMBER` 指令也返回 `25974649`，ArbSys 返回 `62684313`。

`FeeModule._feeForSwap` 和 `PulseV4Hook.afterInitialize` 使用 `block.number`，因此缓存可以跨多个
L2 区块复用，与“每个 Robinhood 区块首次交易刷新”的目标不一致。若保留这个目标，应在这两处
使用同一个读取 L2 块号的方法，并验证同一 L2 块内冻结、L2 块变化时刷新、L1 块号不变时也能刷新。
成交量的整小时衰减仍按 `block.timestamp` 正常计算；块号只控制实际交易使用的 LP 费率缓存。
接受 L1 块号更新时才重算费率，也是可选策略，不会仅因未适配 L2 块号就停止衰减或无法交易。
若希望按时间刷新，可以另行采用明确的秒级缓存。它不等价于逐 L2 块刷新：实测不同 L2 区块
可以共享时间戳。

### 小费不能驱动协议费上涨

Robinhood 的文档说明按交易到达顺序排序。目标链实测收小费开关为关闭状态，普通交易支付
base fee。较新 Nitro 支持链管理员开启收小费，不能将当前行为推广为永久限制；
版本、开关、完整区块交易排序及 Timeboost 的区别见[排序与小费核查](robinhood-ordering.md)。

在观测区块，`block.basefee = 74,268,000 wei`。抽查的 8 笔普通交易回执包含 legacy 和 EIP-1559
交易，`effectiveGasPrice` 都为 `74,268,000 wei`，包括填写非零小费的成功交易
[`0xa7f32d…38caa`](https://robinhoodchain.blockscout.com/tx/0xa7f32dd8e085852db3208e67159cf97bd36863c53c6ac2eb7927f3aa21f38caa)。

另以 `148,536,000 wei`（2 倍 base fee）发起只读 `eth_call`，执行 `NUMBER`、`GASPRICE`、
`BASEFEE` 三个 EVM 指令，返回值依次为 `25974649`、`74268000`、`74268000`。
可用以下 JSON-RPC 请求复现，无需部署探针或签名：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eth_call",
  "params": [
    {"data": "0x436000523a6020524860405260606000f3", "gasPrice": "0x8da7ac0"},
    "0x3bc7c99"
  ]
}
```

因此当前公式在这类交易中为：

```text
协议费率 = min(3000, floor(100 × gasPrice / baseFee))
         = 100 pips = 1 bp
协议费金额 = floor(未指定侧原始金额 × 100 / 1,000,000)
```

这条路径能收协议费；在当前关闭收小费的配置下，按小费加价至 30 bp 的功能不会被这里的
普通交易触发。LP 动态费仍由成交量分布决定，配置上限为 30 bp。

当前上线策略：保留现有协议费公式，接受 Robinhood 当前配置下普通交易收取 **1 bp 协议费**，
收益预期按此计算。LP 动态费继续按成交量分布计算。这不是将协议费永久固定为 1 bp；
若链管理员开启小费收取，现有公式可随实际 gas 比例增加，并受 30 bp 上限约束。

## 当前 fork 验证

2026-09-16 的工程验证固定 L2 区块 **64331435**，哈希
`0xde4864a95f45a279ee5e9f7aaf8f5cf0db4360a3a6f85966725fffb06151c864`。
此区块 base fee 为 **57,234,000 wei**。测试源码和默认工具版本可从当前提交复现。

- [RobinhoodLifecycle](../test/fork/RobinhoodLifecycle.t.sol)：用测试路由器核对底层结算、钱包 delta、claim 收入和 LP 退出。
- [RobinhoodPeriphery](../test/fork/RobinhoodPeriphery.t.sol)：直接调用链上的正式 Universal Router、PositionManager、Permit2，验证创建 LP NFT、增加流动性、四种方向和金额模式的交换、提取两侧收入、销毁 NFT 并全部撤出。
- 正式路由器的两项滑点测试，先计算暂停收费时的交易结果，再启用协议费并要求相同限额，断言 exact-input / exact-output 均因新增协议费回滚，价格、余额和收入保持原值。

**结果：4 项通过、0 失败。** 测试还逐项核对预检与实际部署入口产生相同的 Hook、salt、PoolId 和价格，
以及 Permit2 结算、原生币退款后，路由器和 PositionManager 没有残留资金。

```sh
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
forge test --threads 1 --match-path 'test/fork/*.t.sol' -vv
```

公共 RPC 会裁剪历史状态，默认使用当前状态，并在测试输出中记录所选区块。
复现指定区块时设置 `ROBINHOOD_FORK_BLOCK=64331435`；若出现 historical state unavailable，
需使用保留该区块状态的 archive RPC。不要把 RPC 缺失历史状态当作合约测试通过或合约错误。
未设置 `ROBINHOOD_RPC_URL` 时，两个 fork 套件在 setUp 显式跳过；CI 的手动运行入口可启用公共 RPC 演练。
`--threads 1` 防止脚本的进程级环境变量互相干扰；本地环境变量边界测试也集中在单一用例中执行。

预检和部署共用 [DeploymentConfig](../script/DeploymentConfig.sol)：原始数字先验证再窄化，
所有价格路径检查 TickMath 边界；按实际挖出的 Hook 地址检查目标 PoolId，并检查地址是否已被部署。
填 `PRICE_E18`、留空 `INITIAL_SQRT_PRICE`，两个脚本即可使用同一推导价。
自动推导支持 0–18 位小数的币种，更高小数位可以直接填写排序后的池价。
预检不证明输入价与市场公允价一致。

测试使用公开测试私钥 `1` 和 cheatcode 资金，管理员为本地测试合约，初始价固定为
**3000 USDG/ETH**；它们都不是上线配置。示例 `sqrtPriceX96` 为 `4339505179874779489431521`。
测试路由 ABI 根据浏览器验证的实际部署源码核对，其中单跳交换参数含 `minHopPriceX36`。

Foundry fork 使用本地 EVM，不完整模拟 ArbOS。测试显式将 `tx.gasprice` 设置为所在区块的
base fee，并用 `vm.roll` 推进合约可见块号；它不验证真实排序、L2 逐块刷新或实际小费收取。
真实链语义由前述 RPC 观测与官方文档单独验证。

## 上线前仍需完成

- 确认接受当前按合约可见 L1 块号刷新缓存的策略；如需逐 L2 块刷新，另行实现并验证。
- 确定真实管理员、部署账户、实时初始价、tick spacing、费率参数、资金规模与首批 LP 区间。
- 最终配置重新演练，随后小额实盘、源码验证、地址与交易记录、运行监测。
- 跨缓存区间操纵的经济验证、LP 收益评估、独立安全审查。
- Uniswap 路由接入：当前 Hook 包含动态费与 `afterSwapReturnsDelta`，需遵循
  [Hook 路由审核要求](https://support.uniswap.org/hc/en-us/articles/48291859140621-Routing-for-hooked-pools)。
