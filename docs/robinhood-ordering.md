# Robinhood 交易排序与小费核查

核查日期：2026-09-14。只读查询，无交易广播。

## 区块 62667794 的完整普通交易顺序

区块哈希：`0x5cfb329cffb2e5cf92e11e9c6dc5e251fdc3df1678202f87de8656f7a826ce8d`。
[区块浏览器](https://robinhoodchain.blockscout.com/block/62667794?tab=txs)

顺序以 RPC 返回的 `transactionIndex` 为准。index 0 为系统交易，下面包含其余全部 12 笔。
“RPC 出价”是 `eth_getTransactionByHash` / 区块交易对象中的 `gasPrice`，不是回执中的实际单价。
legacy 交易没有 `maxPriorityFeePerGas`；表中的空项不代表填写了零。

| index | 交易哈希前缀 | RPC 出价，gwei | 小费上限，gwei | gasUsed | 状态 |
| --- | --- | ---: | ---: | ---: | --- |
| 1 | `0xdcf8b76e` | 0.075216326 | 0.002688326 | 183147 | 成功 |
| 2 | `0xa5d325a0` | 0.122528 | 0.05 | 260933 | 成功 |
| 3 | `0xe3c18e2c` | 5 | — | 31585 | 回滚 |
| 4 | `0x364f25a4` | 0.1 | 0.1 | 47818 | 成功 |
| 5 | `0x23795743` | 0.273134 | 0.273134 | 454654 | 成功 |
| 6 | `0xe4aa03a5` | 5 | — | 31573 | 回滚 |
| 7 | `0x421a963d` | 15 | — | 31585 | 回滚 |
| 8 | `0x078004b3` | 0.072528 | 0 | 37035 | 成功 |
| 9 | `0x24aa7171` | 0.082528 | 0.01 | 731958 | 成功 |
| 10 | `0x4e70839e` | 0.122528 | 0.05 | 57916 | 成功 |
| 11 | `0x2ef7fc85` | 0.372528 | 0.3 | 327473 | 成功 |
| 12 | `0x59deeaff` | 5 | — | 31585 | 回滚 |

全部 12 笔的回执 `effectiveGasPrice` 都是 **0.072528 gwei**，等于该区块的 `baseFeePerGas`。
所以总 gas 费用的差异来自 `gasUsed`，不能将总费用更高解读为支付了更高的 gas 单价。

该区块不是按 RPC 出价从高到低排序：index 1 的出价低于后面的多数交易；index 8 的零小费交易
先于 index 9、10、11；最高出价 15 gwei 出现在 index 7。排除出价相同的组合，62 对交易中，
24 对是较高出价先出现，38 对是较低出价先出现。这只是这个区块的描述统计，不是独立随机样本，
不用于显著性检验。index 3 和 12 来自同一账户的连续 nonce，也不是独立排序竞争。

链上区块没有每笔交易到达排序器的时间，也没有调用者发送交易时的网络延迟。因此这些数据
不能排除提交路径、队列分组等影响，也不能仅靠一个区块证明费用对排序在所有情况下都没有作用。
但这个例子不支持“全区块按 gas 出价降序执行”的解释。

## 当前小费开关，以及可能的变化

在 L2 区块 `62697766`，公开预编译查询得到：

```text
ArbSys(0x64).arbOSVersion()          = 116
ArbOwnerPublic(0x6b).getCollectTips() = false
```

Nitro 的 `arbOSVersion()` 对内部 ArbOS 版本加 55，所以这里对应内部版本 61。
[ArbSys 源码](https://github.com/OffchainLabs/nitro/blob/a618155919315241665356fe60f3cd00d66d5e46/precompiles/ArbSys.go#L66)

公开上游源码的 `CollectTips()` / `GetPaidGasPrice()` / `GasPriceOp()` 给出以下逻辑：

- 延迟收件箱消息不收小费；特定历史版本另有行为。
- ArbOS 60 及以上版本支持 `CollectTips` 配置。
- 开关关闭时，付费单价和 `GASPRICE` 指令返回 base fee。
- 开关开启时，返回有效 gas price，可能包含小费。

[交易执行源码](https://github.com/OffchainLabs/nitro/blob/a618155919315241665356fe60f3cd00d66d5e46/arbos/tx_processor.go#L895)
及 [公开查询接口](https://github.com/OffchainLabs/nitro/blob/a618155919315241665356fe60f3cd00d66d5e46/precompiles/ArbOwnerPublic.go#L119)。
`setCollectTips` 是链管理接口，Hook 管理员身份不提供链管理权限。
[设置接口](https://github.com/OffchainLabs/nitro/blob/a618155919315241665356fe60f3cd00d66d5e46/precompiles/ArbOwner.go#L663)

源码引用固定于公开上游提交 `a618155919315241665356fe60f3cd00d66d5e46`。
RPC 自报客户端为 `nitro/v3.11.4-rc.3-7d5ac27/linux-amd64/go1.25.14`；未能在公开上游仓库解析
该短提交，因此不把上游源码当作 Robinhood 实际排序器运行代码的完整证明。预编译返回值和
交易回执来自目标链，属于直接观测。

可通过以下只读命令复现配置查询：

```bash
cast call 0x0000000000000000000000000000000000000064 \
  'arbOSVersion()(uint256)' --block 62697766 \
  --rpc-url https://rpc.mainnet.chain.robinhood.com

cast call 0x000000000000000000000000000000000000006b \
  'getCollectTips()(bool)' --block 62697766 \
  --rpc-url https://rpc.mainnet.chain.robinhood.com
```

普通交易的小费是否被收费，与排序器是否参考某个字段，是两个问题。`CollectTips=false`
直接解释当前 Hook 读取不到小费溢价，不单独证明排序器采用哪一种队列策略。

## Timeboost 与普通小费的区别

Timeboost 拍卖的是一段时间内快速通道的控制权，费用在独立拍卖合约中结算；它可以与普通
交易不收小费同时存在，不能通过 `tx.gasprice - block.basefee` 直接度量拍卖支出。
[Timeboost 官方机制](https://docs.arbitrum.io/how-arbitrum-works/timeboost/gentle-introduction)

Robinhood 当前[官方排序说明](https://docs.robinhood.com/chain/differences-from-ethereum/)
写明 FCFS 和没有 priority gas auction。本次未找到其正式启用 Timeboost 的官方部署依据。
该区块的 RPC 回执没有 `timeboosted` 字段：字段缺失不是 `false`，不能用它证明未启用。
在提供该字段的节点上，可按[官方识别方法](https://docs.arbitrum.io/how-arbitrum-works/timeboost/how-to-use-timeboost#how-to-identify-timeboosted-transactions)
查询回执或排序器 feed 元数据。

目前没有找到可由 Hook 同步调用、可靠返回本次交易原始小费报价或本次快速通道支出的公开接口。
知道某轮的快速通道控制者，也不能简单通过比较 `tx.origin` 判定某笔交易是否受益，因为控制者
可以为其他发送者的交易签署快速通道请求。

## 当前 Hook 的收费策略

当前采用保留现有 `tx.gasprice / block.basefee` 公式的策略，接受 Robinhood 当前配置下普通
交易收取 1 bp 协议费，LP 动态费继续独立计算。
若链后续开启收小费，当前公式可按实际比例增加并受 30 bp 上限约束。
预检应展示链上收费模式，而不是从一次 `basefee > 0` 检查推断动态协议费一定可用。

要确定实盘中是否有报价优先，需要同一发送路径、相近提交时间、不同独立账户、随机交替报价的
受控实验，并记录发送时间与结果；nonce 依赖、RPC 路由、总 gas 消耗和实际价格需分别控制。
本次只完成链上只读分析，没有做需要签名和资金的实盘实验。
