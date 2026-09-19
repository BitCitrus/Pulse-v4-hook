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

单独部署 Hook 只读取 `POOL_MANAGER_ADDRESS`、`ADMIN_ADDRESS`、`MIN_FEE`、`MAX_FEE`、
`FEE_CONSTANT_C`、`BASE_TOKEN_IS_TOKEN0`，签名另需 `PRIVATE_KEY`。
代币地址、`TICK_SPACING`、`PRICE_E18` 和 `INITIAL_SQRT_PRICE` 均为池子配置，可留到建池时填写。

| 变量 | 说明 |
|---|---|
| `POOL_MANAGER_ADDRESS` | 目标链的 v4 PoolManager |
| `ADMIN_ADDRESS` | Hook owner。可暂停协议费、提取收入，与部署、建池、LP 钱包相互独立 |
| `MIN_FEE` / `MAX_FEE` | LP 费率下限与上限,pips。要求 `MIN_FEE <= MAX_FEE < 1000000` |
| `FEE_CONSTANT_C` | 费率公式系数,`<= 2^128 - 1` |
| `BASE_TOKEN_IS_TOKEN0` | 成交量以哪一侧计量。**指排序后的 token0** |
| `TOKEN0_ADDRESS` / `TOKEN1_ADDRESS` | 脚本会自动按地址大小排序 |
| `TICK_SPACING` | 池子 tick 间距 |
| `PRICE_E18` | 建池初始价格，按填写地址顺序，每个完整 TOKEN0 对应多少完整 TOKEN1，乘以 10^18；不属于 Hook 构造参数 |
| `INITIAL_SQRT_PRICE` | 可留空；填写时为排序后池价的 `sqrtPriceX96`，同时填人类价格则交叉校验 |

### 选 C 的注意事项

正常未饱和、忽略逐桶取整的情况下，把成交量集中到当前 tick，未裁剪费率趋近 `C / 3`。
`MIN_FEE` 在 `L == 0` 或计算结果低于下限时生效，`MAX_FEE` 则约束上限。
`MIN_FEE >= C` 不代表固定费率，因为 `L / local` 可以大于 1；两端费率相等才明确选择固定费率。
预检允许合约支持的参数，并提示等上下限和 `C == 0` 的行为。参数的经济合理性需要单独验证。

只有两种币小数位相同时，人类 `1:1` 价格才对应 `INITIAL_SQRT_PRICE=2^96`。
注意排序会改变哪个代币是 token0,`BASE_TOKEN_IS_TOKEN0` 必须按**排序后**的结果填写。

## 3. 预检(不广播,不花 gas)

只部署 Hook 时使用以下入口，无须池子配置或价格，也无须私钥：

```sh
forge script script/Preflight.s.sol --sig "hookOnly()" --rpc-url $RPC_URL
```

它检查链和基础合约、管理员、费率参数，并预测 CREATE2 地址、检查地址是否被占用。
需要同时规划建池时，再填写币对、tickSpacing 和价格，运行完整预检：

```sh
forge script script/Preflight.s.sol --rpc-url $RPC_URL
```

完整预检额外检查池子配置与初始价格：

| 检查 | 不检查会怎样 |
|---|---|
| 当前 `block.basefee > 0` | 当前为 0 时协议费不会收取；此检查不能证明未来 base fee 或小费开关状态 |
| PoolManager 代码与 v4 视图接口 | 拦住常见地址填错；仍需与官方部署地址核对身份 |
| CREATE2 工厂存在 | 部署阶段才失败,地址挖矿白做 |
| 读链上 `decimals()` 推导初始价格 | 小数位搞错 → 价格差 10^(d0−d1) 倍,池子开出来即被套利搬平 |
| 排序翻转时自动倒置报价 | 地址排序决定谁是 currency0,搞反等于按倒数开池 |
| 原始整数、费率和 TickMath 价格边界 | 所有数字先验证再窄化，手填和推导价格使用相同边界 |
| 实际 Hook 地址和目标 PoolId | 检查 CREATE2 地址占用及带该 Hook 的池子是否已经初始化 |

完整预检、合并部署建池和独立建池共用 [DeploymentConfig](../script/DeploymentConfig.sol)，填写
`PRICE_E18` 即可推导同一初始价格，无须手动复制。地址排序翻转时使用精确的倒数比例，不先把倒数截成 18 位小数。
推导支持 0–18 位小数的币种；更高位数需留空 `PRICE_E18`，提供排序后的 `INITIAL_SQRT_PRICE`。
它打印链 ID、管理员、PoolManager、Hook 地址、salt、PoolId、价格及费率上下限。
反算价格按排序后的 currency1/currency0 输出，可能因取整比原报价少一个最小单位。
这些检查不验证市场公允价；创建池子前仍需核对实时价格，部署 Hook 前核对管理员和费率参数。

## 4. 部署与创建池子

