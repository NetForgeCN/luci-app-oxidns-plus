#
# Copyright (C) 2026 NetForgeCN
#
# Licensed under GPL-3.0-or-later. See /LICENSE.
#
# luci-app-oxidns-plus is an ADD-ON for an existing OxiDNS 1.7.x runtime.
# It ships a single static Go binary (oxidns-prewarmer) that performs
# TTL-adaptive stale-hit prewarming by talking to OxiDNS's own management API
# and DNS listener. It does NOT ship or modify the OxiDNS core, and it never
# reads or writes /etc/oxidns/config.yaml.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-oxidns-plus
PKG_VERSION:=0.3.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=NetForgeCN

LUCI_TITLE:=OxiDNS Plus - TTL-adaptive prewarming
LUCI_DEPENDS:=+luci-base +rpcd +jsonfilter

# The package ships a prebuilt static binary, so it is arch-specific.
LUCI_PKGARCH:=

# Select the prebuilt binary by target architecture. Binaries are built with
# CGO_ENABLED=0 (fully static) from src/prewarmer via scripts/build.sh.
PREWARMER_BIN:=prewarmer-amd64
ifneq ($(findstring aarch64,$(CONFIG_ARCH)),)
  PREWARMER_BIN:=prewarmer-arm64
else ifneq ($(findstring arm_cortex,$(CONFIG_ARCH)),)
  PREWARMER_BIN:=prewarmer-armv7
else ifneq ($(findstring armv7,$(CONFIG_ARCH)),)
  PREWARMER_BIN:=prewarmer-armv7
else ifneq ($(findstring mipsel,$(CONFIG_ARCH)),)
  PREWARMER_BIN:=prewarmer-mipsle
else ifneq ($(findstring mips,$(CONFIG_ARCH)),)
  PREWARMER_BIN:=prewarmer-mips
endif

define Package/luci-app-oxidns-plus/description
  Adds a LuCI page, UCI settings, a procd-managed binary and an rpcd API on top
  of an existing OxiDNS installation. A small static Go daemon reads the OxiDNS
  cache API for TTL truth, maintains one independent deadline per (domain,qtype)
  and fires a query at OxiDNS's own listener just after fresh expiry so the
  native lazy cache refreshes in the background. TTL changes are followed,
  retries back off, single-flight and jitter are enforced, and the old cache is
  always kept. The OxiDNS main config is never read or written.
endef

define Package/luci-app-oxidns-plus/conffiles
/etc/config/oxidnsplus
/etc/oxidnsplus/watch.list
endef

define Package/luci-app-oxidns-plus/postinst
#!/bin/sh
ROOT="$${IPKG_INSTROOT:-}"
for f in /etc/init.d/oxidnsplus /usr/libexec/rpcd/luci.oxidnsplus /usr/libexec/oxidns-prewarmer; do
	[ -f "$$ROOT$$f" ] && chmod 755 "$$ROOT$$f"
done
[ -n "$$ROOT" ] && exit 0
if [ -f /etc/sysupgrade.conf ]; then
	for entry in /etc/config/oxidnsplus /etc/oxidnsplus/watch.list; do
		grep -qxF "$$entry" /etc/sysupgrade.conf 2>/dev/null || echo "$$entry" >> /etc/sysupgrade.conf
	done
fi
rm -f /tmp/luci-indexcache* 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -x /etc/init.d/rpcd ]; then /etc/init.d/rpcd restart >/dev/null 2>&1 || true; fi
exit 0
endef

define Package/luci-app-oxidns-plus/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
if [ -x /etc/init.d/oxidnsplus ]; then
	/etc/init.d/oxidnsplus stop >/dev/null 2>&1 || true
	/etc/init.d/oxidnsplus disable >/dev/null 2>&1 || true
	/etc/init.d/oxidnsplus cleanup >/dev/null 2>&1 || true
fi
if [ -f /etc/sysupgrade.conf ]; then
	grep -vxE '/etc/config/oxidnsplus|/etc/oxidnsplus/watch.list' \
		/etc/sysupgrade.conf > /etc/sysupgrade.conf.oxidnsplus.tmp && \
		mv /etc/sysupgrade.conf.oxidnsplus.tmp /etc/sysupgrade.conf
fi
logger -t oxidns-plus "prerm: prewarmer stopped and runtime state removed" 2>/dev/null || true
exit 0
endef

define Package/luci-app-oxidns-plus/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT:-}" ] && exit 0
rm -f /tmp/oxidnsplus.status.json /tmp/oxidnsplus.status.json.tmp 2>/dev/null || true
rm -rf /tmp/luci-modulecache/* 2>/dev/null || true
if [ -f /etc/sysupgrade.conf ]; then
	grep -vxE '/etc/config/oxidnsplus|/etc/oxidnsplus/watch.list' \
		/etc/sysupgrade.conf > /etc/sysupgrade.conf.tmprm && \
		mv /etc/sysupgrade.conf.tmprm /etc/sysupgrade.conf
fi
[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd restart >/dev/null 2>&1 || true
exit 0
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
	true
endef

define Package/luci-app-oxidns-plus/install
	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) $(CURDIR)/src/bin/$(PREWARMER_BIN) $(1)/usr/libexec/oxidns-prewarmer
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/oxidnsplus $(1)/etc/init.d/oxidnsplus
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/luci.oxidnsplus $(1)/usr/libexec/rpcd/luci.oxidnsplus
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DATA) ./root/etc/config/oxidnsplus $(1)/etc/config/oxidnsplus
	$(INSTALL_DIR) $(1)/etc/oxidnsplus
	$(INSTALL_DATA) ./root/etc/oxidnsplus/watch.list $(1)/etc/oxidnsplus/watch.list
	$(INSTALL_DIR) $(1)/usr/share/oxidnsplus
	$(INSTALL_DATA) ./root/usr/share/oxidnsplus/uci.defaults $(1)/usr/share/oxidnsplus/uci.defaults
	$(INSTALL_DATA) ./root/usr/share/oxidnsplus/watch.list.defaults $(1)/usr/share/oxidnsplus/watch.list.defaults
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json $(1)/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-oxidns-plus.json $(1)/usr/share/luci/menu.d/luci-app-oxidns-plus.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/oxidnsplus
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/oxidnsplus/plus.js $(1)/www/luci-static/resources/view/oxidnsplus/plus.js
endef

include $(TOPDIR)/feeds/luci/luci.mk

$(eval $(call BuildPackage,luci-app-oxidns-plus))
