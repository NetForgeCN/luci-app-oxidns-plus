# luci-app-oxidns-plus

> OxiDNS 增强附加包：按 TTL 维持缓存、DHCP 主机名、上游诊断、可视化配置。
> 只加一层，不换核心，**不改主配置**。

[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

## 定位与边界

这是**附加包（add-on）**，不是 `luci-app-oxidns` 的替代品，需要原运行时已装好：

- 先装 OxiDNS 核心（通过 [NetForgeCN/luci-app-oxidns](https://github.com/NetForgeCN/luci-app-oxidns)
  的 LuCI 安装/上传，或手工部署），再装本包。
- 本仓库不含 OxiDNS Rust 源码，不含核心二进制，不修改 `luci-app-oxidns` 的任何文件。
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

## 功能

| 功能 | 手段 | 效果 |
|---|---|---|
| **TTL 感知缓存维持** | `warm.list` + `oxidnsplus-warm.sh` + 系统 crond（默认每 1 分钟调度）+ 开机立即跑一次 | 冷启动首包不冷；长 TTL 域名不再无脑重查；短 TTL 域名不会过期；上游 QPS 与日志噪声同步下降 |
| **DHCP 主机名** | 读官方 OpenWrt `/tmp/dhcp.leases` → 生成标准 hosts → 变化时可选 reload | 局域网可用设备名访问；默认关闭 |
| **上游延迟实测** | 诊断脚本，只出报告不改任何配置 | 挑最快的上游 |
| **查询测试** | 单次 `dig` 到本地监听口 | 排障不用 SSH |
| **全部参数可视化** | 独立 UCI + rpcd + LuCI 页面 + 中文翻译 | 清单、轮询间隔、提前量、TTL 钳制都在页面上改 |
| **自动化回退** | `prerm` + `postrm` + `cleanup` + 「还原默认」 | 停用/卸载无需手工清理 |

> 启用 DHCP 主机名时，请在你自己的 `config.yaml` 的 `hosts_system.files` 中
> 手动加入 `/etc/oxidns/dhcp-hosts`。本包会创建一个只有注释的空文件，
> 因此即使不启用也不会导致 OxiDNS 启动失败；但它不会替你写这一行。

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

`dig +noall +answer` 从应答里读到的是**这份缓存答案还能活多久**（CNAME 链取最小值），正好是刷新所需的信号；查询打给本机 OxiDNS 监听口，会走完整策略链并把新答案写回缓存。NODATA / NXDOMAIN / 被拦截的应答没有 TTL 可读，用 `warm_noanswer_ttl` 兜底。

**自动重建基线的四种情况**：显式 `--force`（LuCI「立即预热」）、状态文件丢失（重启后 `/tmp` 清空）、OxiDNS 进程集变化（核心重启 = 内存缓存没了）、预热清单被保存过。

查询数由 TTL 分布决定：TTL 300 s 的条目约每 4 分钟查一次，TTL 3600 s 的约每 48 分钟一次，TTL 60 s 的每分钟查一次。

## 安装

依赖：`luci-base`、`rpcd`、`jsonfilter`、`bind-dig`。不硬依赖 `oxidns-core`（基础包默认走运行时上传安装）。

```sh
# OpenWrt buildroot / SDK：把本仓库放进 package/ 或 feed，
# menuconfig 选 luci-app-oxidns-plus
make package/luci-app-oxidns-plus/compile V=s

# 或直接装已构建的 ipk / apk
opkg install luci-app-oxidns-plus_*.ipk     # 或 apk add ...
/etc/init.d/oxidnsplus enable
/etc/init.d/oxidnsplus start
```

安装脚本会修复可执行位、创建空的 `/etc/oxidns/dhcp-hosts`、把可编辑文件加入 `/etc/sysupgrade.conf`、重启 rpcd。

## 快速开始

1. 进 LuCI → **Services → OxiDNS Plus**。
2. 「运行状态」看 `Cache keeper` 与 `Last warming` 的 `total / due / skipped`。
3. 「预热清单」里编辑域名，默认 27 个有效域名（YouTube / Google / GitHub）。
4. 想立刻验证点「立即预热」，然后 `cat /tmp/oxidnsplus-warm.entries` 看每条 TTL。
5. 要用 DHCP 主机名：先在自己的 `config.yaml` 挂上 `/etc/oxidns/dhcp-hosts`，再打开开关（自动重载默认关闭）。

所有 UCI 选项见 [CONFIGURATION](docs/CONFIGURATION.md)。

### 关于预热清单

清单里 10 个会被现有广告规则拦截的域名（doubleclick ×4、googlesyndication ×2、googletagservices、google-analytics ×2、2mdn）默认注释禁用：预热它们只会得到不缓存的 black_hole 应答。想启用需同时加白名单。

## 停用 / 还原 / 卸载（全部自动化）

| 动作 | 自动做了什么 | 剩下什么 |
|---|---|---|
| `/etc/init.d/oxidnsplus stop` | 移除 cron 标记块、重载 crond | UCI 配置、清单、`/tmp` 状态保留 |
| LuCI「还原默认」 | 从只读副本恢复 UCI 与 `warm.list`、清空状态、清空 `dhcp-hosts` 为空 stub、重装 cron 块 | 主配置完全没动 |
| `opkg remove`（`prerm` + `postrm`） | stop / disable / cleanup、清 `/etc/sysupgrade.conf` 三行、删 `/tmp` 状态、清 cron 块、重启 rpcd | conffiles（opkg 默认保留）、空的 `dhcp-hosts` stub |

`dhcp-hosts` 只清空不删除：你的 `config.yaml` 里可能引用了它，直接删文件会让下次 OxiDNS 启动失败。如果确实不再需要，手动删掉主配置里的那一行再删文件。

## 已知代价

- **DHCP 主机名的 reload 会丢缓存**：OxiDNS 重载配置时会等 `cache.dump` 恢复，但 dump 周期是 600 s，最近十分钟内的条目仍会丢。所以 `dhcp_auto_reload` 默认 `0`，同步间隔默认 10 分钟，且只在生成文件实际变化时才触发。
- **预热仍然会向上游发查询**：TTL 感知只是把「固定全量」变成「按寿命」，不是零成本。清单越长、TTL 越短，QPS 越高；`warm_min_ttl` 就是防短 TTL 狂刷的下限。

功能范围与后续规划见 [FEATURES](docs/FEATURES.md) 与 [ROADMAP](docs/ROADMAP.md)。

## 许可证与来源

GPL-3.0-or-later，见 [LICENSE](LICENSE)。独立实现，不复制 PhotoDNS、KixDNS 或 mosdns 的源码，保持 `or-later` 与基础包一致。

OxiDNS 本体属于 [svenshi/oxidns](https://github.com/svenshi/oxidns)，本仓库与其无隶属关系。
