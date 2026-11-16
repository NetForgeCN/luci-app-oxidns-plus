# 功能清单与取舍

来源：PhotoDNS / KixDNS / mosdns / OxiDNS 四款引擎的能力对比，见工作区
`dns-engine-integration-analysis.html`。层级沿用：

| 层级 | 含义 |
|---|---|
| **L0** | 纯配置（`config.yaml` 或 UCI），0 代码 |
| **L1** | 外部脚本 / 系统 crond 编排，不改 OxiDNS 二进制 |
| **L2a** | 给已编译插件加字段（不需要新 Cargo feature，轻量 PR） |
| **L2b** | 新增 Executor 插件（需 feature gate + 同步 8 处，重型） |
| **L3** | 改 server 收包层 / forward 状态机 / cache 内部（不建议） |

## 本版已实现（全部 L1，且全在本仓库）

| # | 功能 | 来源 | 落点 |
|---|---|---|---|
| **S1** | **TTL 感知缓存维持**（预热清单 + 按剩余寿命刷新） | PhotoDNS 预热列表 + KixDNS 过期前刷新 | `warm.list` + `oxidnsplus-warm.sh` + init.d 冷启动 + 系统 crond |
| **S2** | DHCP 租约学主机名 | PhotoDNS | `oxidnsplus-dhcp-hosts.sh` 读 `/tmp/dhcp.leases` → 标准 hosts |
| **S4** | 上游延迟实测 | 整合评估 | `oxidnsplus-diagnose.sh`，**只出报告不改任何配置** |
| N5 | 查询测试 | PhotoDNS WebUI | LuCI `query_test` |
| — | 全部参数可视化 | 用户要求 | UCI `oxidnsplus.main` + rpcd + ACL + 菜单 + JS 页面 + 中文 po |
| — | **自动化回退** | 用户要求 | `prerm` / `postrm` / init.d `cleanup` / rpcd `restore_defaults` |

### 0.2.0 的三处设计改动

**① 彻底不碰主配置。** 0.1.0 曾有 `apply_config_tuning`（改 `lazy_cache_ttl`）、
`recommended_config`（617 行模板）、`status` 里的配置体检。用户反馈：改个数字
直接在自己的 `config.yaml` 里改就行，改完即生效，包里不该再做一个功能。
于是三项全删，连带删掉 `config_path` / `working_dir` 两个 UCI 选项、模板文件，
以及 `diagnose.sh` 里读主配置的代码。现在 `scripts/check.sh` 会扫描所有可执行
文件，发现这些方法名或配置标识符就直接报错，防止回潮。

**② 预热从「固定全量」改成「按 TTL 维持」。** 旧方案每 2 分钟把 27 个域名
× 2 类型全查一遍：长 TTL 域名白查，短 TTL 域名在两轮之间就过期了。新方案
从 `dig` 应答读取每条记录的 TTL，只在快到期前刷新，crond 退化成分钟级调度器。
这同时把 KixDNS 式「过期前刷新」用 L1 手段近似实现——不需要改 cache 插件，
因为刷新信号来自应答本身，而不是 cache 内部状态。

限制要说清楚：这是**清单驱动的主动刷新**，不是 cache 内部的「按剩余 TTL 百分比
命中触发」。它没有热度门槛（`prefetch_min_hits`），也不覆盖清单外的域名；
清单内的条目即使没人访问也会一直保持热。换来的是零改动、可回退、无凭据依赖。

**③ 回退自动化。** 因为主配置从未被改，回退的重点变成「清掉包自己留下的
运行时痕迹」：cron 块、`/tmp` 状态、`sysupgrade.conf` 三行、DHCP hosts 内容。
`prerm` 在文件被删之前执行 stop/disable/cleanup；`postrm` 兜底；LuCI 另有
「还原默认」把 UCI 与清单从只读副本恢复。

### 两处沿用 0.1.0 的简化

- 预热与 DHCP 走 **OpenWrt 系统 crond** 而非 OxiDNS 内部 `cron`/`script`
  插件，因此不需要改主配置（它是基础包的 conffile，附加包改它会冲突）。
