# 配置说明

所有设置都在 UCI 包 `oxidnsplus` 的 `main` 段，也可以在 LuCI →
**Services → OxiDNS Plus** 里改。改完点「保存设置」，init 脚本会自动
重装 crond 任务块，间隔立即生效。

## UCI 选项表

### 缓存预热（S1）

| 选项 | 默认 | 说明 |
|---|---|---|
| `warm_enabled` | `1` | 总开关；关掉后不再安装预热 cron 条目 |
| `warm_interval` | `2` | 周期，**分钟**，最小 1。系统 crond 只支持分钟粒度 |
| `warm_types` | `A AAAA` | 每种域名查哪些记录；可为 `A` / `AAAA` / `A AAAA` |
| `warm_list` | `/etc/oxidns/warm.list` | 清单路径，**必须**在 `/etc/oxidns/` 下（rpcd 校验） |
| `warm_on_boot` | `1` | 启动时立即后台预热一次，避开 cron 首个间隔 |
| `warm_wait_ready` | `15` | 冷启动时最多等多少秒 `oxidns` 进程出现 |
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
| `hosts_output` | `/etc/oxidns/dhcp-hosts` | 标准 hosts 输出（IP 在前） |
| `dhcp_auto_reload` | `0` | 文件变化时自动 `/etc/init.d/oxidns reload` |
| `reload_mode` | `signal` | `signal`（温和）/ `restart`（确定生效但代价大） |

### 路径（与基础包默认值对齐）

| 选项 | 默认 | 说明 |
|---|---|---|
| `config_path` | `/etc/oxidns/config.yaml` | 只用于体检与配置调优，**不会被自动改写** |
| `working_dir` | `/var/lib/oxidns` | `oxidns check -d` 用；备份也放这里的 `config-backups/` |

## 部署检查清单

1. **OxiDNS 核心已安装并运行**：`/usr/bin/oxidns`、`/etc/oxidns/config.yaml` 存在，
   `/etc/init.d/oxidns start` 可用。
2. **`bind-dig` 已安装**：busybox 的 `nslookup` 不能指定端口 5333，预热和诊断都依赖 `dig`。
3. **`config_path` 里的 `hosts_system.files` 必须包含 `/etc/oxidns/dhcp-hosts`**，
   否则 S2 生成的文件不会被读取。推荐配置模板已带这一行，可在 LuCI 点
   「Recommended config」查看后复制；「配置体检」里的 `dhcp-hosts referenced`
   会显示当前是否已挂上。
4. **防环**：若本地域名转发给 dnsmasq，dnsmasq 侧必须配
   `local=/lan/ /home.arpa/ ...`，且 53 与 5333 分离，否则
   `53 → 5333 → 53` 会形成查询环。
5. **开机启用**：`/etc/init.d/oxidnsplus enable && /etc/init.d/oxidnsplus start`。

## 重载代价（重要）

OxiDNS 重载配置时会等 `cache.dump` 恢复，缓存**不是全清**，但 dump 周期是
600 s，**最近十分钟内的条目仍会丢**。因此：

- `dhcp_auto_reload` 默认 `0`；同步脚本只在生成文件内容**实际变化**时才考虑重载。
- `dhcp_interval` 默认 10 分钟，避免频繁重载。
- 想完全避免，就保持自动重载关闭，需要时在 LuCI 点「立即同步 DHCP」并勾选
  `reload`，手动挑个低峰时刻执行。
- `reload_mode=signal` 调用基础包 `/etc/init.d/oxidns reload`
  （`procd_send_signal`）；若实测发现 hosts 文件未重新加载，改成 `restart`。

## 闪存写入

| 来源 | 频率 | 说明 |
|---|---|---|
| crond 任务块 | 每次 init restart | 写 `/etc/crontabs/root`，很小 |
| `warm.list` | 仅用户编辑时 | conffile，已加入 sysupgrade.conf |
| `dhcp-hosts` | 仅租约变化时 | 默认关闭，启用后变化才写 |
| 状态文件 | 每次运行 | 写在 `/tmp`，内存文件系统，**不写闪存** |
| 日志 | 每次运行 | `logger` → syslog 内存环形缓冲，不写文件 |
| config 备份 | 每次配置调优 | `/var/lib/oxidns/config-backups/`，可手动清理 |

OxiDNS 本身的 `cache.dump`（600 s）与规则订阅（12 h）属于基础包，不在本包控制范围。

## 预热清单

- 一行一个域名，空行与 `#` 注释忽略；只接受 `[A-Za-z0-9._-]`。
- 默认 27 个有效域名（YouTube / Google / GitHub）。
- **10 个域名被默认注释禁用**：`googleads.g.doubleclick.net`、
  `static.doubleclick.net`、`pubads.g.doubleclick.net`、
  `securepubads.g.doubleclick.net`、`pagead2.googlesyndication.com`、
  `tpc.googlesyndication.com`、`www.googletagservices.com`、
  `www.google-analytics.com`、`ssl.google-analytics.com`、`s0.2mdn.net`。
  它们会被现有广告规则（geosite `category-ads-all` 与两个 AdGuard 订阅）拦截，
  预热只会得到不缓存的 black_hole 应答，纯浪费 QPS。想启用需同时加白名单。
- 频率建议 2 分钟：YouTube / Google 的 TTL 普遍 60–300 s。

## 常用命令

```sh
uci show oxidnsplus.main
uci set oxidnsplus.main.warm_interval='5'
uci commit oxidnsplus
/etc/init.d/oxidnsplus restart          # 重装 cron 块

/etc/init.d/oxidnsplus warm             # 立即预热一次
/etc/init.d/oxidnsplus sync             # 立即同步 DHCP（不重载）
/etc/init.d/oxidnsplus sync --reload    # 同步并重载

cat /tmp/oxidnsplus-warm.state          # 上次预热结果
cat /tmp/oxidnsplus-dhcp.state          # 上次 DHCP 同步结果
logread -e oxidns-plus                  # 运行日志
/usr/libexec/oxidnsplus-diagnose.sh     # 上游延迟报告

oxidns check -c /etc/oxidns/config.yaml -d /var/lib/oxidns
```

## 排障

| 现象 | 检查 |
|---|---|
| 预热没效果 | `cat /tmp/oxidnsplus-warm.state`；`dig @127.0.0.1 -p 5333 www.google.com A`；确认 `bind-dig` 已装、端口正确 |
| 状态页 `core_running = No` | `pgrep -x oxidns`；基础包服务是否启动 |
| 状态页 `cron_installed = No` | `/etc/init.d/oxidnsplus enabled`；`/etc/crontabs/root` 里是否有 `# oxidns-plus:begin` 块 |
| 状态页 `scripts_ok = No` | 重新跑安装脚本的 chmod，或 `chmod 755 /usr/libexec/oxidnsplus-*.sh` |
| DHCP 主机名不生效 | `dhcp-hosts referenced` 是否为 Yes；`cat /etc/oxidns/dhcp-hosts`；租约文件是否可读；是否需要 `reload_mode=restart` |
| 配置调优失败 | rpcd 会返回 `oxidns check` 的错误；原文件保持不变，备份在 `/var/lib/oxidns/config-backups/` |
