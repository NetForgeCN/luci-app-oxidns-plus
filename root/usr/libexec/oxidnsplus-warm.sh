#!/bin/sh
# Copyright (C) 2026 NetForgeCN - GPL-3.0-or-later
#
# OxiDNS Plus TTL-aware cache keeper.
#
# Instead of re-resolving the whole warm list on a fixed timer, this script
# remembers the TTL observed for every (domain, type) pair and only re-queries
# a pair shortly before its cached answer expires. crond only acts as a
# minute-resolution scheduler; the actual refresh decisions are per entry.
#
# The TTL comes from the DNS answer itself (dig +noall +answer, field 2).
# Because queries are sent to OxiDNS's own listener, a refresh runs through
# the normal policy chain and rewrites the cache entry with a fresh TTL.
#
# Triggered by:
#   1) /etc/init.d/oxidnsplus start (cold boot, immediate, background)
#   2) the crond block installed by that init script (default every 1 min)
#   3) LuCI "Warm now" / CLI: /etc/init.d/oxidnsplus warm  (--force)
#
# Uses --force to rebuild the TTL baseline from scratch. A baseline is also
# rebuilt automatically when the OxiDNS process set changes (core restart
# means the in-memory cache is gone) or when the state file is missing.

uci_get() {
	if command -v uci >/dev/null 2>&1; then
		uci -q get "oxidnsplus.main.$1" 2>/dev/null || printf '%s' "$2"
	else
		printf '%s' "$2"
	fi
}

num() {
	case "$1" in
		''|*[!0-9]*) printf '%s' "$2" ;;
		*) printf '%s' "$1" ;;
	esac
}

RESOLVER="$(uci_get resolver '127.0.0.1')"
PORT="$(num "$(uci_get resolver_port '5333')" 5333)"
TYPES="$(uci_get warm_types 'A AAAA')"
DIG_TIMEOUT="$(num "$(uci_get dig_timeout '1')" 1)"
DIG_TRIES="$(num "$(uci_get dig_tries '1')" 1)"
SLEEP_BETWEEN="$(uci_get sleep_between '0')"
LIST="$(uci_get warm_list '/etc/oxidns/warm.list')"
WAIT_READY="$(num "$(uci_get warm_wait_ready '15')" 15)"

POLL_MIN="$(num "$(uci_get warm_interval '1')" 1)"
MARGIN="$(num "$(uci_get warm_margin_percent '20')" 20)"
MIN_TTL="$(num "$(uci_get warm_min_ttl '30')" 30)"
MAX_TTL="$(num "$(uci_get warm_max_ttl '3600')" 3600)"
NOANSWER_TTL="$(num "$(uci_get warm_noanswer_ttl '300')" 300)"
RETRY_TTL="$(num "$(uci_get warm_retry_ttl '30')" 30)"

[ "$POLL_MIN" -ge 1 ] || POLL_MIN=1
[ "$MARGIN" -le 90 ] || MARGIN=90
[ "$MIN_TTL" -ge 1 ] || MIN_TTL=1
[ "$MAX_TTL" -ge "$MIN_TTL" ] || MAX_TTL="$MIN_TTL"
[ "$NOANSWER_TTL" -ge 1 ] || NOANSWER_TTL=1
[ "$RETRY_TTL" -ge 1 ] || RETRY_TTL=1
POLL=$((POLL_MIN * 60))

ENTRIES="/tmp/oxidnsplus-warm.entries"
STATE_FILE="/tmp/oxidnsplus-warm.state"
LOCKDIR="/tmp/oxidnsplus-warm.lock"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

log() {
	logger -t oxidns-plus "$1" 2>/dev/null || true
}

write_state() {
	# write_state <total> <due> <ok> <fail> <rebuilt> <rc> <note>
	_tmp="$STATE_FILE.tmp.$$"
	{
		printf 'last_run=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf unknown)"
		printf 'mode=ttl\n'
		printf 'core_sig=%s\n' "${CORE_SIG:-none}"
		printf 'poll_seconds=%s\n' "$POLL"
		printf 'total=%s\n' "${1:-0}"
		printf 'domains=%s\n' "${1:-0}"
		printf 'due=%s\n' "${2:-0}"
		printf 'skipped=%s\n' "$((${1:-0} - ${2:-0}))"
		printf 'queries_ok=%s\n' "${3:-0}"
		printf 'queries_failed=%s\n' "${4:-0}"
		printf 'rebuilt=%s\n' "${5:-0}"
		printf 'rc=%s\n' "${6:-1}"
		printf 'note=%s\n' "${7:--}"
	} > "$_tmp" && mv "$_tmp" "$STATE_FILE" || rm -f "$_tmp"
}