- 基础包 init.d 自带 `reload_service() { procd_send_signal oxidns; }`，
  配置重载直接走 `/etc/init.d/oxidns reload`，不需要 HTTP API、basic auth
  或 `curl`。

## 明确不做

### 配置建议类（0.2.0 起，硬边界）

配置模板、配置调优按钮、配置体检、主配置备份/校验/回滚、任何形式的
「推荐值」输出。**主配置归用户**，本包不读写 `/etc/oxidns/config.yaml`。

### 需要改官方二进制（第二阶段，见 ROADMAP.md）

当前 `NetForgeCN/luci-app-oxidns/oxidns-core` 打包的是**官方 1.7.1 预编译
musl 二进制**（`Build/Compile` 为空），不是 Rust 源码。以下功能写进
`config.yaml` 会被配置校验直接拒绝：

| 功能 | 层级 | 缺失字段/能力 |
|---|---|---|
| 先等上游再回 stale | L2a | `cache.serve_stale_client_timeout_ms` |
| cache 内部过期前刷新 | L2a | `cache.background_refresh_threshold_percent` + `refresh_min_ttl` |
| 热度门槛 | L2a | `cache.prefetch_min_hits` |
| TTL 倍增 | L2a | `ttl.multiply` |
| 应答上游 tag / `upstream_equals` | L2a | `forward` 暴露胜出上游 tag |
| 原生 `prefetch` 插件 | L2b | 新 Executor |
| 主动探测 + EWMA 熔断 | L2b | 新插件维护健康状态写 marks |
| 并发未命中去重 | L2b→L3 | cache inflight map |

按「收益低但工作量大的先不考虑」砍掉：落地这些必须把上游 Rust 源码 vendor
进自家仓库、搭交叉编译、长期 rebase。字段清单保留在 ROADMAP.md，等自定义
二进制就绪后由用户自行写进主配置。

### L3 内核改动（明确不碰）

零重编码字节转发、`SO_REUSEPORT`、`recvmmsg`、forward 内部请求级 EWMA 排序
与自适应对冲。改动会破坏 `DnsContext` 可组合性。

### 用户明确不要

- guest 全系列（`pipeline_select` / 媒体游戏拦截 / 独立 guest 缓存）
- ECS 注入（要求全剥离，故不引入 `ecs_handler` / `client_ip_from_ecs`）

### 边角料与负向项（评估后砍掉）

| 项 | 砍掉理由 |
|---|---|
| CHAOS TXT 彩蛋、DoH Canary 拦截、小米域名补一条 | 纯边角规则，日常无感 |
| `tcp/udp` 双发 | 上游 QPS 实打实翻倍 |
| 按请求方切缓存 | 缓存碎片化，命中率下降 |
| `fallback` 失败回落 | 违背既定「国外组失败即 SERVFAIL」 |
| `SO_MARK` 分组绕代理 | 透明代理已接管 |
| 动态 permits 流控 / 自适应流控 | 家用 QPS 个位数，无收益 |
| Kix JSON→YAML 生成器 | guest 剔除后价值下降 |
| DoQ 0-RTT 降级 | 上游全是 DoH/DoT/UDP，无 `doq://` |

## 已知代价

- **预热仍会向上游发查询**：TTL 感知只是把「固定全量」变成「按寿命」，
  不是零成本。清单越长、TTL 越短，QPS 越高；`warm_min_ttl` 是防狂刷下限。
- **清单外域名不预热**：只保证 `warm.list` 里的 27 个域名。
- **S2 的 reload 会丢缓存**：`cache.dump` 周期 600 s，最近条目会丢。
  故 `dhcp_auto_reload` 默认 0，同步间隔默认 10 分钟，且只在文件实际变化时触发。
- **PTR 未打包票**：正向解析确定可用；PTR 依赖
  `reverse_lookup_main(handle_ptr: true)`，建议实测验证。
- **卸载后保留空 `dhcp-hosts` stub**：主配置可能引用它，删文件会破坏下次启动。
  想彻底清除需先在用户自己的主配置里删掉那一行。
