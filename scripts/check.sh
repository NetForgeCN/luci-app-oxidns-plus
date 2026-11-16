#!/bin/sh
# Copyright (C) 2026 NetForgeCN - GPL-3.0-or-later
#
# Static validation for the repository. Runs on a workstation; it does NOT
# build an OpenWrt package and does NOT need an OxiDNS binary.

set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
FAIL=0

ok()  { printf '  OK   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

printf '== shell syntax ==\n'
for f in \
	"$ROOT/root/etc/init.d/oxidnsplus" \
	"$ROOT/root/usr/libexec/rpcd/luci.oxidnsplus" \
	"$ROOT/root/usr/libexec/oxidnsplus-warm.sh" \
	"$ROOT/root/usr/libexec/oxidnsplus-dhcp-hosts.sh" \
	"$ROOT/root/usr/libexec/oxidnsplus-diagnose.sh" \
	"$ROOT/scripts/check.sh" ; do
	if sh -n "$f" 2>/dev/null; then
		ok "sh -n ${f#$ROOT/}"
	else
		bad "sh -n ${f#$ROOT/}"
	fi
done

printf '== JSON syntax ==\n'
for f in \
	"$ROOT/root/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json" \
	"$ROOT/root/usr/share/luci/menu.d/luci-app-oxidns-plus.json" ; do
	if python3 -m json.tool "$f" >/dev/null 2>&1; then
		ok "json ${f#$ROOT/}"
	else
		bad "json ${f#$ROOT/}"
	fi
done

printf '== JS syntax ==\n'
if command -v node >/dev/null 2>&1; then
	if node --check "$ROOT/htdocs/luci-static/resources/view/oxidnsplus/plus.js" >/dev/null 2>&1; then
		ok "node --check plus.js"
	else
		bad "node --check plus.js"
	fi
else
	printf '  SKIP node not available\n'
fi

printf '== hard rule: no main-config access ==\n'
python3 - "$ROOT" <<'PY'
import os, sys
root = sys.argv[1]
bad = False
code_files = [
    'root/usr/libexec/rpcd/luci.oxidnsplus',
    'root/usr/libexec/oxidnsplus-warm.sh',
    'root/usr/libexec/oxidnsplus-dhcp-hosts.sh',
    'root/usr/libexec/oxidnsplus-diagnose.sh',
    'root/etc/init.d/oxidnsplus',
    'root/etc/config/oxidnsplus',
    'htdocs/luci-static/resources/view/oxidnsplus/plus.js',
]
forbidden = ['apply_config_tuning', 'recommended_config', 'config_path',
             'config.recommended.yaml', 'lazy_cache_ttl', 'oxidns check -c']
for rel in code_files:
    text = open(os.path.join(root, rel), encoding='utf-8').read()
    for word in forbidden:
        if word in text:
            print('  FAIL %s still references %s' % (rel, word)); bad = True
if os.path.isfile(os.path.join(root, 'root/usr/share/oxidnsplus/config.recommended.yaml')):
    print('  FAIL config.recommended.yaml still shipped'); bad = True
# diagnose.sh in particular must not read the main config at all
diag = open(os.path.join(root, 'root/usr/libexec/oxidnsplus-diagnose.sh'), encoding='utf-8').read()
if 'config.yaml' in diag.replace('never reads /etc/oxidns/config.yaml', '') \
                       .replace('Edit /etc/oxidns/config.yaml yourself', ''):
    print('  FAIL diagnose.sh still reads config.yaml'); bad = True
if not bad:
    print('  OK   package never reads/writes /etc/oxidns/config.yaml')
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))

printf '== automated rollback ==\n'
python3 - "$ROOT" <<'PY'
import os, sys
root = sys.argv[1]
bad = False
mk = open(os.path.join(root, 'Makefile'), encoding='utf-8').read()
init = open(os.path.join(root, 'root/etc/init.d/oxidnsplus'), encoding='utf-8').read()
for needle, where in [
    ('define Package/luci-app-oxidns-plus/prerm', 'Makefile prerm'),
    ('define Package/luci-app-oxidns-plus/postrm', 'Makefile postrm'),
    ('sysupgrade.conf.oxidnsplus.tmp', 'prerm sysupgrade cleanup'),
    ('/etc/init.d/oxidnsplus cleanup', 'prerm cleanup call'),
]:
    if needle not in mk:
        print('  FAIL missing ' + where); bad = True
for needle in ['cleanup()', 'EXTRA_COMMANDS="warm sync cleanup"', 'HOSTS_STUB']:
    if needle not in init:
        print('  FAIL init.d missing ' + needle); bad = True
if not bad:
    print('  OK   prerm / postrm / cleanup present')
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))

printf '== defaults copies ==\n'
if cmp -s "$ROOT/root/etc/config/oxidnsplus" "$ROOT/root/usr/share/oxidnsplus/uci.defaults"; then
	ok "uci.defaults matches default UCI"
else
	bad "uci.defaults differs from default UCI"
fi
if cmp -s "$ROOT/root/etc/oxidns/warm.list" "$ROOT/root/usr/share/oxidnsplus/warm.list.defaults"; then
	ok "warm.list.defaults matches warm.list"
else
	bad "warm.list.defaults differs from warm.list"
fi

printf '== cross-file consistency ==\n'
python3 - "$ROOT" <<'PY'
import json, os, re, sys
root = sys.argv[1]
fail = False

def bad(msg):
    global fail
    print('  FAIL ' + msg); fail = True

def read(rel):
    return open(os.path.join(root, rel), encoding='utf-8').read()