部署 Hook、创建池子、添加流动性可以由不同钱包完成。部署时只需指定 Hook 管理员，
不需要预先登记建池钱包或 LP 钱包。`PRIVATE_KEY` 只决定当前脚本由谁签名并支付 gas；
`ADMIN_ADDRESS` 决定 Hook 管理员；LP 仓位的归属由添加流动性时的 NFT 接收地址决定。

### 不同钱包分别执行

部署钱包在本地配置自己的 `PRIVATE_KEY` 和 Hook 参数，只部署 Hook；币对、tickSpacing 和价格可留空：

```sh
forge script script/Deploy.s.sol --sig "deployHook()" --rpc-url $RPC_URL --broadcast --verify
```

建池钱包使用相同代码版本、编译设置和构造参数，在本地切换为自己的 `PRIVATE_KEY`，
填写币对、tickSpacing，并按实时市场价格填写 `PRICE_E18`（`INITIAL_SQRT_PRICE` 留空或填写匹配值），再创建池子：

```sh
forge script script/InitializePool.s.sol --rpc-url $RPC_URL --broadcast
```

初始化脚本重算同一个 CREATE2 地址，检查该 Hook 已部署、目标池尚未初始化，再设置初始价格。
改变价格不会改变 Hook 地址；改变管理员、费率构造参数或 Hook 编译产物会改变地址。
两步均可先省略 `--broadcast` 做模拟。私钥只在本地使用，不需要发给任何人。

池子初始化是公开操作，创建者没有池子的独占管理权限。分步执行时，如果目标池已被他人初始化，
脚本会停止；添加流动性前应读取池子的实际价格，重新核对区间和金额。

### 同一个钱包完成部署和建池

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

## 5. 交易者与 LP 接入

Hook 不托管 LP 资金，仓位通过 v4 periphery 管理。

- 交易者通过兼容动态费与 Hook delta 的 v4 路由器交换，需按实际 ABI 编码结算与退款动作
- LP 照常通过 `PoolManager.modifyLiquidity` 或 position manager 提供流动性
- 实际支付的 LP 费率由 Hook 在 `beforeSwap` 覆盖,可用 `computeFee(key)` 预估

### ETH/USDG 首仓试算

原生 ETH（18 位）/ USDG（6 位）可用只读脚本计算价格区间、tick、流动性及两种币的实际用量：

```sh
forge script script/PlanLiquidity.s.sol
```

它读取 `PRICE_E18`、`TICK_SPACING`、`LP_WIDTH_BPS`、`LP_AMOUNT0_MAX` 和 `LP_AMOUNT1_MAX`，
不需要 RPC、钱包地址或私钥。`LP_WIDTH_BPS=500` 表示参考价两侧各 5%，边界再向外对齐 tick；
`LP_AMOUNT0_MAX=1000000000000000000` 和 `LP_AMOUNT1_MAX=3000000000` 表示最多 1 ETH、3000 USDG。
预算不含 gas，两种币不一定全部用完。脚本打印未使用余额，并按 PoolManager 铸造时向上取整计算应付金额。

此脚本固定采用 ETH/USDG 的排序和小数位，不适用于反向报价或其他资产。
结果只对应输入价格，没有执行授权或铸造仓位；实际添加前读取池价，设置金额上限与交易截止时间。
Hook 不会自动调整 LP 区间，价格离开区间后需由 LP 自行管理仓位。

Robinhood 的正式 Universal Router、PositionManager 和 Permit2 流程见
[fork 验证](robinhood.md)。合约调用兼容性不代表前端自动发现池子；Uniswap 的动态费和
`afterSwapReturnsDelta` 池需按[路由审核要求](https://support.uniswap.org/hc/en-us/articles/48291859140621-Routing-for-hooked-pools)申请接入。

**不需要 keeper。** 合约可见 `block.number` 变化后的第一笔交易重算费用。
Robinhood 上该值为估算的 L1 块号，所以多个 L2 区块可复用缓存；整点成交量衰减使用 `block.timestamp`。

## 6. 索引器与前端

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

展示成交量时若要显示衰减后的值,需要在链下用 `0.5^h` 自行计算并向下取整,`h` 为当前时间与锚点相隔的**整小时数**,
`h >= 90` 时归零。直接展示 getter 返回值会高估近期活跃度。

## 7. 运营

| 操作 | 命令 |
|---|---|
| 暂停协议费 | owner 调用 `setPaused(true)`。交易不受影响 |
| 提取收入 | owner 调用 `withdrawProtocolRevenue(key, recipient)`,按池执行 |

协议费以 ERC-6909 claim 保存在 PoolManager。提现需在 PoolManager 未解锁时发起,
由 Hook 在回调中兑换并直接付给 recipient;原生币收款人需要能够接收 ETH。任一币种转账失败则整笔回滚。
收入查询和事件接口保持不变,但集成方应读取 claim 余额,不再以 Hook 的 ERC20/ETH 余额表示可提收入。

owner 无法修改费率参数、无法阻断交易、无法触碰 LP 的资金——Hook 里没有 LP 的资金。
