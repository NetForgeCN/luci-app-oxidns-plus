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

## 本版已实现（全部 L0 + L1，且全在本仓库）

| # | 功能 | 来源 | 层级 | 落点 |
|---|---|---|---|---|
| P1 | `lazy_cache_ttl` 86400 → 3600 | 整合评估 | L0 | `apply_config_tuning` RPC：备份 → 字段替换 → `oxidns check` → 失败回滚 |
| P2 | ECS 全剥离 | 已确认 | L0 | 推荐配置 `edns_strip(strip_unknown + denylist:[8])`；`status` 检测 `ecs_handler` / `client_ip_from_ecs` 并告警 |
| P3 | 无 guest 分支 | 已确认不要 | L0 | 推荐配置不含 `client_ip` 分流与按请求方切缓存；`status` 检测残留 |
| **S1** | 缓存预热（预热列表） | PhotoDNS | L1 | `warm.list` + `oxidnsplus-warm.sh` + init.d 冷启动 + 系统 crond |
| **S2** | DHCP 租约学主机名 | PhotoDNS | L1 | `oxidnsplus-dhcp-hosts.sh` 读 `/tmp/dhcp.leases` → 标准 hosts → `hosts_system` |
| **S4** | 上游延迟实测 | 整合评估 | L1 | `oxidnsplus-diagnose.sh`，只出报告，不自动改配置 |
| N5 | 查询测试 + 配置体检 | PhotoDNS WebUI | L1 | LuCI 页面 `query_test` / `status` |
| — | 全部参数可视化 | 用户要求 | L1 | UCI `oxidnsplus.main` + rpcd + ACL + 菜单 + JS 页面 + 中文 po |

### 设计上的一处改进

上一版方案打算用 OxiDNS 内部的 `cron` + `script` 插件做预热，那需要改
`/etc/oxidns/config.yaml`（基础包的 conffile），附加包改它会冲突、升级会被覆盖。
本版改用 **OpenWrt 系统 crond**：
`/etc/init.d/oxidnsplus` 在 `/etc/crontabs/root` 里维护一个带
`# oxidns-plus:begin/end` 标记的块，幂等替换；启动时再后台跑一次预热，
解决 cron「首个间隔才触发」的空窗。结果是**预热与 DHCP 同步完全不需要改主配置**。

### 另一处简化

基础包 init.d 自带 `reload_service() { procd_send_signal oxidns; }`。
因此配置重载直接走 `/etc/init.d/oxidns reload`，不需要 HTTP API、
不需要 basic auth 凭据、不需要 `curl` 依赖。这也让 UCI 少了一组敏感字段。

## 明确不做

### 需要改官方二进制（第二阶段，见 ROADMAP.md）

当前 `NetForgeCN/luci-app-oxidns/oxidns-core` 打包的是**官方 1.7.1 预编译
musl 二进制**（`Build/Compile` 为空），不是 Rust 源码。以下功能写进
`config.yaml` 会直接被配置校验拒绝：

| 功能 | 层级 | 缺失字段/能力 |
|---|---|---|
| 先等上游再回 stale | L2a | `cache.serve_stale_client_timeout_ms` |
| 过期前提前刷新 | L2a | `cache.background_refresh_threshold_percent` + `refresh_min_ttl` |
| 热点门槛 | L2a | `cache.prefetch_min_hits` |
| TTL 倍增 | L2a | `ttl.multiply` |
| 应答上游 tag / `upstream_equals` | L2a | `forward` 暴露胜出上游 tag |
| 原生 `prefetch` 插件 | L2b | 新 Executor |
| 主动探测 + EWMA 熔断 | L2b | 新插件维护健康状态写 marks |
| 并发未命中去重 | L2b→L3 | cache inflight map |

按「收益低但工作量大的先不考虑」砍掉：要落地这些必须把上游 Rust 源码
vendor 进自家仓库、搭交叉编译、长期 rebase，是工作量最大的一类。
推荐配置里 F1 字段已以注释形式留好，自定义二进制一上即可启用。

### L3 内核改动（明确不碰）

零重编码字节转发、`SO_REUSEPORT`、`recvmmsg`、forward 内部请求级 EWMA 排序
与自适应对冲。改动会破坏 `DnsContext` 可组合性，官方基准也不覆盖这些路径。

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
| `SO_MARK` 分组绕代理 | 透明代理已接管；原配置 `outbound.profiles.proxy` 写了但未引用 |
| 动态 permits 流控 / 自适应流控 | 家用 QPS 个位数，无收益 |
| 缓存诊断报表 / Kix JSON→YAML 生成器 | `/entries` 不返回剩余 TTL；guest 剔除后价值下降 |
| DoQ 0-RTT 降级 | 上游全是 DoH/DoT/UDP，无 `doq://`，零收益 |
| 缓存条目数查询 | 需要 API 凭据，收益低；改为查询测试 + 配置体检 |

## 已知代价

- **预热放大上游 QPS**：27 域名 × A/AAAA = 54 次 / 2 分钟，平均 <0.5 QPS。
  清单越长、间隔越短代价越大。
- **S2 的 reload 会丢缓存**：`cache.dump` 周期 600 s，最近条目会丢。
  故 `dhcp_auto_reload` 默认 0，同步间隔默认 10 分钟，且只在生成文件
  实际变化时才触发。
- **PTR 未打包票**：正向解析确定可用；PTR 依赖
  `reverse_lookup_main(handle_ptr: true)`，建议实测验证。
- **配置调优只改一处**：`lazy_cache_ttl`。ECS / guest / `hosts_system.files`
  只检测提示，不自动改写，避免擅自改动基础包配置。
