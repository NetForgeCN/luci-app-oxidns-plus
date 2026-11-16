# 配置说明

所有设置都在 UCI 包 `oxidnsplus` 的 `main` 段，也可以在 LuCI →
**Services → OxiDNS Plus** 里改。改完点「保存设置」，init 脚本会自动
重装 crond 任务块，轮询间隔立即生效。

> **本包不读写 `/etc/oxidns/config.yaml`。** 主配置的所有参数由你直接在
> 自己的文件里修改并 reload。下文出现的 `config.yaml` 只是说明某个功能
> 依赖哪一行，本包不会替你添加、校验或备份。

## UCI 选项表

### 缓存预热 / 维持（S1）

| 选项 | 默认 | 说明 |
|---|---|---|
| `warm_enabled` | `1` | 总开关；关掉后不再安装预热 cron 条目 |
| `warm_interval` | `1` | **调度轮询周期（分钟）**，最小 1。crond 只负责叫醒调度器，不是「每 N 分钟全量预热」 |
| `warm_types` | `A AAAA` | 每种域名维护哪些记录；可为 `A` / `AAAA` / `A AAAA` |
| `warm_list` | `/etc/oxidns/warm.list` | 清单路径，**必须**在 `/etc/oxidns/` 下（rpcd 校验） |
| `warm_on_boot` | `1` | 启动时立即后台预热一次，避开 cron 首个间隔 |
| `warm_wait_ready` | `15` | 冷启动时最多等多少秒 `oxidns` 进程出现 |
| `warm_margin_percent` | `20` | **提前刷新比例**：TTL 剩 20% 时刷新，即 `refresh_at = TTL × 80%`。范围 0–90 |
| `warm_min_ttl` | `30` | 计算出的刷新间隔下限（秒），防短 TTL 狂刷 |
| `warm_max_ttl` | `3600` | 刷新间隔上限（秒），且永不超过观测到的 TTL |
| `warm_noanswer_ttl` | `300` | NODATA / NXDOMAIN / 被拦截时应答无 TTL 可读，用这个值兜底 |
| `warm_retry_ttl` | `30` | 查询失败后的退避间隔；失败不覆盖已知的好 TTL |
| `resolver` | `127.0.0.1` | 预热查询打给哪个地址（本机的 OxiDNS 监听口） |
| `resolver_port` | `5333` | 对应端口 |
| `dig_timeout` | `1` | 单次 `dig` 超时（秒） |
| `dig_tries` | `1` | 单次 `dig` 重试次数 |
| `sleep_between` | `0` | 每次查询之间的间隔（秒），可调大以降低瞬时 QPS |

### DHCP 主机名（S2）

| 选项 | 默认 | 说明 |
|---|---|---|
| `dhcp_enabled` | `0` | **默认关闭**。打开前请先读下面「重载代价」 |
| `dhcp_interval` | `10` | 同步周期，分钟 |
| `lease_file` | `/tmp/dhcp.leases` | 官方 OpenWrt `dnsmasq.init` 硬编码的租约文件 |
| `lease_domain` | `lan` | 生成 `hostname.lan` 形式 |
| `hosts_output` | `/etc/oxidns/dhcp-hosts` | 标准 hosts 输出（IP 在前），必须在 `/etc/oxidns/` 下 |
| `dhcp_auto_reload` | `0` | 文件变化时自动 `/etc/init.d/oxidns reload` |
| `reload_mode` | `signal` | `signal`（温和）/ `restart`（确定生效但代价大） |

## TTL 调度机制

状态文件 `/tmp/oxidnsplus-warm.entries`，每行一条：

```
core_sig=1234,5678,
www.youtube.com|A|300|1731772800|ok
www.google.com|AAAA|60|1731772800|no_answer
```

字段依次是 `域名|记录类型|观测 TTL|上次查询 epoch|备注`。判定规则：

```
refresh_at = clamp( ttl × (100 - warm_margin_percent) / 100,
                    warm_min_ttl, warm_max_ttl )
refresh_at = min(refresh_at, ttl)          # 永不排到过期之后
到期条件：now + warm_interval×60 >= last + refresh_at
```

最后的 `+ poll` 是**向前看一个轮询窗口**：crond 只有分钟粒度，提前把「下一轮
会来不及」的条目在这一轮查掉，就不会出现 TTL 在两次轮询之间过期。

自动全量重建基线的四种触发：`--force`、状态文件不存在、OxiDNS 进程集签名
变化（核心重启 = 内存缓存清空）、保存过预热清单。

**为什么不用 OxiDNS 的 cache API**：`GET /plugins/<tag>/entries` 只返回
`qname / answer_ip / limit / cursor`，**不返回剩余 TTL**，配置层拿不到刷新
信号。而 `dig` 的 answer section 直接带 TTL，纯 shell 就能拿到，不需要凭据、
不需要改二进制。

## 部署检查清单

1. **OxiDNS 核心已安装并运行**：`/usr/bin/oxidns` 存在，5333 端口在监听，
   `/etc/init.d/oxidns start` 可用。
2. **`bind-dig` 已安装**：busybox 的 `nslookup` 不能指定端口 5333，
   也不能读 answer TTL，预热和诊断都依赖 `dig`。
3. **若启用 S2**：在你自己的 `/etc/oxidns/config.yaml` 的
   `hosts_system.files` 中手动加入 `/etc/oxidns/dhcp-hosts`。本包会创建
   空 stub 保证引用不会导致启动失败，但不会替你写这一行。
