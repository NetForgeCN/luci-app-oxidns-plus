# luci-app-oxidns-plus (OpenWrt feed)

TTL-adaptive prewarming add-on for OxiDNS 1.7.x — x86_64 only.

This repository is a standard OpenWrt feed. The package lives in
[`luci-app-oxidns-plus/`](luci-app-oxidns-plus/), following the layout that
`scripts/feeds` and `include/scan.mk` expect. Add it to `feeds.conf`:

```sh
src-git oxidnsplus https://github.com/NetForgeCN/luci-app-oxidns-plus.git
```

Then:

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
make menuconfig   # LuCI -> Applications -> luci-app-oxidns-plus
make -j$(nproc)
```

> Do **not** place the package Makefile at the repository root. `scan.mk`
> strips package paths with `sed 's#/Makefile:.*##'`, which requires a `/`
> before `Makefile`. A root-level Makefile leaves
> `Makefile:$(eval $(call BuildPackage,...))` as a bogus package directory,
> causing `index missing` and a broken `.files-packageinfo.mk`.

See the [package README](luci-app-oxidns-plus/README.md) for the design,
configuration options and rebuild instructions.

License: GPL-3.0-or-later.
