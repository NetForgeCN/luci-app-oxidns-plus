# luci-app-oxidns-plus

> OxiDNS 增强附加包：按 TTL 维持缓存、DHCP 主机名、上游诊断、可视化配置。
> 只加一层，不换核心，**不改主配置**。

[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

## 0.2.0 的三条修复

| # | 修复 | 结果 |
|---|---|---|
| 1 | **移除全部配置建议类功能** | 删掉 `config.recommended.yaml` 模板、「配置调优」「推荐配置」按钮、「配置体检」、以及 `config_path` / `working_dir` 两个 UCI 选项。像 `lazy_cache_ttl` 这类数字，直接在自己的 `config.yaml` 里改、改完就生效，不需要包里再做一个功能。**本包任何代码都不读写 `/etc/oxidns/config.yaml`。** |
| 2 | **预热改成 TTL 感知的按需维持** | 不再是「每 2 分钟把 27 个域名全查一遍」。现在记住每条 `(域名, 记录类型)` 应答的 TTL，只在该条缓存快到期前刷新；crond 只做分钟级调度，实际查询数按 TTL 分布下降，同时消除固定间隔下短 TTL 域名「没到下一轮就过期」的空窗。 |
| 3 | **回退自动化** | 新增 `prerm`（卸载前自动 stop/disable/清状态/清 `sysupgrade.conf` 三行）、`postrm` 兜底、init.d `cleanup`、LuCI「还原默认」按钮。因为主配置从未被改过，卸载后 OxiDNS 本身就是原样。 |

## 定位与边界

这是**附加包（add-on）**，不是 `luci-app-oxidns` 的替代品，需要原运行时已装好：

- 先装 OxiDNS 核心（通过 [NetForgeCN/luci-app-oxidns](https://github.com/NetForgeCN/luci-app-oxidns)
  的 LuCI 安装/上传，或手工部署），再装本包。
- 本仓库**不含** OxiDNS Rust 源码，**不含**核心二进制，**不推送**到
  `svenshi/oxidns`，也**不修改** `luci-app-oxidns` 的任何文件。
- **主配置归你**：`/etc/oxidns/config.yaml` 的所有参数（缓存 TTL、上游、
  ECS、hosts 引用等）都由你直接在文件里维护。本包不生成模板、不校验、不改写、
  不备份它。`scripts/check.sh` 会扫描所有可执行文件，防止这类代码回潮。

所有命名空间都与原包隔离，两个包可以同时装、互不影响：

| | 基础包 | 本包 |
|---|---|---|
| UCI | `oxidns.main` | `oxidnsplus.main` |
| init.d | `oxidns` | `oxidnsplus` |
| rpcd | `luci.oxidns` | `luci.oxidnsplus` |
| LuCI 菜单 | Services → OxiDNS | Services → OxiDNS Plus |
| conffiles | `/etc/config/oxidns` | `/etc/config/oxidnsplus`, `/etc/oxidns/warm.list` |

## 这一版做了什么

| # | 功能 | 手段 | 真实收益 |
|---|---|---|---|
| **S1** | **TTL 感知缓存维持** | `warm.list` + `oxidnsplus-warm.sh` + 系统 crond（默认每 1 分钟调度）+ 开机立即跑一次 | 冷启动首包不冷；长 TTL 域名不再无脑重查；短 TTL 域名不会过期；上游 QPS 与日志噪声同步下降 |
| **S2** | DHCP 主机名 | 读官方 OpenWrt `/tmp/dhcp.leases` → 生成标准 hosts → 变化时可选 reload | 局域网可用设备名访问；默认关闭 |
| **S4** | 上游延迟实测 | 诊断脚本，**只出报告不改任何配置** | 挑最快的上游 |
| N5 | 查询测试 | 单次 `dig` 到本地监听口 | 排障不用 SSH |
| — | 全部参数可视化 | 独立 UCI + rpcd + LuCI 页面 + 中文翻译 | 清单、轮询间隔、提前量、TTL 钳制都在页面上改 |
| — | **自动化回退** | `prerm` + `postrm` + `cleanup` + 「还原默认」 | 停用/卸载无需手工清理 |

> S2 唯一的主配置前提：**若启用 DHCP 主机名，请在你自己的 `config.yaml`
> 的 `hosts_system.files` 中手动加入 `/etc/oxidns/dhcp-hosts`。** 本包会创建
> 一个只有注释的空文件，因此即使不启用也不会导致 OxiDNS 启动失败；
> 但它不会替你写这一行。

## TTL 感知预热怎么工作

```
crond 每 warm_interval 分钟叫醒一次调度器（默认 1 分钟）
        │
        ├─ 读 /tmp/oxidnsplus-warm.entries 里每条记录的 TTL 与上次查询时间
        ├─ 到期判定：now + poll_seconds >= last + refresh_at
        │     refresh_at = TTL × (100 - warm_margin_percent) / 100
        │                 再钳制到 [warm_min_ttl, warm_max_ttl]，且不超过 TTL
        │     「向前看一个轮询窗口」保证分钟粒度不会错过任何过期点
        ├─ 只 dig 到期的 (域名, 类型)，从应答第 2 列读回新的 TTL
        └─ 合并回状态文件；失败项按 warm_retry_ttl 退避，不覆盖旧 TTL
```

`dig +noall +answer` 从应答里读到的是**这份缓存答案还能活多久**（CNAME 链取
最小值），正好是刷新所需的信号；查询打给本机 OxiDNS 监听口，会走完整策略链
并把新答案写回缓存。NODATA / NXDOMAIN / 被拦截的应答没有 TTL 可读，用
`warm_noanswer_ttl` 兜底。

**自动重建基线的四种情况**：显式 `--force`（LuCI「立即预热」）、状态文件丢失
（重启后 `/tmp` 清空）、OxiDNS 进程集变化（核心重启 = 内存缓存没了）、预热清单
被保存过。

对比旧方案：固定 2 分钟全量 = 54 次 / 120 s；新方案下 TTL 300 s 的条目约
每 4 分钟才查一次，TTL 3600 s 的约每 48 分钟一次，而 TTL 60 s 的每分钟查
一次（旧方案会让它在两轮之间过期）。**总查询数由 TTL 分布决定，通常明显更少，
且不再有过期空窗。**

## 安装

依赖：`luci-base`、`rpcd`、`jsonfilter`、`bind-dig`。
**不**硬依赖 `oxidns-core`（基础包默认走运行时上传安装，硬依赖会导致装不上）。

```sh
# OpenWrt buildroot / SDK：把本仓库放进 package/ 或 feed，
# menuconfig 选 luci-app-oxidns-plus
make package/luci-app-oxidns-plus/compile V=s

# 或直接装已构建的 ipk / apk
opkg install luci-app-oxidns-plus_*.ipk     # 或 apk add ...
/etc/init.d/oxidnsplus enable
/etc/init.d/oxidnsplus start
```

安装脚本会修复可执行位、创建空的 `/etc/oxidns/dhcp-hosts`、把可编辑文件加入
`/etc/sysupgrade.conf`、重启 rpcd。

## 快速开始

1. 进 LuCI → **Services → OxiDNS Plus**。
2. 「运行状态」看 `Cache keeper` 与 `Last warming` 的 `total / due / skipped`。
3. 「预热清单」里编辑域名，默认 27 个有效域名（YouTube / Google / GitHub）。
4. 想立刻验证点「立即预热」，然后 `cat /tmp/oxidnsplus-warm.entries` 看每条 TTL。
5. 要用 DHCP 主机名：先在自己的 `config.yaml` 挂上 `/etc/oxidns/dhcp-hosts`，
   再打开开关（自动重载默认关闭）。

所有 UCI 选项见 [CONFIGURATION](docs/CONFIGURATION.md)。

### 关于预热清单

原清单里有 **10 个域名会被现有广告规则拦截**（doubleclick ×4、
googlesyndication ×2、googletagservices、google-analytics ×2、2mdn）。
预热它们只会得到不缓存的 black_hole 应答，纯浪费 QPS，因此默认注释禁用。
想启用需同时加白名单。

## 停用 / 还原 / 卸载（全部自动化）

| 动作 | 自动做了什么 | 剩下什么 |
|---|---|---|
| `/etc/init.d/oxidnsplus stop` | 移除 cron 标记块、重载 crond | UCI 配置、清单、`/tmp` 状态保留 |
| LuCI「还原默认」 | 从只读副本恢复 UCI 与 `warm.list`、清空状态、清空 `dhcp-hosts` 为空 stub、重装 cron 块 | 主配置**完全没动** |
| `opkg remove`（`prerm` + `postrm`） | stop / disable / cleanup、清 `/etc/sysupgrade.conf` 三行、删 `/tmp` 状态、清 cron 块、重启 rpcd | conffiles（opkg 默认保留）、**空的** `dhcp-hosts` stub |

`dhcp-hosts` 故意**只清空不删除**：你的 `config.yaml` 里可能引用了它，直接删文件
会让下次 OxiDNS 启动失败。如果确实不再需要，手动删掉主配置里的那一行再删文件。

因为**主配置从未被本包修改**，停用/卸载后不存在「把 `lazy_cache_ttl` 改回去」
这类动作 —— 它一直是你自己文件里的值。

## 两个已知代价

- **S2 的 reload 会丢缓存**：OxiDNS 重载配置时会等 `cache.dump` 恢复，
  但 dump 周期是 600 s，最近十分钟内的条目仍会丢。所以
  `dhcp_auto_reload` 默认 `0`，同步间隔默认 10 分钟，且只在生成文件
  实际变化时才触发。
- **预热仍然会向上游发查询**：TTL 感知只是把「固定全量」变成「按寿命」，
  不是零成本。清单越长、TTL 越短，QPS 越高；`warm_min_ttl` 就是防短 TTL
  狂刷的下限。

## 明确不做

- 任何形式的配置模板、配置建议、配置调优、配置体检（0.2.0 起）。
- 需要改官方二进制的 F/N 类：`serve_stale_client_timeout_ms`、过期前
  原生刷新、原生 `prefetch` 插件、主动探测 + EWMA 熔断。当前核心是
  **预编译 musl 二进制**，落点见 [ROADMAP](docs/ROADMAP.md)。
- L3 内核改动（零重编码、`SO_REUSEPORT`、`recvmmsg`、请求级 EWMA 对冲）。
- guest 全系列、ECS 注入、CHAOS 彩蛋、DoH Canary、`tcp/udp` 双发、
  按请求方切缓存、DoQ 0-RTT。逐项理由见 [FEATURES](docs/FEATURES.md)。

## 许可证与来源

GPL-3.0-or-later，见 [LICENSE](LICENSE)。

只**借鉴设计**、**独立实现**，没有复制 PhotoDNS（GPL-3.0-**only**）、
KixDNS 或 mosdns 的任何源码。PhotoDNS 是 `GPL-3.0-only`，直接搬源码会
让整体只能按 only 分发；本包保持 `or-later` 与基础包一致。

OxiDNS 本体属于 [svenshi/oxidns](https://github.com/svenshi/oxidns)，
本仓库与其无隶属关系，也不向其提交改动。
