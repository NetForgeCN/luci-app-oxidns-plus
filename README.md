# luci-app-oxidns-plus

> OxiDNS 增强附加包：缓存预热、DHCP 主机名、上游诊断、可视化配置。
> 只加一层，不换核心。

[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

## 为什么叫 plus，不叫 pro

选 **`luci-app-oxidns-plus`**。这个包打包的仍然是**官方 1.7.1 预编译二进制**，
它没有重写 OxiDNS 内核，只是在旁边加了一层配置、脚本和 LuCI 管理界面。
`plus`（加料）准确描述这件事；`pro` 容易被理解成深度改造过引擎，
也带一点商业版暗示。若之后真把 Rust 源码和补丁接进本仓库（见
[ROADMAP](docs/ROADMAP.md) 第二阶段），那时再改名 `pro` 也不迟。

目录名、包名、UCI 名、菜单名都统一用 `oxidnsplus` / `oxidns-plus`。

## 定位与边界

这是**附加包（add-on）**，不是 `luci-app-oxidns` 的替代品，需要原运行时已装好：

- 先装 OxiDNS 核心（通过 [NetForgeCN/luci-app-oxidns](https://github.com/NetForgeCN/luci-app-oxidns)
  的 LuCI 安装/上传，或手工部署），再装本包。
- 本仓库**不含** OxiDNS Rust 源码，**不含**核心二进制，**不推送**到
  `svenshi/oxidns`，也**不修改** `luci-app-oxidns` 的任何文件。
- 本包**不自动改写** `/etc/oxidns/config.yaml`。它属于基础安装，是 conffile。
  唯一会碰它的动作是 LuCI 上手动触发的「配置调优」，且带备份、校验、失败回滚。

所有命名空间都与原包隔离，两个包可以同时装、互不影响：

| | 基础包 | 本包 |
|---|---|---|
| UCI | `oxidns.main` | `oxidnsplus.main` |
| init.d | `oxidns` | `oxidnsplus` |
| rpcd | `luci.oxidns` | `luci.oxidnsplus` |
| LuCI 菜单 | Services → OxiDNS | Services → OxiDNS Plus |
| conffiles | `/etc/config/oxidns` | `/etc/config/oxidnsplus`, `/etc/oxidns/warm.list` |

## 这一版做了什么

| # | 功能 | 来源 | 手段 | 真实收益 |
|---|---|---|---|---|
| P1 | `lazy_cache_ttl` 86400 → 3600 | 整合评估 | 手动触发的字段级调优（备份 + `oxidns check` + 回滚） | 上游失败时不再返回隔夜旧 IP；stale 兜底仍在 |
| P2 | ECS 全剥离 | 已确认 | 推荐配置保持 `edns_strip(strip_unknown + denylist:[8])`；状态页检测并告警 | 防指纹、防缓存碎片 |
| P3 | 去掉 guest 分支 | 已确认不要 | 推荐配置不含 `client_ip` 分流与按请求方切缓存 | 少一次 matcher 求值，维护面更小 |
| **S1** | **缓存预热** | PhotoDNS / 预热列表 | `warm.list` + 预热脚本 + 系统 crond + 开机立即跑一次 | 消除重启/清缓存后的**首次访问冷未命中**：从完整 DoH 握手 RTT 降到 <1 ms |
| **S2** | **DHCP 主机名** | PhotoDNS 租约学习 | 读官方 OpenWrt `/tmp/dhcp.leases` → 生成标准 hosts → 变化时可选 reload | 局域网可用设备名访问；默认关闭，避免频繁 reload 伤缓存 |
| **S4** | 上游延迟实测 | 整合评估 | 诊断脚本，只出报告不改配置 | 挑最快的两家上游，比加任何规则都有效 |
| N5 | 查询测试 + 配置体检 | PhotoDNS WebUI | 单次解析测试、上游延迟报告、`lazy_cache_ttl` / ECS / `hosts_system` 体检 | 排障不用 SSH |
| — | **全部参数可视化** | 用户要求「后续便捷调整」 | 独立 UCI + rpcd + LuCI 页面 + 中文翻译 | 预热清单、频率、开关都在页面上改 |

预热与 DHCP 同步走的是 **OpenWrt 系统 crond**，不是 OxiDNS 内部的
`cron` / `script` 插件 —— 这是本包不需要改主配置就能工作的关键。

## 明确不做（以及为什么）

按「收益低但工作量大的先不考虑」这条尺子砍掉：

- **需要改官方二进制的 F/N 类**：`serve_stale_client_timeout_ms`、
  过期前提前刷新、`prefetch_min_hits`、TTL 倍增、原生 `prefetch` 插件、
  主动探测 + EWMA 熔断。当前核心是**预编译 musl 二进制**，落地这些必须把
  Rust 源码 vendor 进自家仓库 + 交叉编译 + 长期 rebase 上游，是工作量最大的
  一类。接入方式与字段清单已写在 [ROADMAP](docs/ROADMAP.md)，
  推荐配置里 F1 字段以注释形式留好，自定义二进制一上就能启用。
- **L3 内核改动**：零重编码字节转发 / `SO_REUSEPORT` / `recvmmsg` /
  请求级 EWMA 对冲。会破坏 `DnsContext` 可组合性，明确不碰。
- **guest 全系列**（用户明确不要）、**ECS 注入**（用户明确要全剥离）。
- **边角料规则**：CHAOS TXT 彩蛋、DoH Canary 拦截、占位示例条目、
  `tcp/udp` 双发（QPS 翻倍）、独立 guest 缓存（碎片化）、
  DoQ 0-RTT（本拓扑上游全是 DoH/DoT/UDP，无 `doq://`）。
- 动态 permits 流控、并发未命中去重、自适应流控、Kix JSON→YAML 生成器。

完整清单与逐项理由见 [FEATURES](docs/FEATURES.md)。

## 安装

依赖：`luci-base`、`rpcd`、`jsonfilter`、`bind-dig`。
**不**硬依赖 `oxidns-core`（基础包默认走运行时上传安装，硬依赖会导致装不上）。

```sh
# OpenWrt buildroot / SDK
# 把本仓库放进 package/ 或 feed，menuconfig 选 luci-app-oxidns-plus
make package/luci-app-oxidns-plus/compile V=s

# 或直接装已构建的 ipk / apk
opkg install luci-app-oxidns-plus_*.ipk     # 或 apk add ...
/etc/init.d/oxidnsplus enable
/etc/init.d/oxidnsplus start
```

安装脚本会自动修复可执行位、创建空的 `/etc/oxidns/dhcp-hosts`、
把可编辑文件加入 `/etc/sysupgrade.conf`、重启 rpcd。

## 快速开始

1. 进 LuCI → **Services → OxiDNS Plus**。
2. 「配置体检」看当前配置里 `lazy_cache_ttl` / ECS / `hosts_system` 的状态。
3. 需要时点「配置调优」（只把 `lazy_cache_ttl` 改成 3600，可回滚）。
4. 「预热清单」里编辑域名，默认 27 个有效域名（YouTube / Google / GitHub）。
5. 默认每 2 分钟预热一次，开机立即跑一次；立即验证可点「立即预热」。
6. 要用 DHCP 主机名：先确认 `config.yaml` 的 `hosts_system.files` 里有
   `/etc/oxidns/dhcp-hosts`（推荐配置已带），再打开开关。

所有 UCI 选项见 [CONFIGURATION](docs/CONFIGURATION.md)。

### 关于预热清单

用户给的原清单里有 **10 个域名会被现有广告规则拦截**
（doubleclick ×4、googlesyndication ×2、googletagservices、
google-analytics ×2、2mdn）。预热它们只会得到不缓存的 black_hole
应答，纯浪费上游 QPS，因此默认注释禁用并写明原因。想启用需同时加白名单。

频率默认 **2m**：27 域名 × A/AAAA = 54 次查询，串行约 3 秒跑完，
平均 <0.5 QPS，能覆盖 YouTube / Google 常见的 60–300 s TTL。

## 两个已知代价

- **S2 的 reload 会丢缓存**：OxiDNS 重载配置时会等 `cache.dump` 恢复，
  但 dump 周期是 600 s，最近十分钟内的条目仍会丢。所以
  `dhcp_auto_reload` 默认 **0**，同步间隔默认 10 分钟，且只在生成文件
  实际变化时才触发。想完全避免就保持关闭，手动点「立即同步并重载」。
- **预热放大上游 QPS**：清单越长、间隔越短，代价越大。默认参数下
  可忽略，但不要把它当成免费功能。

## 许可证与来源

GPL-3.0-or-later，见 [LICENSE](LICENSE)。

只**借鉴设计**、**独立实现**，没有复制 PhotoDNS（GPL-3.0-**only**）、
KixDNS 或 mosdns 的任何源码。PhotoDNS 是 `GPL-3.0-only`，直接搬源码会
让整体只能按 only 分发；本包保持 `or-later` 与基础包一致。

OxiDNS 本体属于 [svenshi/oxidns](https://github.com/svenshi/oxidns)，
本仓库与其无隶属关系，也不向其提交改动。