if ! command -v dig >/dev/null 2>&1; then
	log "warm: dig not found; install bind-dig"
	CORE_SIG="none"
	write_state 0 0 0 0 0 1 "dig_missing"
	echo "warm: 'dig' not found; install bind-dig" >&2
	exit 1
fi

if [ ! -f "$LIST" ]; then
	log "warm: list $LIST not found"
	CORE_SIG="none"
	write_state 0 0 0 0 0 1 "list_missing"
	echo "warm: list $LIST not found" >&2
	exit 1
fi

# Wait for the core to be up. Only useful on the cold-start invocation.
if [ "$WAIT_READY" -gt 0 ] 2>/dev/null; then
	i=0
	while [ "$i" -lt "$WAIT_READY" ]; do
		if command -v pgrep >/dev/null 2>&1 && pgrep -x oxidns >/dev/null 2>&1; then
			break
		fi
		sleep 1
		i=$((i + 1))
	done
fi

# Process-set signature: a core restart invalidates the whole in-memory cache.
CORE_SIG="none"
if command -v pgrep >/dev/null 2>&1; then
	_sig="$(pgrep -x oxidns 2>/dev/null | sort -n | tr '\n' ',')"
	[ -n "$_sig" ] && CORE_SIG="$_sig"
fi

if [ "$CORE_SIG" = "none" ]; then
	log "warm: OxiDNS core not running; skipping this pass"
	write_state 0 0 0 0 0 0 "core_not_running"
	echo "warm: OxiDNS core not running; skipping" >&2
	exit 0
fi

NOW="$(date +%s 2>/dev/null || printf 0)"
case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac

# mkdir-as-lock: atomic, no PID races, works with busybox. A stale lock left
# by a killed run must not disable warming forever, so recover after 300 s.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
	_ts="$(cat "$LOCKDIR/ts" 2>/dev/null || printf 0)"
	case "$_ts" in ''|*[!0-9]*) _ts=0 ;; esac
	if [ "$NOW" -gt 0 ] && [ $((NOW - _ts)) -gt 300 ]; then
		rm -rf "$LOCKDIR"
		mkdir "$LOCKDIR" 2>/dev/null || { log "warm: cannot recreate lock"; exit 0; }
	else
		log "warm: another run is in progress, skipping"
		exit 0
	fi
fi
printf '%s\n' "$NOW" > "$LOCKDIR/ts" 2>/dev/null || true

WORK="$(mktemp -d /tmp/oxidnsplus-warm.XXXXXX)" || {
	rm -rf "$LOCKDIR"
	log "warm: cannot create temp dir"
	exit 1
}
trap 'rm -rf "$WORK" "$LOCKDIR"' EXIT INT TERM

KEYS="$WORK/keys"
DUE="$WORK/due"
NEW="$WORK/new"
OLD="$WORK/old"
: > "$KEYS"
: > "$DUE"
: > "$NEW"
: > "$OLD"

# Build the set of (domain, type) keys from the warm list.
while IFS= read -r line || [ -n "$line" ]; do
	name=$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	case "$name" in
		''|\#*) continue ;;
	esac
	case "$name" in
		*[!A-Za-z0-9._-]*) continue ;;
	esac
	for type in $TYPES; do
		printf '%s|%s\n' "$name" "$type" >> "$KEYS"
	done
done < "$LIST"

# Decide whether the TTL baseline is still valid.
REBUILT=0
if [ "$FORCE" = "1" ] || [ ! -f "$ENTRIES" ]; then
	REBUILT=1
else
	_old_sig="$(awk -F= '$1 == "core_sig" { sub(/^[^=]*=/, ""); print; exit }' "$ENTRIES" 2>/dev/null)"
	if [ "$_old_sig" != "$CORE_SIG" ]; then
		REBUILT=1
	fi
fi

if [ "$REBUILT" = "0" ]; then
	awk -F'[|]' 'NF == 5 { print }' "$ENTRIES" > "$OLD" 2>/dev/null || : > "$OLD"
fi