rpcd = read('root/usr/libexec/rpcd/luci.oxidnsplus')
acl = json.loads(read('root/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json'))
menu = json.loads(read('root/usr/share/luci/menu.d/luci-app-oxidns-plus.json'))
uci = read('root/etc/config/oxidnsplus')
js = read('htdocs/luci-static/resources/view/oxidnsplus/plus.js')
mk = read('Makefile')
po = read('po/zh_Hans/oxidnsplus.po')

required = [
    'LICENSE', 'README.md', 'AGENTS.md', 'Makefile', '.gitignore',
    'root/etc/config/oxidnsplus',
    'root/etc/init.d/oxidnsplus',
    'root/etc/oxidns/warm.list',
    'root/usr/libexec/rpcd/luci.oxidnsplus',
    'root/usr/libexec/oxidnsplus-warm.sh',
    'root/usr/libexec/oxidnsplus-dhcp-hosts.sh',
    'root/usr/libexec/oxidnsplus-diagnose.sh',
    'root/usr/share/rpcd/acl.d/luci-app-oxidns-plus.json',
    'root/usr/share/luci/menu.d/luci-app-oxidns-plus.json',
    'root/usr/share/oxidnsplus/uci.defaults',
    'root/usr/share/oxidnsplus/warm.list.defaults',
    'htdocs/luci-static/resources/view/oxidnsplus/plus.js',
    'po/zh_Hans/oxidnsplus.po',
    'docs/FEATURES.md', 'docs/CONFIGURATION.md', 'docs/ROADMAP.md',
]
for rel in required:
    if not os.path.isfile(os.path.join(root, rel)):
        bad('missing file ' + rel)
if not fail:
    print('  OK   required file set')

# rpcd list / call / ACL method sets
m = re.search(r'\tlist\)\n(.*?)\n\t\t;;', rpcd, re.S)
list_methods = set(re.findall(r"printf '\"([a-z_]+)\"\s*:", m.group(1))) if m else set()
m = re.search(r'\tcall\)\n(.*?)\n\t\t;;', rpcd, re.S)
call_methods = set(re.findall(r'^\s+([a-z_]+)\)\s+emit_', m.group(1), re.M)) if m else set()
grp = acl.get('luci-app-oxidns-plus', {})
acl_methods = set(grp.get('read', {}).get('ubus', {}).get('luci.oxidnsplus', []) +
                  grp.get('write', {}).get('ubus', {}).get('luci.oxidnsplus', []))
if not list_methods or not call_methods or not acl_methods:
    bad('could not extract one of the method sets')
elif list_methods == call_methods == acl_methods:
    print('  OK   rpcd list/call/ACL methods aligned (%d)' % len(list_methods))
else:
    bad('method mismatch: list-only=%s call-only=%s acl-only=%s' % (
        sorted(list_methods - call_methods - acl_methods),
        sorted(call_methods - list_methods - acl_methods),
        sorted(acl_methods - list_methods - call_methods)))

# UCI options vs rpcd FIELDS vs JS FIELDS
uci_opts = set(re.findall(r'^\s*option\s+([a-z_]+)\s', uci, re.M))
m = re.search(r'^FIELDS="([^"]+)"', rpcd, re.M)
rpcd_fields = set(m.group(1).split()) if m else set()
m = re.search(r'var FIELDS = \[(.*?)\];', js, re.S)
js_fields = set(re.findall(r"'([a-z_]+)'", m.group(1))) if m else set()
if uci_opts == rpcd_fields == js_fields:
    print('  OK   UCI/rpcd/JS option sets aligned (%d)' % len(uci_opts))
else:
    bad('option mismatch: uci-only=%s rpcd-only=%s js-only=%s' % (
        sorted(uci_opts - rpcd_fields - js_fields),
        sorted(rpcd_fields - uci_opts - js_fields),
        sorted(js_fields - uci_opts - rpcd_fields)))

# settings_save signature must list exactly FIELDS
m = re.search(r'"settings_save":\{(.*?)\}', rpcd, re.S)
sig = set(re.findall(r'"([a-z_]+)":"string"', m.group(1))) if m else set()
if sig != uci_opts:
    bad('settings_save signature mismatch: %s' % sorted(sig ^ uci_opts))

# every UI _('...') string has a translation
used = set(re.findall(r"_\('([^']+)'\)", js))
known = set(re.findall(r'^msgid "(.*)"$', po, re.M))
missing = sorted(used - known)
if missing:
    bad('untranslated strings: %s' % missing)

# menu / ACL / view path / package name
acl_group = 'luci-app-oxidns-plus'
for node, spec in menu.items():
    deps = spec.get('depends', {}).get('acl', [])
    if deps != [acl_group]:
        bad('menu %s depends on %s, expected %s' % (node, deps, acl_group))
view_path = menu.get('admin/services/oxidnsplus/plus', {}).get('action', {}).get('path')
if view_path and not os.path.isfile(os.path.join(root, 'htdocs/luci-static/resources/view', view_path + '.js')):
    bad('menu view %s has no matching JS file' % view_path)
if 'PKG_NAME:=luci-app-oxidns-plus' not in mk:
    bad('Makefile package name mismatch')

# no namespace leakage into the base app
for rel, patterns in {
    'root/etc/config/oxidnsplus': [r'^\s*config\s+oxidns\b'],
    'root/usr/libexec/rpcd/luci.oxidnsplus': [r"object\s*[:=]\s*['\"]luci\.oxidns['\"]"],
}.items():
    text = read(rel)
    for pat in patterns:
        if re.search(pat, text, re.M):
            bad('base-app namespace leak in ' + rel)

if not fail:
    print('  OK   menu / ACL / view / i18n / namespace')
sys.exit(1 if fail else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))

printf '\n'
if [ "$FAIL" -eq 0 ]; then
	printf 'All checks passed.\n'
	exit 0
fi
printf '%s check(s) failed.\n' "$FAIL"
exit 1