4. **防环**：若本地域名转发给 dnsmasq，dnsmasq 侧必须配
   `local=/lan/ /home.arpa/ ...`，且 53 与 5333 分离。
5. **开机启用**：`/etc/init.d/oxidnsplus enable && /etc/init.d/oxidnsplus start`。

## 重载代价（仅 S2）

OxiDNS 重载配置时会等 `cache.dump` 恢复，缓存**不是全清**，但 dump 周期是
600 s，**最近十分钟内的条目仍会丢**。因此：

- `dhcp_auto_reload` 默认 `0`；同步脚本只在生成文件内容**实际变化**时才考虑重载。
- `dhcp_interval` 默认 10 分钟。
- 想完全避免就保持关闭，需要时点「立即同步 DHCP」并勾选 `reload`。
- `reload_mode=signal` 调用基础包 `/etc/init.d/oxidns reload`；若实测发现
  hosts 文件未重新加载，改成 `restart`。

## 闪存写入

| 来源 | 频率 | 说明 |
|---|---|---|
| crond 任务块 | 每次 init restart | 写 `/etc/crontabs/root`，很小 |
| `warm.list` | 仅用户编辑时 | conffile，已加入 sysupgrade.conf |
| `dhcp-hosts` | 仅租约变化时 | 默认关闭，启用后变化才写 |
| 状态文件 | 每次运行 | `/tmp/oxidnsplus-warm.{state,entries}`，内存文件系统，**不写闪存** |
| 日志 | 每次运行 | `logger` → syslog 内存环形缓冲，不写文件 |

OxiDNS 本身的 `cache.dump`（600 s）与规则订阅（12 h）属于基础包，不在本包范围。

## 预热清单

- 一行一个域名，空行与 `#` 注释忽略；只接受 `[A-Za-z0-9._-]`。
- 默认 27 个有效域名（YouTube / Google / GitHub）。
- **10 个域名被默认注释禁用**：`googleads.g.doubleclick.net`、
  `static.doubleclick.net`、`pubads.g.doubleclick.net`、
  `securepubads.g.doubleclick.net`、`pagead2.googlesyndication.com`、
  `tpc.googlesyndication.com`、`www.googletagservices.com`、
  `www.google-analytics.com`、`ssl.google-analytics.com`、`s0.2mdn.net`。
  它们会被现有广告规则拦截，预热只会得到不缓存的 black_hole 应答。
- 保存清单会自动丢弃 TTL 基线，下一轮重新观测。

## 停用 / 还原 / 卸载

```sh
/etc/init.d/oxidnsplus stop          # 移除 cron 块，功能立刻停
/etc/init.d/oxidnsplus disable       # 开机不再自启
/etc/init.d/oxidnsplus cleanup       # 清 /tmp 状态 + 把 dhcp-hosts 重置为空 stub
opkg remove luci-app-oxidns-plus     # prerm 自动执行上面三步并清 sysupgrade.conf
```

LuCI 的「还原默认」会把 `/etc/config/oxidnsplus` 与 `warm.list` 从
`/usr/share/oxidnsplus/*.defaults` 恢复、清状态、重装 cron 块。

**唯一可能的手工收尾**：如果你曾在主配置里加过 `/etc/oxidns/dhcp-hosts`
引用，卸载后想彻底清掉，应**先删主配置里那一行，再删空 stub 文件**，顺序
反了会让 OxiDNS 下次启动找不到文件。除此之外，主配置从头到尾没被改过。

## 常用命令

```sh
uci show oxidnsplus.main
uci set oxidnsplus.main.warm_margin_percent='25'
uci commit oxidnsplus
/etc/init.d/oxidnsplus restart          # 重装 cron 块

/etc/init.d/oxidnsplus warm             # 强制全量重建 TTL 基线
/etc/init.d/oxidnsplus sync             # 立即同步 DHCP（不重载）
/etc/init.d/oxidnsplus sync --reload    # 同步并重载

cat /tmp/oxidnsplus-warm.state          # 上次调度汇总
cat /tmp/oxidnsplus-warm.entries        # 每条记录的 TTL 与到期基准
cat /tmp/oxidnsplus-dhcp.state
logread -e oxidns-plus                  # 运行日志
/usr/libexec/oxidnsplus-diagnose.sh     # 上游延迟报告
```

## 排障

| 现象 | 检查 |
|---|---|
| 状态页 `core_running = No` | `pgrep -x oxidns`；基础包服务是否启动 |
| 预热没效果 | `cat /tmp/oxidnsplus-warm.state`；`dig @127.0.0.1 -p 5333 www.google.com A`；确认 `bind-dig` 已装 |
| `note=core_not_running` | 核心没起来，本轮跳过；`warm_wait_ready` 可调大 |
| `queries_failed` 一直涨 | 上游或本地监听异常；失败项按 `warm_retry_ttl` 退避，不会狂刷 |
| `due` 每轮都等于 `total` | TTL 普遍很短（< `warm_min_ttl`），或 `--force` 刚跑过；属预期 |
| 状态页 `cron_installed = No` | `/etc/init.d/oxidnsplus enabled`；`/etc/crontabs/root` 是否有 `# oxidns-plus:begin` 块 |
| DHCP 主机名不生效 | 主配置的 `hosts_system.files` 是否含 `/etc/oxidns/dhcp-hosts`；租约文件是否可读；是否需要 `reload_mode=restart` |
