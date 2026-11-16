# 第二阶段：带补丁的自家二进制

> 本版（0.2.0）**没有**改 OxiDNS 二进制。这份文档说明如果将来要把
> 「先等上游再回 stale」「过期前提前刷新」「原生 prefetch」「主动探测熔断」
> 等能力做进来，落点在哪、代价是什么、怎么保证不干扰上游仓库。

## 为什么这一版没做

`NetForgeCN/luci-app-oxidns/oxidns-core/Makefile` 打包的是**官方 1.7.1
预编译 musl 二进制**：`PKG_SOURCE_URL` 指向 `svenshi/oxidns` 的 release
tarball，`Build/Compile` 为空，`PKG_HASH` 锁死。配置文件里写官方二进制
不认识的字段（如 `serve_stale_client_timeout_ms`）会直接被
`oxidns check` 拒绝。

而且 OxiDNS **没有运行时插件 ABI**：插件靠 `#[plugin_factory("type")]`
在**编译期**注册，由 Cargo feature 裁剪。官方自定义构建的三条路里，
模板仓库 + Actions、本地 `cargo build` 只能挑选已存在的 feature，
不能注入自己的插件代码。官方路线图把 WASM / 原生动态库放在 Later，
并明确「在开放第三方 ABI 前，优先稳定配置模型、生命周期、能力声明」。

所以要做 F/N 类，只有两条路，**两条都不需要向上游 push**：

| 路线 | 做法 | 代价 |
|---|---|---|
| **A · 源码编译 + patches/** | 把 `svenshi/oxidns` 源码（或 release 源码 tarball）vendor 进 `luci-app-oxidns-plus/core-src/`，加 `patches/` 目录，`Makefile` 改成 Rust 交叉编译并在 `Build/Prepare` 应用补丁 | 需要 Rust 工具链与目标 triple；上游每次发版要 rebase 补丁 |
| **B · 外部编译 + 上传** | 自行在 CI 里编译带补丁的二进制，做成 release asset；用基础包 LuCI 的「上传 archive/binary」替换设备上的核心 | 不需要改本仓库的构建链；但要维护一套独立的编译 CI 与版本对齐 |

推荐 **B** 起步：不增加本仓库的构建复杂度，且随时可以退回官方二进制。
等补丁稳定、需要长期随固件出包时再转 A。

## L2 内部成本差一个量级

官方 `docs/ai/plugin-dev.md` 明确：

- **L2a「给已编译插件加字段」不需要新增 Cargo feature**。改动局限在
  现有插件的参数结构与处理逻辑，可独立提 PR、不必长期维护 fork。
- **L2b「新增插件」只要有后台任务 / 文件 I/O / 外部调用就必须加 feature gate**，
  并同步 8 处：`Cargo.toml`、`build_info.rs`、`feature_gating.rs`、
  `plugin_integration.rs`、website 中英文、WebUI 插件定义、canonical config。

所以优先级是 **F 系列（L2a）在前，N 系列（L2b）在后**。

## 建议实施顺序

### 批次 1 · L2a，四个小字段

| 字段 | 插件 | 语义 | 与现有配置的关系 |
|---|---|---|---|
| `serve_stale_client_timeout_ms: 1500` | `cache` | 命中 stale 后先等上游 1.5 s，真失败才回旧值 | 必须 < 上游 timeout(3 s/5 s) 且 < request_timeout(8 s)。缓存 stale 窗口由用户自行在主配置里调整 |
| `background_refresh_threshold_percent: 10` | `cache` | TTL 剩 10% 时命中触发异步刷新 | 削掉 TTL 到期瞬间的回源尖峰 |
| `refresh_min_ttl: 5` | `cache` | 短 TTL 不参与提前刷新 | 防止短 TTL 域名被狂刷 |
| `prefetch_min_hits` | `cache` | 只有够热的条目参与提前刷新 | 抑制 QPS 放大 |

机制提醒：`cache` 是**读+写一体、命中即把 response 写进 `DnsContext`**，
`fallback` 能造等待窗口但主路径一碰 cache 就立刻拿到 stale 并被判成功，
所以「先等上游再回 stale」纯配置**拼不出**，必须加字段。

### 批次 2 · L2a，日志与可观测

| 字段 | 插件 | 语义 |
|---|---|---|
| 暴露胜出上游 tag | `forward` | 写入 `DnsContext` 供 matcher / `query_summary` 消费，补齐 KixDNS 的 `upstream_equals` |
| `multiply` | `ttl` | 钳制前放大 TTL；本拓扑已有 `max: 3600`，只对短 TTL 有效，收益有限 |

### 批次 3 · L2b，新插件

| 插件 | 能力 | 边界 |
|---|---|---|
| `prefetch` | 读 `domain_set`，做预热 + 按 TTL 刷新 + min_hits，带并发限速 | 能把本版 S1 与批次 1 收成一个原生插件，不再需要系统 crond。注意 0.2.0 的 S1 已在外面按 TTL 维持缓存，这个插件的增量只剩「清单外域名」与「热度门槛」 |
| 主动探测 + 熔断 | 后台定期直连各上游发探测查询，维护 EWMA / 连续失败 / 熔断状态写 marks，外层 `sequence` 用 `mark` 选 forward 子链 | **只能做「探测 + 踢坏上游」**；请求级 EWMA 排序 / 自适应对冲仍要改 `forward` 状态机（L3）。`load_balance` 官方明确无健康检查 |

注意：本版预热（0.2.0 起已按 TTL 感知）与诊断是 L1 脚本，已经能工作。
L2b 的价值是**收编**它们，不是补缺口——按收益排序它应该排在最后。
即便第二阶段落地，字段也由用户自行写进主配置，本包不代劳。

## 与国外组 SERVFAIL 原则的冲突

现有 v5 配置明确「国外组失败即 SERVFAIL、不静默降级」，且专门不用
`fallback`。若第二阶段给国外组加「降级子链」，会突破这条原则；
若坚守原则，主动探测熔断对国外组就只剩「少等一个超时」，收益大幅缩水。
**实施前必须先裁决这一点**，不要默认加降级。

## 明确的红线

- **本包任何代码都不读写 `/etc/oxidns/config.yaml`**。第二阶段的新字段由用户
  自行写进主配置；不复活配置模板、配置调优或配置体检。
- **不向 `svenshi/oxidns` 提交 PR 之外的任何写入**，也不修改
  `NetForgeCN/luci-app-oxidns` 的现有文件。补丁只存在于本仓库。
- **不搬 PhotoDNS 源码**：PhotoDNS 是 **GPL-3.0-only**，而本仓库与基础包
  都是 `GPL-3.0-or-later`。直接并入会让整体只能按 `only` 分发。
  一律「借设计 + 独立实现」。
- **不碰 L3**：零重编码字节转发、`SO_REUSEPORT`、`recvmmsg`、
  forward 内部请求级 EWMA、cache 内部结构复用。会破坏 `DnsContext`
  可组合性，且官方基准不覆盖这些路径。

## 什么时候改名 `pro`

当前命名 `luci-app-oxidns-plus` 是诚实的：核心仍是官方二进制，
只是外面加了一层。等**批次 1 的自定义二进制真正进本仓库并成为默认**，
再考虑改名 `luci-app-oxidns-pro`。改名成本很低，只是目录名、
包名、UCI 名、菜单名、rpcd 对象名、i18n catalog 的一次全局替换，
但会破坏已装设备的 UCI 配置，需要写迁移脚本。
