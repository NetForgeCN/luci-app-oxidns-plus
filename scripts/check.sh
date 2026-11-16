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

printf '== YAML sanity ==\n'
python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
p = os.path.join(root, 'root/usr/share/oxidnsplus/config.recommended.yaml')
text = open(p, encoding='utf-8').read()
bad = False
if '\t' in text:
    print('  FAIL recommended config contains tab characters'); bad = True
for key in ('runtime:', 'log:', 'api:', 'network:', 'plugins:'):
    if not re.search(r'^' + re.escape(key) + r'\s*$', text, re.M):
        print('  FAIL missing top-level key ' + key); bad = True
for tag in ('cache_main', 'edns_strip', 'hosts_system', 'seq_main', 'udp_lan'):
    if 'tag: ' + tag not in text:
        print('  FAIL missing plugin tag ' + tag); bad = True
if 'lazy_cache_ttl: 3600' not in text:
    print('  FAIL P1 not applied (lazy_cache_ttl != 3600)'); bad = True
if re.search(r'^\s*serve_stale_client_timeout_ms:', text, re.M):
    print('  FAIL F1 field is active but the official binary does not know it'); bad = True
if 'ecs_handler' in text and 'type: ecs_handler' in text:
    print('  FAIL ECS injection plugin present'); bad = True
if '/etc/oxidns/dhcp-hosts' not in text:
    print('  FAIL S2 hosts file not referenced'); bad = True
if not bad:
    print('  OK   recommended config sanity')
sys.exit(1 if bad else 0)
PY
[ $? -eq 0 ] || FAIL=$((FAIL + 1))

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

# required files
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
    'root/usr/share/oxidnsplus/config.recommended.yaml',
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
# Only the first "name": on each printf line is a method. Parameter names
# appear later on the same line and must not be counted as methods.
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
    print('  OK   menu / ACL / view / package namespace')
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
