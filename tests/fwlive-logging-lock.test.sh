#!/usr/bin/env bash
# Concurrency test for the WAN logging lock (#151).
#
# Evidence that enable/disable_wan_logging no longer lose an update when two
# write-ACL callers race on the same zone:
#   A) A general read-modify-write (counter) canary proves the flock helper
#      itself serializes: WITHOUT the lock the counter loses updates, WITH
#      the lock it never does (the harness is sensitive to lost updates).
#   B) The REAL enable_wan_logging / disable_wan_logging functions, run
#      concurrently against a stubbed shared UCI store, always leave the
#      committed firewall.<zone>.log bit equal to SOME serial-execution
#      outcome (never a torn or stale value), and every invocation reports
#      well-formed ok/changed JSON (applied, no-op, or failed closed).
#
# BusyBox note: the production flock helper has no -w timeout, so the
# critical section stays short (read->compute->set->commit); the firewall
# reload runs outside the lock. Tests run hermetically by pointing
# FWLIVE_WAN_LOG_LOCK_FILE at a temp path (default is /var/lock/...).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGGING_SH="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh"
export FWLIVE_WAN_LOG_LOCK_FILE

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FWLIVE_WAN_LOG_LOCK_FILE="$WORK/fwlive-logging.lock"

die() { echo "fwlive-logging-lock test FAIL: $*" >&2; exit 1; }
ok() { echo "fwlive-logging-lock test OK: $*"; }

# --- Part A: canary read-modify-write counter (harness sensitivity) --------
# usage: $0 <logging-sh> <dir> <locked|unlocked>
cat > "$WORK/canary.sh" <<'EOF'
#!/bin/sh
. "$1"
dir="$2"
mode="$3"
if [ "$mode" = locked ]; then
	acquire_wan_log_lock || exit 3
fi
sleep 0.05
n=$(cat "$dir/counter" 2>/dev/null || printf '0')
sleep 0.20
n=$((n + 1))
printf '%s' "$n" > "$dir/counter"
if [ "$mode" = locked ]; then
	release_wan_log_lock
fi
EOF
chmod +x "$WORK/canary.sh"

run_counter() {
	mode="$1"
	dir="$WORK/counter-$mode"
	mkdir -p "$dir"
	printf '0' > "$dir/counter"
	for _ in 1 2; do
		sh "$WORK/canary.sh" "$LOGGING_SH" "$dir" "$mode" &
	done
	wait
	cat "$dir/counter"
}

counter_lost=0
for _ in 1 2 3 4 5; do
	final=$(run_counter unlocked)
	if [ "$final" -lt 2 ]; then
		counter_lost=$((counter_lost + 1))
	fi
done
[ "$counter_lost" -ge 1 ] \
	|| die "unlocked read-modify-write never lost an update (harness not sensitive)"
ok "unlocked read-modify-write loses updates ($counter_lost/5 rounds show lost update)"

for _ in 1 2 3 4 5; do
	final=$(run_counter locked)
	[ "$final" -eq 2 ] || die "locked counter final=$final expected 2 (lost update under flock)"
done
ok "flock-serialized read-modify-write never loses an update (5/5 rounds end at 2)"

# --- Part B: real functions, concurrent enable/disable on shared UCI -------
# usage: $0 <logging-sh> <dir> <enable|disable> <seed>
cat > "$WORK/child.sh" <<'EOF'
#!/bin/sh
. "$1"
dir="$2"
op="$3"
seed="$4"

COMMIT_FILE="$dir/log"
STAGED=''

json_escape() { cat; }
check_nf_log_ipv4() { return 0; }
check_nf_log_ipv6() { return 0; }
reload_firewall() { return 0; }
logger() { return 0; }

uci() {
	case "$1" in
		-q)
			case "$2" in
				show)
					printf "firewall.@zone[0].name='wan'\n"
					;;
				get)
					cat "$COMMIT_FILE" 2>/dev/null
					;;
			esac
			return 0
			;;
		set)
			STAGED="${2#*=}"
			sleep "0.0$((seed % 3 + 1))"
			;;
		delete)
			STAGED=''
			sleep "0.0$((seed % 3 + 1))"
			;;
		commit)
			sleep "0.0$((seed % 3 + 1))"
			if [ -n "$STAGED" ]; then
				printf '%s' "$STAGED" > "$COMMIT_FILE"
			else
				rm -f "$COMMIT_FILE"
			fi
			;;
	esac
	return 0
}

case "$op" in
	enable) enable_wan_logging ;;
	disable) disable_wan_logging ;;
esac
EOF
chmod +x "$WORK/child.sh"

# A final committed value is a valid serial outcome if some order of the two
# concurrent toggles (bit-0 set / bit-0 clear) could have produced it.
final_allowed() {
	init="$1"
	final="$2"
	if [ -z "$init" ]; then
		[ "$final" = 'empty' ] || [ "$final" = '1' ]
		return
	fi
	if [ "$final" = "$init" ] || [ "$final" = "$((init | 1))" ]; then
		return 0
	fi
	cleared=$((init & ~1))
	if [ "$cleared" -eq 0 ]; then
		[ "$final" = 'empty' ]
		return
	fi
	[ "$final" = "$cleared" ]
}

