# AGENTS.md

## What this repository is

`luci-app-oxidns-plus` is an **add-on** for an existing OxiDNS 1.7.x runtime on
OpenWrt. It adds cache warming, DHCP-lease hostname learning, upstream latency
diagnostics, a guarded config tuning action and a LuCI page for all of it.

It is owned by NetForgeCN. It is **not** a fork of, and never pushes to,
`svenshi/oxidns`. It also does **not** modify `NetForgeCN/luci-app-oxidns`:
no shared file is overwritten, and the add-on is designed to be installed
side by side with the base LuCI app.

## Hard boundaries

- The OxiDNS core binary is **not** in this repository. The base package
  `luci-app-oxidns` (and its optional `oxidns-core` build recipe) ships the
  official prebuilt musl binary. This repository contains **no Rust code**.
- `/etc/oxidns/config.yaml` belongs to the base install. This repository never
  writes to it automatically. The only code path that touches it is the
  explicit, user-triggered `apply_config_tuning` RPC, which performs a single
  field replacement with backup + `oxidns check` validation + rollback.
- The recommended config is shipped read-only at
  `/usr/share/oxidnsplus/config.recommended.yaml` for reference/copy.
- Frontend pages must call system operations through rpcd. No shell/system
  actions directly in LuCI JavaScript.
- Do not echo API passwords into UI, logs or RPC error messages.

## Why an add-on and not a full fork

The base app has five LuCI JS pages and a ~66 KB rpcd backend. Copying them
would be pure duplication with no functional gain, and would collide with the
base package on every path (UCI, init.d, menu, rpcd object, ACL). The add-on
uses its own namespace on every axis.

## Namespaces (keep all of these distinct from the base app)

| Axis | Base app | This add-on |
|---|---|---|
| Package | `luci-app-oxidns` | `luci-app-oxidns-plus` |
| UCI | `oxidns.main` | `oxidnsplus.main` |
| init.d | `/etc/init.d/oxidns` | `/etc/init.d/oxidnsplus` |
| rpcd object | `luci.oxidns` | `luci.oxidnsplus` |
| ACL group | `luci-app-oxidns` | `luci-app-oxidns-plus` |
| LuCI menu | `admin/services/oxidns` | `admin/services/oxidnsplus` |
| LuCI view | `oxidns/*` | `oxidnsplus/plus` |
| i18n catalog | `oxidns` | `oxidnsplus` |
| Conffiles | `/etc/config/oxidns` | `/etc/config/oxidnsplus` |

## Runtime design notes

- Warming and DHCP sync run from the **system crond**, not from OxiDNS's
  internal `cron`/`script` plugins. This is the reason the add-on never needs
  to edit `config.yaml` for those features. The init script owns a marked
  block in `/etc/crontabs/root` (`# oxidns-plus:begin` / `end`) and replaces
  it idempotently.
- Cron `interval` jobs in OxiDNS wait one full interval before their first
  trigger; the init script therefore also fires one warmer run in the
  background at start. The warmer itself waits for the `oxidns` process.
- `hosts_system.files` in `config.yaml` must include
  `/etc/oxidns/dhcp-hosts` for the DHCP feature to take effect. The
  recommended config already contains it. The RPC `status` reports whether
  the running config references it.
- DHCP sync only calls the OxiDNS reload API when the generated file actually
  changed and `dhcp_auto_reload` is enabled. Reload costs cache entries newer
  than the last `cache.dump` (600 s by default), so it is off by default.

## Key paths

- `Makefile` - OpenWrt package definition, postinst permissions/conffiles.
- `root/etc/config/oxidnsplus` - default UCI settings.
- `root/etc/init.d/oxidnsplus` - cron block install + cold-start warming.
- `root/etc/oxidns/warm.list` - editable warm domain list.
- `root/usr/libexec/oxidnsplus-warm.sh` - warmer.
- `root/usr/libexec/oxidnsplus-dhcp-hosts.sh` - lease to hosts file.
- `root/usr/libexec/oxidnsplus-diagnose.sh` - upstream latency report.
- `root/usr/libexec/rpcd/luci.oxidnsplus` - rpcd backend.
- `root/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json` - ACL.
- `root/usr/share/luci/menu.d/luci-app-oxidns-plus.json` - menu.
- `htdocs/luci-static/resources/view/oxidnsplus/plus.js` - LuCI page.
- `root/usr/share/oxidnsplus/config.recommended.yaml` - reference config.
- `po/zh_Hans/oxidnsplus.po` - Simplified Chinese translation.
- `scripts/check.sh` - local static validation.

## Validation

```sh
scripts/check.sh
```

On a device, the real acceptance test is:

```sh
oxidns check -c /etc/oxidns/config.yaml -d /var/lib/oxidns
/etc/init.d/oxidnsplus restart
/etc/init.d/oxidnsplus warm
logread -e oxidns-plus
```

## Commit notes

- Conventional Commits.
- Any new rpcd method must be added to **all three**: the `list` signature,
  the `call` dispatcher, and the ACL JSON.
- Any new UCI option must be added to the default config, `settings_read`,
  `settings_save`, the LuCI form, and `docs/CONFIGURATION.md`.