# A key is due when its next refresh would fall inside the upcoming poll
# window (look-ahead), so minute-grained crond can never miss an expiry.
while IFS='|' read -r k t; do
	[ -n "$k" ] || continue
	rec="$(awk -F'[|]' -v k="$k" -v t="$t" '$1 == k && $2 == t { print $3 "|" $4; exit }' "$OLD")"
	if [ -z "$rec" ]; then
		printf '%s|%s\n' "$k" "$t" >> "$DUE"
		continue
	fi
	ttl="${rec%%|*}"
	last="${rec##*|}"
	case "$ttl" in ''|*[!0-9]*) ttl=0 ;; esac
	case "$last" in ''|*[!0-9]*) last=0 ;; esac
	if [ "$ttl" -le 0 ] || [ "$last" -le 0 ]; then
		printf '%s|%s\n' "$k" "$t" >> "$DUE"
		continue
	fi
	refresh=$(( ttl * (100 - MARGIN) / 100 ))
	[ "$refresh" -lt "$MIN_TTL" ] && refresh="$MIN_TTL"
	[ "$refresh" -gt "$MAX_TTL" ] && refresh="$MAX_TTL"
	[ "$refresh" -gt "$ttl" ] && refresh="$ttl"
	[ "$ttl" -lt "$MIN_TTL" ] && refresh="$ttl"
	if [ $((NOW + POLL)) -ge $((last + refresh)) ]; then
		printf '%s|%s\n' "$k" "$t" >> "$DUE"
	fi
done < "$KEYS"

# Query only what is due, and record the observed TTL.
ok=0
fail=0
while IFS='|' read -r k t; do
	[ -n "$k" ] || continue
	OUT="$(dig "@$RESOLVER" -p "$PORT" "+time=$DIG_TIMEOUT" "+tries=$DIG_TRIES" \
		+noall +answer "$k" "$t" 2>/dev/null)"
	RC=$?
	if [ "$RC" -ne 0 ]; then
		ttl="$RETRY_TTL"
		note="query_failed"
		fail=$((fail + 1))
	elif [ -z "$OUT" ]; then
		# NODATA / NXDOMAIN / black_hole: no answer section to read a TTL from.
		ttl="$NOANSWER_TTL"
		note="no_answer"
		ok=$((ok + 1))
	else
		ttl="$(printf '%s\n' "$OUT" | awk '
			$3 == "IN" && $2 ~ /^[0-9]+$/ {
				if (min == "" || $2 + 0 < min) min = $2 + 0
			}
			END { print min + 0 }')"
		case "$ttl" in ''|*[!0-9]*) ttl="$NOANSWER_TTL" ;; esac
		[ "$ttl" -gt 0 ] || ttl="$NOANSWER_TTL"
		[ "$ttl" -le "$MAX_TTL" ] || ttl="$MAX_TTL"
		note="ok"
		ok=$((ok + 1))
	fi
	printf '%s|%s|%s|%s|%s\n' "$k" "$t" "$ttl" "$NOW" "$note" >> "$NEW"
	if [ "$SLEEP_BETWEEN" != "0" ]; then
		sleep "$SLEEP_BETWEEN"
	fi
done < "$DUE"

# Merge: keep only keys still in the list; prefer fresh records, else old ones
# that were not due (a failed query must not erase a known-good TTL).
{
	printf 'core_sig=%s\n' "$CORE_SIG"
	awk -F'[|]' '
		FILENAME == ARGV[1] { keep[$1 "|" $2] = 1; next }
		FILENAME == ARGV[2] { due[$1 "|" $2]  = 1; next }
		FILENAME == ARGV[3] { old[$1 "|" $2]  = $0; next }
		FILENAME == ARGV[4] { new[$1 "|" $2]  = $0; next }
		END {
			for (k in keep) {
				if (k in new) print new[k]
				else if (!(k in due) && (k in old)) print old[k]
			}
		}
	' "$KEYS" "$DUE" "$OLD" "$NEW" | sort
} > "$ENTRIES.tmp" && mv "$ENTRIES.tmp" "$ENTRIES" || rm -f "$ENTRIES.tmp"

total="$(wc -l < "$KEYS" | tr -d ' ')"
due="$(wc -l < "$DUE" | tr -d ' ')"
case "$total" in ''|*[!0-9]*) total=0 ;; esac
case "$due" in ''|*[!0-9]*) due=0 ;; esac

if [ "$fail" -eq 0 ]; then rc=0; note="ok"; else rc=1; note="some_queries_failed"; fi
write_state "$total" "$due" "$ok" "$fail" "$REBUILT" "$rc" "$note"
log "warm: total=$total due=$due ok=$ok failed=$fail rebuilt=$REBUILT"
echo "warm: total=$total due=$due skipped=$((total - due)) ok=$ok failed=$fail rebuilt=$REBUILT"
exit "$rc"