check_json() {
	case "$1" in
		'{"ok":true,'*|'{"ok":false,'*) return 0 ;;
		*) return 1 ;;
	esac
}

sweep_fail=0
failures="$WORK/failures"
: > "$failures"

trial_id=0
for init in '' 1 2 3; do
	for trial in 0 1 2 3 4 5 6 7; do
		trial_id=$((trial_id + 1))
		dir="$WORK/t$trial_id"
		mkdir -p "$dir"
		if [ -z "$init" ]; then
			rm -f "$dir/log"
		else
			printf '%s' "$init" > "$dir/log"
		fi
		if [ $((trial_id % 2)) -eq 0 ]; then
			op1=enable; op2=disable
		else
			op1=disable; op2=enable
		fi
		sh "$WORK/child.sh" "$LOGGING_SH" "$dir" "$op1" "$((trial_id * 7))" > "$dir/out1" 2>&1 &
		p1=$!
		sh "$WORK/child.sh" "$LOGGING_SH" "$dir" "$op2" "$((trial_id * 13 + 3))" > "$dir/out2" 2>&1 &
		p2=$!
		wait "$p1" || { sweep_fail=1; echo "child1 rc=$? init=$init trial=$trial" >> "$failures"; }
		wait "$p2" || { sweep_fail=1; echo "child2 rc=$? init=$init trial=$trial" >> "$failures"; }
		final=$(cat "$dir/log" 2>/dev/null || true)
		[ -n "$final" ] || final=empty
		if ! final_allowed "$init" "$final"; then
			sweep_fail=1
			echo "init=$init final=$final not a serial outcome" >> "$failures"
		fi
		out1=$(cat "$dir/out1")
		out2=$(cat "$dir/out2")
		check_json "$out1" || { sweep_fail=1; echo "child1 bad json init=$init: $out1" >> "$failures"; }
		check_json "$out2" || { sweep_fail=1; echo "child2 bad json init=$init: $out2" >> "$failures"; }
	done
done

if [ "$sweep_fail" -ne 0 ]; then
	cat "$failures" >&2
	die "concurrent sweep produced an inconsistent state or malformed JSON"
fi
ok "real enable/disable: 32 concurrent trials -> serial-consistent log bit, well-formed JSON"

# --- Part C: reload-failure conditional rollback (luna fold 2026-08-10) -----
# A failed reload must only roll back to the pre-commit value if the CURRENT
# value is still what THIS caller committed. If a concurrent toggle changed it
# after our commit, rollback must be SKIPPED (else the stale rollback clobbers
# the newer toggle).
# usage: $0 <logging-sh> <dir> <previous> <committed> -> writes the post-rollback value to stdout
cat > "$WORK/rollback-child.sh" <<'EOF'
#!/bin/sh
. "$1"
dir="$2"
previous="$3"
committed="$4"
COMMIT_FILE="$dir/log"
# uci stub (mirrors the child.sh one — keep it minimal for reload_and_report).
uci() {
	case "$1" in
		-q)
			case "$2" in
				show) printf "firewall.@zone[0].name='wan'\n" ;;
				get) cat "$COMMIT_FILE" 2>/dev/null ;;
			esac
			return 0
			;;
		set) STAGED="${2#*=}" ;;
		delete) STAGED='' ;;
		commit)
			if [ -n "$STAGED" ]; then
				printf '%s' "$STAGED" > "$COMMIT_FILE"
			else
				rm -f "$COMMIT_FILE"
			fi
			;;
	esac
	return 0
}
reload_firewall() { return 1; }   # reload ALWAYS fails in this part
logger() { return 0; }
# zone = wan (first zone section)
find_wan_zone_section() { printf 'wan'; }
wan_zone_log_value() { cat "$COMMIT_FILE" 2>/dev/null || true; }
zone_json='{"zone":"wan"}'
reload_and_report_wan_log wan "$previous" "$committed" fail-msg success-msg "$zone_json" >/dev/null 2>&1
cat "$COMMIT_FILE" 2>/dev/null || true
EOF
chmod +x "$WORK/rollback-child.sh"

# C1: current still == committed -> rollback restores the previous value.
mkdir -p "$WORK/rb1"
printf '1' > "$WORK/rb1/log"        # current value: 1 (what we committed)
out=$(sh "$WORK/rollback-child.sh" "$LOGGING_SH" "$WORK/rb1" "" "1")
[ -z "$out" ] || die "C1: expected rollback to restore previous (empty), got '$out'"
ok "reload failure + unchanged value -> rollback restores previous"

# C2: current != committed (concurrent toggle changed it) -> rollback SKIPPED.
mkdir -p "$WORK/rb2"
printf '2' > "$WORK/rb2/log"        # current value: 2 (NEWER commit by B)
out=$(sh "$WORK/rollback-child.sh" "$LOGGING_SH" "$WORK/rb2" "" "1")
[ "$out" = "2" ] || die "C2: expected rollback skipped (value stays 2), got '$out'"
ok "reload failure + concurrent change -> rollback skipped (newer toggle preserved)"

echo "fwlive-logging-lock tests passed"
