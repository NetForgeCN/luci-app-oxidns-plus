#!/bin/sh
# Copyright (C) 2026 NetForgeCN - GPL-3.0-or-later
#
# Upstream latency snapshot. Read-only: never changes the configuration.
# Uses dig's own "Query time: N msec" line, so no high-resolution clock is
# needed (busybox date has no milliseconds).

uci_get() {
	if command -v uci >/dev/null 2>&1; then
		uci -q get "oxidnsplus.main.$1" 2>/dev/null || printf '%s' "$2"
	else
		printf '%s' "$2"
	fi
}

RESOLVER="$(uci_get resolver '127.0.0.1')"
PORT="$(uci_get resolver_port '5333')"
CONFIG_PATH="$(uci_get config_path '/etc/oxidns/config.yaml')"
STATE_FILE="/tmp/oxidnsplus-diagnose.state"

probe() {
	# probe <server> <port> <label> -> prints "label|best_ms|samples"
	_server="$1"
	_port="$2"
	_label="$3"
	best=""
	samples=""
	n=0
	while [ "$n" -lt 3 ]; do
		ms=$(dig "@$_server" -p "$_port" +time=2 +tries=1 www.baidu.com A 2>/dev/null \
			| awk '/Query time:/ { print $4; exit }')
		case "$ms" in
			''|*[!0-9]*) ms="timeout" ;;
		esac
		if [ "$ms" != "timeout" ]; then
			if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then
				best="$ms"
			fi
			samples="${samples}${ms} "
		else
			samples="${samples}timeout "
		fi
		n=$((n + 1))
	done
	printf '%s|%s|%s\n' "$_label" "${best:-timeout}" "${samples% }"
}

config_health() {
	if [ ! -r "$CONFIG_PATH" ]; then
		printf 'config=missing\n'
		return
	fi
	lazy=$(awk '/^[[:space:]]*lazy_cache_ttl:/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "$CONFIG_PATH")
	printf 'lazy_cache_ttl=%s\n' "${lazy:-unset}"
	if grep -qE 'ecs_handler|client_ip_from_ecs' "$CONFIG_PATH"; then
		printf 'ecs=injection_detected\n'
	elif grep -q 'edns_filter' "$CONFIG_PATH"; then
		printf 'ecs=stripped\n'
	else
		printf 'ecs=unknown\n'
	fi
	if grep -q '/etc/oxidns/dhcp-hosts' "$CONFIG_PATH"; then
		printf 'dhcp_hosts=referenced\n'
	else
		printf 'dhcp_hosts=not_referenced\n'
	fi
	if grep -qE 'client_ip|guest' "$CONFIG_PATH"; then
		printf 'guest=detected\n'
	else
		printf 'guest=none\n'
	fi
}

if ! command -v dig >/dev/null 2>&1; then
	echo "dig (bind-dig) is required for diagnostics" >&2
	exit 1
fi

printf 'OxiDNS Plus diagnostics - %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf unknown)"
printf '\n== Config health ==\n'
config_health
printf '\n== Local resolver (full policy chain, cache hits included) ==\n'
probe "$RESOLVER" "$PORT" "local:$PORT"
printf '\n== Direct UDP upstreams (relative comparison only) ==\n'
probe "223.5.5.5" 53 "alidns-udp"
probe "119.29.29.29" 53 "dnspod-udp"
probe "1.1.1.1" 53 "cloudflare-udp"
probe "8.8.8.8" 53 "google-udp"
probe "9.9.9.9" 53 "quad9-udp"
printf '\nNote: the running config uses DoH/DoT for most upstreams. Direct UDP\n'
printf 'numbers are only a rough link-quality comparison, not the real path.\n'
printf 'For blocked or intercepted targets, "timeout" is expected.\n'

{
	printf 'last_run=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf unknown)"
	printf 'rc=0\n'
} > "$STATE_FILE.tmp.$$" && mv "$STATE_FILE.tmp.$$" "$STATE_FILE" || rm -f "$STATE_FILE.tmp.$$"
