#!/bin/sh
# Copyright (C) 2026 NetForgeCN - GPL-3.0-or-later
#
# OxiDNS Plus cache warmer.
#
# Sends real queries back into OxiDNS's own listener so the normal policy
# chain (cache -> routing -> upstream -> ttl) runs and the answer is cached
# in the usual way. Nothing here talks to an upstream directly.
#
# Triggered by:
#   1) /etc/init.d/oxidnsplus start (cold boot, immediate, background)
#   2) the crond block installed by that init script (default every 2 min)
#   3) LuCI "Warm now" / CLI: /etc/init.d/oxidnsplus warm
#
# Cron alone is not enough: a cron job waits one full interval before its
# first trigger, so a cold boot would still see a cold first visit.

uci_get() {
	if command -v uci >/dev/null 2>&1; then
		uci -q get "oxidnsplus.main.$1" 2>/dev/null || printf '%s' "$2"
	else
		printf '%s' "$2"
	fi
}

RESOLVER="$(uci_get resolver '127.0.0.1')"
PORT="$(uci_get resolver_port '5333')"
TYPES="$(uci_get warm_types 'A AAAA')"
DIG_TIMEOUT="$(uci_get dig_timeout '1')"
DIG_TRIES="$(uci_get dig_tries '1')"
SLEEP_BETWEEN="$(uci_get sleep_between '0')"
LIST="$(uci_get warm_list '/etc/oxidns/warm.list')"
WAIT_READY="$(uci_get warm_wait_ready '15')"

STATE_FILE="/tmp/oxidnsplus-warm.state"
LOCKDIR="/tmp/oxidnsplus-warm.lock"

log() {
	logger -t oxidns-plus "$1" 2>/dev/null || true
}

write_state() {
	# shellcheck disable=SC2039  # POSIX sh, no local
	_tmp="$STATE_FILE.tmp.$$"
	{
		printf 'last_run=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf unknown)"
		printf 'domains=%s\n' "${1:-0}"
		printf 'queries_ok=%s\n' "${2:-0}"
		printf 'queries_failed=%s\n' "${3:-0}"
		printf 'rc=%s\n' "${4:-1}"
		printf 'note=%s\n' "${5:--}"
	} > "$_tmp" && mv "$_tmp" "$STATE_FILE" || rm -f "$_tmp"
}

if ! command -v dig >/dev/null 2>&1; then
	log "warm: dig not found; install bind-dig"
	write_state 0 0 0 1 "dig_missing"
	echo "warm: 'dig' not found; install bind-dig" >&2
	exit 1
fi

if [ ! -f "$LIST" ]; then
	log "warm: list $LIST not found"
	write_state 0 0 0 1 "list_missing"
	echo "warm: list $LIST not found" >&2
	exit 1
fi

# Wait for the core to be up. Useful only for the cold-start invocation;
# on periodic runs this exits immediately.
if command -v pgrep >/dev/null 2>&1 && [ "$WAIT_READY" -gt 0 ] 2>/dev/null; then
	i=0
	while [ "$i" -lt "$WAIT_READY" ]; do
		if pgrep -x oxidns >/dev/null 2>&1; then
			break
		fi
		sleep 1
		i=$((i + 1))
	done
fi

# mkdir-as-lock: atomic, no PID races, works with busybox.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
	log "warm: another run is in progress, skipping"
	exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT INT TERM

ok=0
fail=0
domains=0

while IFS= read -r line || [ -n "$line" ]; do
	name=$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	case "$name" in
		''|\#*) continue ;;
	esac
	# Only accept a conservative hostname character set.
	case "$name" in
		*[!A-Za-z0-9._-]*) continue ;;
	esac
	domains=$((domains + 1))
	for type in $TYPES; do
		if dig "@$RESOLVER" -p "$PORT" "+time=$DIG_TIMEOUT" "+tries=$DIG_TRIES" \
				+short "$name" "$type" >/dev/null 2>&1; then
			ok=$((ok + 1))
		else
			fail=$((fail + 1))
		fi
		if [ "$SLEEP_BETWEEN" != "0" ]; then
			sleep "$SLEEP_BETWEEN"
		fi
	done
done < "$LIST"

if [ "$fail" -eq 0 ]; then
	rc=0
	note="ok"
else
	rc=1
	note="some_queries_failed"
fi

write_state "$domains" "$ok" "$fail" "$rc" "$note"
log "warm: domains=$domains ok=$ok failed=$fail"
echo "warm: domains=$domains queries_ok=$ok queries_failed=$fail"
exit "$rc"
