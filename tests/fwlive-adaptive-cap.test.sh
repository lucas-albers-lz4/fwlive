#!/usr/bin/env bash
# Unit tests for fwlive-adaptive-cap.sh (#306 Layer 1).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTIVE_SH="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-adaptive-cap.sh"
RPCD="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive"

die() { echo "fwlive-adaptive-cap test FAIL: $*" >&2; exit 1; }
ok() { echo "fwlive-adaptive-cap test OK: $*"; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
export FWLIVE_ADAPTIVE_STATE_FILE="$WORKDIR/state.json"
export FWLIVE_ADAPTIVE_OFF_FILE="$WORKDIR/adaptive-off"
export POLL_LINES_MAX=2000
unset FWLIVE_ADAPTIVE
rm -f "$FWLIVE_ADAPTIVE_STATE_FILE" "$FWLIVE_ADAPTIVE_OFF_FILE"

# shellcheck disable=SC1090
. "$ADAPTIVE_SH"

[ "$(fwlive_adaptive_bucket_for_ms 0)" = cold ] || die "0 → cold"
[ "$(fwlive_adaptive_bucket_for_ms 99)" = cold ] || die "99 → cold"
[ "$(fwlive_adaptive_bucket_for_ms 100)" = cool ] || die "100 → cool"
[ "$(fwlive_adaptive_bucket_for_ms 199)" = cool ] || die "199 → cool"
[ "$(fwlive_adaptive_bucket_for_ms 200)" = warm ] || die "200 → warm"
[ "$(fwlive_adaptive_bucket_for_ms 800)" = warm ] || die "800 → warm"
[ "$(fwlive_adaptive_bucket_for_ms 801)" = hot ] || die "801 → hot"
ok "bucket thresholds"

# Cold start: plan serves full request.
set -- $(fwlive_adaptive_plan 500)
[ "$1" = 500 ] || die "cold plan lines=$1 want 500"
[ "$2" = 0 ] || die "cold plan shed=$2"
ok "cold plan serves request"

# Record cool duration → next plan caps at 250.
fwlive_adaptive_record 150 500
set -- $(fwlive_adaptive_plan 2000)
[ "$1" = 250 ] || die "after cool, plan limit=$1 want 250"
ok "cool caps at 250"

# Duration ≠ inter-arrival: a long gap must not look hot.
# State still holds last duration 150 (cool), not wall gap.
sleep 1
set -- $(fwlive_adaptive_plan 2000)
[ "$1" = 250 ] || die "after sleep gap, still cool-based limit=$1"
[ "$(fwlive_adaptive_bucket_for_ms "$(fwlive_adaptive_read_state | awk '{print $1}')")" = cool ] \
	|| die "state duration must stay cool after gap"
ok "plan uses processing duration not inter-arrival"

# A full-sized cold sample probes upward one step at a time instead of
# jumping from the cool cap straight to POLL_LINES_MAX.
fwlive_adaptive_record 40 250
set -- $(fwlive_adaptive_read_state)
[ "$2" = 500 ] && [ "$3" = cold ] || die "first cold probe state=$*"
set -- $(fwlive_adaptive_plan 2000)
[ "$1" = 500 ] || die "cold probe must hold retained limit=$1 want 500"
fwlive_adaptive_record 40 500
set -- $(fwlive_adaptive_plan 2000)
[ "$1" = 1000 ] || die "second cold probe=$1 want 1000"
fwlive_adaptive_record 40 1000
set -- $(fwlive_adaptive_plan 2000)
[ "$1" = 2000 ] || die "third cold probe=$1 want 2000"
ok "cold recovery probes upward without oscillation"

# Warm: first warm halves; second consecutive warm holds.
fwlive_adaptive_write_state 0 2000 cold 0 0 0
fwlive_adaptive_record 400 2000
set -- $(fwlive_adaptive_read_state)
[ "$3" = warm ] || die "record warm bucket=$3"
[ "$2" = 1000 ] || die "first warm half limit=$2 want 1000"
[ "$4" = 1 ] || die "warm_halved=$4"
set -- $(fwlive_adaptive_plan 2000)
# Still in warm cooldown holding halved limit from state.
[ "$1" = 1000 ] || die "plan after warm half=$1 want 1000"
fwlive_adaptive_record 400 1000
set -- $(fwlive_adaptive_read_state)
[ "$2" = 1000 ] || die "second warm must hold=$2 want 1000"
ok "warm halves once then holds"

# Hot: floor 250 + shed; resolve gate.
fwlive_adaptive_write_state 0 2000 cold 0 0 0
fwlive_adaptive_record 900 2000
set -- $(fwlive_adaptive_read_state)
[ "$3" = hot ] || die "hot bucket=$3"
[ "$5" = 1 ] || die "shed bit=$5"
fwlive_adaptive_is_hot || die "is_hot after hot record"
set -- $(fwlive_adaptive_plan 2000)
[ "$1" = 250 ] || die "hot plan floor=$1"
[ "$2" = 1 ] || die "hot plan shed=$2"
# Cap rule: never raise a small request.
set -- $(fwlive_adaptive_plan 50)
[ "$1" = 50 ] || die "hot floor must not raise 50 → got $1"
ok "hot floor + shed + min(request)"

# Cooldown expiry: use a deterministic clock after sourcing so the probe
# vector controls the helper's clock seam rather than /proc/uptime.
(
	FWLIVE_ADAPTIVE_STATE_FILE="$WORKDIR/probe-state.json"
	FWLIVE_ADAPTIVE_OFF_FILE="$WORKDIR/probe-off"
	export FWLIVE_ADAPTIVE_STATE_FILE FWLIVE_ADAPTIVE_OFF_FILE
	. "$ADAPTIVE_SH"
	_probe_cs=1600
	fwlive_adaptive_clock_cs() { printf '%s\n' "$_probe_cs"; }

	# Expired hot cooldown probes upward from the 250-line floor.
	fwlive_adaptive_write_state 900 250 hot 0 1 1000
	set -- $(fwlive_adaptive_plan 2000)
	[ "$1" = 500 ] || die "expired hot cooldown probe=$1 want 500"

	# A still-hot probe falls back to the floor.
	_probe_cs=1601
	fwlive_adaptive_record 900 500
	set -- $(fwlive_adaptive_read_state)
	[ "$2" = 250 ] && [ "$3" = hot ] || die "hot probe recovery state=$*"

	# A healthy probe retains the raised limit for the short probe window.
	fwlive_adaptive_write_state 900 250 hot 0 1 1000
	_probe_cs=1600
	set -- $(fwlive_adaptive_plan 2000)
	[ "$1" = 500 ] || die "healthy probe setup=$1 want 500"
	_probe_cs=1601
	fwlive_adaptive_record 150 500
	set -- $(fwlive_adaptive_read_state)
	[ "$2" = 500 ] && [ "$3" = cool ] || die "healthy probe state=$*"
	set -- $(fwlive_adaptive_plan 2000)
	[ "$1" = 500 ] || die "healthy probe retained limit=$1 want 500"

	# Warm cooldown also doubles its previous limit once the window expires.
	fwlive_adaptive_write_state 400 1000 warm 1 0 1000
	_probe_cs=1300
	set -- $(fwlive_adaptive_plan 2000)
	[ "$1" = 2000 ] || die "expired warm cooldown probe=$1 want 2000"
)
ok "cooldown expiry probes upward and recovers"

# Cap rule on cool: request 50 stays 50.
fwlive_adaptive_write_state 150 250 cool 0 0 "$(fwlive_adaptive_clock_cs)"
set -- $(fwlive_adaptive_plan 50)
[ "$1" = 50 ] || die "cool must not raise 50 → $1"
ok "cool respects small request"

# Override: env and sentinel.
FWLIVE_ADAPTIVE=0
fwlive_adaptive_enabled && die "FWLIVE_ADAPTIVE=0 must disable"
set -- $(fwlive_adaptive_plan 2000)
[ "$1" = 2000 ] && [ "$2" = 0 ] && [ "$3" = off ] || die "disabled plan=$1 $2 $3"
unset FWLIVE_ADAPTIVE
: >"$FWLIVE_ADAPTIVE_OFF_FILE"
fwlive_adaptive_enabled && die "sentinel must disable"
rm -f "$FWLIVE_ADAPTIVE_OFF_FILE"
fwlive_adaptive_enabled || die "enabled again after sentinel remove"
# Default off path is under the state dir (not world-writable /tmp) when OFF unset.
_saved_off=$FWLIVE_ADAPTIVE_OFF_FILE
unset FWLIVE_ADAPTIVE_OFF_FILE
_saved_state=$FWLIVE_ADAPTIVE_STATE_FILE
FWLIVE_ADAPTIVE_STATE_FILE=/var/run/fwlive-state.json
_def_off=$(fwlive_adaptive_off_path)
[ "$_def_off" = /var/run/fwlive-adaptive-off ] || \
	die "production default off path want /var/run/fwlive-adaptive-off got: $_def_off"
FWLIVE_ADAPTIVE_STATE_FILE=$_saved_state
export FWLIVE_ADAPTIVE_OFF_FILE="$_saved_off"
ok "test/triage overrides"

# Fail-open: corrupt state → defaults, no abort.
printf 'not-json\n' >"$FWLIVE_ADAPTIVE_STATE_FILE"
set -- $(fwlive_adaptive_read_state)
[ "$1" = 0 ] && [ "$3" = cold ] || die "corrupt state defaults got: $*"
ok "corrupt state fail-open"

# Q1: without a success record, prior hot/shed must persist (failed ubus ≠ cold).
fwlive_adaptive_write_state 900 250 hot 0 1 "$(fwlive_adaptive_clock_cs)"
fwlive_adaptive_is_hot || die "hot must persist without a success record"
set -- $(fwlive_adaptive_plan 2000)
[ "$1" = 250 ] || die "hot floor must persist without record, got $1"
[ "$2" = 1 ] || die "shed must persist without record, got $2"
if grep -n 'log_read_failed' -A6 "$RPCD" | grep -q 'fwlive_adaptive_record'; then
	die "log_read_failed path must not call fwlive_adaptive_record"
fi
ok "failed-read keeps prior bucket (no record)"

# Unusable lock file: fail-closed (skip the write). Missing flock and a busy
# lock stay fail-open.
_saved_lock=${FWLIVE_ADAPTIVE_LOCK_FILE:-}
_restore_lock() {
	if [ -n "${_saved_lock:-}" ]; then
		export FWLIVE_ADAPTIVE_LOCK_FILE="$_saved_lock"
	else
		unset FWLIVE_ADAPTIVE_LOCK_FILE
	fi
}
_expect_lock_skipped() {
	_why=$1
	set -- $(fwlive_adaptive_read_state)
	[ "$3" = cold ] || die "$_why: bucket=$3 want cold"
	[ "$2" = 2000 ] || die "$_why: limit=$2 want 2000"
}
_seed_cold() {
	fwlive_adaptive_write_state 0 2000 cold 0 0 0
}

_seed_cold
_lock_dir="$WORKDIR/lock-as-dir"
mkdir -p "$_lock_dir"
export FWLIVE_ADAPTIVE_LOCK_FILE="$_lock_dir"
fwlive_adaptive_record 900 2000
_expect_lock_skipped "directory lock"
_restore_lock
ok "directory lock path skips write"

_seed_cold
_lock_link_tgt="$WORKDIR/lock-link-target"
: >"$_lock_link_tgt"
ln -s "$_lock_link_tgt" "$WORKDIR/lock-symlink"
export FWLIVE_ADAPTIVE_LOCK_FILE="$WORKDIR/lock-symlink"
fwlive_adaptive_record 900 2000
_expect_lock_skipped "symlink lock"
_restore_lock
ok "symlink lock path skips write"

_seed_cold
_lock_fifo="$WORKDIR/lock.fifo"
mkfifo "$_lock_fifo"
[ -w "$_lock_fifo" ] || die "fifo fixture must be -w so only the regular-file check rejects it"
# A writable FIFO would block the fd-9 open waiting for a reader; bound it.
timeout 5 env FWLIVE_ADAPTIVE_LOCK_FILE="$_lock_fifo" bash -c \
	'. "$1"; fwlive_adaptive_record 900 2000' sh "$ADAPTIVE_SH" \
	|| die "fifo lock must not hang or fail the record"
_expect_lock_skipped "fifo lock"
ok "fifo lock path skips write without blocking"

_seed_cold
_missing_lock_parent="$WORKDIR/lock-missing-parent"
[ ! -e "$_missing_lock_parent" ] || die "lock-create fixture parent must not exist"
export FWLIVE_ADAPTIVE_LOCK_FILE="$_missing_lock_parent/lock"
fwlive_adaptive_record 900 2000
_expect_lock_skipped "lock create failure"
[ ! -e "$_missing_lock_parent" ] || die "lock create failure must not create its missing parent"
_restore_lock
ok "missing lock parent skips write for any uid"

if [ "$(id -u)" -eq 0 ]; then
	echo "skip: unwritable lock mode fixture (root bypasses permission bits; non-root run covers it)"
else
	_seed_cold
	_nw_lock="$WORKDIR/lock-unwritable"
	: >"$_nw_lock"
	chmod 444 "$_nw_lock"
	export FWLIVE_ADAPTIVE_LOCK_FILE="$_nw_lock"
	[ -w "$_nw_lock" ] && die "unwritable lock fixture must not be -w"
	fwlive_adaptive_record 900 2000
	_expect_lock_skipped "unwritable lock"
	_restore_lock
	ok "unwritable lock skips write"
fi

_seed_cold
_nf_bin="$WORKDIR/path-no-flock"
mkdir -p "$_nf_bin"
for _c in find mv rm; do
	ln -s "$(command -v "$_c")" "$_nf_bin/$_c"
done
PATH="$_nf_bin" command -v flock >/dev/null 2>&1 && die "stub PATH must hide flock"
PATH="$_nf_bin" fwlive_adaptive_record 900 2000
set -- $(fwlive_adaptive_read_state)
[ "$3" = hot ] || die "missing flock must fail-open, bucket=$3"
ok "missing flock fail-opens record"

_seed_cold
_busy_lock="$(fwlive_adaptive_lock_path)"
: >"$_busy_lock"
_busy_held="$WORKDIR/lock-held"
_busy_done="$WORKDIR/lock-done"
rm -f "$_busy_held" "$_busy_done"
(
	flock 9 || exit 1
	echo held >"$_busy_held"
	while [ ! -f "$_busy_done" ]; do
		sleep 0.05
	done
) 9>>"$_busy_lock" &
_busy_pid=$!
_busy_i=0
while [ ! -f "$_busy_held" ]; do
	_busy_i=$((_busy_i + 1))
	[ "$_busy_i" -gt 100 ] && die "busy-lock holder did not start"
	sleep 0.05
done
fwlive_adaptive_record 900 2000
echo done >"$_busy_done"
wait "$_busy_pid" || die "busy-lock holder failed"
set -- $(fwlive_adaptive_read_state)
[ "$3" = hot ] || die "busy lock must fail-open, bucket=$3"
ok "busy lock fail-opens record"

# Non-regular lock (unix socket: not a dir/symlink, and >> would fail) → skip write.
# Do not use ulimit -n: bash vs ash abort is environment-dependent (#619).
fwlive_adaptive_write_state 0 2000 cold 0 0 0
_sock="$WORKDIR/lock.sock"
rm -f "$_sock"
command -v python3 >/dev/null 2>&1 || die "python3 required for unopenable lock fixture"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$_sock" \
	|| die "could not create unix socket lock fixture"
[ -L "$_sock" ] && die "socket fixture must not be a symlink"
[ -d "$_sock" ] && die "socket fixture must not be a directory"
[ -w "$_sock" ] || die "socket fixture must be -w so the fd-9 probe runs"
( exec 9>>"$_sock" ) 2>/dev/null && die "socket fixture must be unopenable for append"
_saved_lock=${FWLIVE_ADAPTIVE_LOCK_FILE:-}
export FWLIVE_ADAPTIVE_LOCK_FILE="$_sock"
fwlive_adaptive_record 900 2000
set -- $(fwlive_adaptive_read_state)
[ "$3" = cold ] || die "unopenable lock must skip write, bucket=$3 want cold"
[ "$2" = 2000 ] || die "unopenable lock must not record unlocked, limit=$2"
if [ -n "$_saved_lock" ]; then
	export FWLIVE_ADAPTIVE_LOCK_FILE="$_saved_lock"
else
	unset FWLIVE_ADAPTIVE_LOCK_FILE
fi
ok "unopenable lock skips write"

# merge_reply shape
got=$(fwlive_adaptive_merge_reply '{}' 0 50 0 0)
[ "$got" = '{"adaptive":1,"messages_received":0,"truncated":0}' ] || \
	die "empty object merge must remain valid JSON: $got"
got=$(fwlive_adaptive_merge_reply '{"log":[]}' 0 50 0 0)
case "$got" in
	*'\"adaptive\":1'*|*',"adaptive":1,'*) ;;
	*) die "merge missing adaptive: $got" ;;
esac
got=$(fwlive_adaptive_merge_reply '{"log":[]}' 1 250 1 3)
case "$got" in
	*'"shed":{"level":"hot","limit":250}'*) ;;
	*) die "merge missing shed: $got" ;;
esac
got=$(fwlive_adaptive_merge_reply '{"log":[]}' 1 250 1 3 1)
case "$got" in
	*'"effective_limit":250'*) ;;
	*) die "successful adaptive merge missing effective_limit: $got" ;;
esac
got=$(fwlive_adaptive_merge_reply '{"log":[]}' 1 250 1 3 0)
case "$got" in
	*'"effective_limit":'*) die "error adaptive merge must omit effective_limit: $got" ;;
	*) ;;
esac
got=$(fwlive_adaptive_merge_reply '{"log":[],"messages_received":7}' 0 50 0 0)
case "$got" in
	*'"messages_received":7'*'"adaptive":1'*) ;;
	*) die "merge must preserve filter count: $got" ;;
esac
[ "$(printf '%s' "$got" | awk -F 'messages_received' '{print NF - 1}')" = 1 ] || \
	die "merge must not duplicate messages_received: $got"
ok "merge preserves filter count"
# Truncated bodies that still end in `}` must not be spliced into invalid JSON.
got=$(fwlive_adaptive_merge_reply '{"log":[{"msg":"a"}' 0 50 0 0 0)
[ "$got" = '{"log":[{"msg":"a"}' ] || die "truncated object must pass through unspliced: $got"
got=$(fwlive_adaptive_merge_reply '{"log":[{"msg":"a"},{"msg":"b"}' 0 50 0 0 0)
[ "$got" = '{"log":[{"msg":"a"},{"msg":"b"}' ] || die "truncated array must pass through unspliced: $got"
got=$(fwlive_adaptive_merge_reply '{"log":[{"msg":"]"}' 0 50 0 0 0)
[ "$got" = '{"log":[{"msg":"]"}' ] || die "truncated body with ] in a string must pass through: $got"
got=$(fwlive_adaptive_merge_reply '{"log":[' 0 50 0 0 0)
[ "$got" = '{"log":[' ] || die "unclosed array must pass through: $got"
got=$(fwlive_adaptive_merge_reply '{"log":[],"error":"filter_failed"}' 0 50 0 0 0)
case "$got" in
	*'{"log":[],"error":"filter_failed"'*) ;;
	*) die "complete error object must still merge: $got" ;;
esac
printf '%s' "$got" | python3 -c 'import json,sys; json.load(sys.stdin)' || \
	die "merged error object must be valid JSON: $got"
_merge_exact() {
	_why=$1
	_want=$2
	shift 2
	_got=$(fwlive_adaptive_merge_reply "$@")
	[ "$_got" = "$_want" ] || die "$_why: got $_got want $_want"
}
_merge_exact "empty success" \
	'{"adaptive":1,"messages_received":0,"effective_limit":50,"truncated":0}' \
	'{}' 0 50 0 0 1
_merge_exact "log shed" \
	'{"log":[],"adaptive":1,"messages_received":3,"truncated":1,"shed":{"level":"hot","limit":250}}' \
	'{"log":[]}' 1 250 1 3 0
_merge_exact "log shed success" \
	'{"log":[],"adaptive":1,"messages_received":3,"effective_limit":250,"truncated":1,"shed":{"level":"hot","limit":250}}' \
	'{"log":[]}' 1 250 1 3 1
_merge_exact "preserve count shed" \
	'{"log":[],"messages_received":7,"adaptive":1,"effective_limit":50,"truncated":1,"shed":{"level":"hot","limit":50}}' \
	'{"log":[],"messages_received":7}' 1 50 1 9 1
FWLIVE_ADAPTIVE=0
_merge_exact "adaptive off empty" \
	'{"adaptive":0,"messages_received":0}' \
	'{}' 0 50 0 0 1
_merge_exact "adaptive off log" \
	'{"log":[],"adaptive":0,"messages_received":3}' \
	'{"log":[]}' 1 250 1 3
_merge_exact "adaptive off preserve count" \
	'{"log":[],"messages_received":7,"adaptive":0}' \
	'{"log":[],"messages_received":7}' 1 250 1 3 1
unset FWLIVE_ADAPTIVE
ok "merge_reply"

# Lock file mode 0600 on create (Grok #329 P2 / logging.lock #167).
rm -f "$(fwlive_adaptive_lock_path)"
(
	umask 022
	fwlive_adaptive_record 50 50
)
_lock=$(fwlive_adaptive_lock_path)
_mode=$(stat -c '%a' "$_lock" 2>/dev/null || stat -f '%OLp' "$_lock")
case "$_mode" in
	600|0600) ;;
	*) die "lock mode want 0600 got $_mode" ;;
esac
ok "lock created 0600 under umask 022"

# State writes must not change the caller's process umask (issue #505).
rm -f "$FWLIVE_ADAPTIVE_STATE_FILE"
_caller_umask=$(umask)
umask 022
fwlive_adaptive_write_state 900 250 hot 0 1 1000
_after_write_umask=$(umask)
[ "$_after_write_umask" = 0022 ] || die "state write changed umask: $_after_write_umask"
_state_mode=$(stat -c '%a' "$FWLIVE_ADAPTIVE_STATE_FILE" 2>/dev/null || stat -f '%OLp' "$FWLIVE_ADAPTIVE_STATE_FILE")
case "$_state_mode" in
	600|0600) ;;
	*) die "state mode want 0600 got $_state_mode" ;;
esac
umask "$_caller_umask"
ok "state write scopes umask"

# oneshot dropped from production poll path
if grep -E 'oneshot[[:space:]]*:[[:space:]]*true' "$RPCD" >/dev/null; then
	die "rpcd poll must not send oneshot:true"
fi
ok "oneshot absent from rpcd"

# Resolve load-shed via sourced helpers + stub state
fwlive_adaptive_write_state 900 250 hot 0 1 "$(fwlive_adaptive_clock_cs)"
fwlive_adaptive_is_hot || die "hot state for resolve gate"
ok "resolve hot gate helper"

# Sibling lock survives atomic state rename (Luna P1).
rm -f "$FWLIVE_ADAPTIVE_STATE_FILE" "$(fwlive_adaptive_lock_path)"
fwlive_adaptive_record 900 2000
_lock=$(fwlive_adaptive_lock_path)
[ -f "$_lock" ] || die "expected sibling lock file at $_lock"
_inode_before=$(stat -c '%i' "$_lock" 2>/dev/null || stat -f '%i' "$_lock")
fwlive_adaptive_record 150 250
_inode_after=$(stat -c '%i' "$_lock" 2>/dev/null || stat -f '%i' "$_lock")
[ "$_inode_before" = "$_inode_after" ] || die "lock inode changed across state mv ($_inode_before → $_inode_after)"
# Holding the sibling lock must make a peer flock -n fail, even after state mv.
# Peer uses file-path form (`flock -n "$lock" -c …`). A bare `flock -n 8 true`
# locks a *file named "8"*, not fd 8, under util-linux.
(
	flock 9 || exit 1
	fwlive_adaptive_write_state 900 250 hot 0 1 "$(fwlive_adaptive_clock_cs)"
	if flock -n "$_lock" -c 'true' 2>/dev/null; then
		echo "peer acquired lock during hold" >&2
		exit 1
	fi
) 9>>"$_lock" || die "sibling lock did not stay exclusive across state rename"
ok "sibling lock survives state rename"

# Concurrent writers: final state remains one-line valid JSON (no hang/corrupt).
rm -f "$FWLIVE_ADAPTIVE_STATE_FILE"
fwlive_adaptive_write_state 0 2000 cold 0 0 0
_pids=
for _i in 1 2 3 4 5 6 7 8; do
	(
		# shellcheck disable=SC1090
		. "$ADAPTIVE_SH"
		fwlive_adaptive_record 900 2000
	) &
	_pids="$_pids $!"
done
for _p in $_pids; do
	wait "$_p" || die "concurrent record pid $_p failed"
done
_raw=
IFS= read -r _raw <"$FWLIVE_ADAPTIVE_STATE_FILE" || true
case "$_raw" in
	'{"duration_ms":'*) ;;
	*) die "concurrent writers left corrupt state: $_raw" ;;
esac
# Must still parse via the helper.
set -- $(fwlive_adaptive_read_state)
case "$3" in
	hot|cool|warm|cold) ;;
	*) die "concurrent final bucket invalid: $3" ;;
esac
ok "concurrent writers converge to valid state"

_ww=$(mktemp -d)
chmod 0777 "$_ww"
_saved_state=$FWLIVE_ADAPTIVE_STATE_FILE
FWLIVE_ADAPTIVE_STATE_FILE="$_ww/state.json"
fwlive_adaptive_state_dir_ok && die "world-writable adaptive state dir must fail"
fwlive_adaptive_record 40 50
[ ! -f "$FWLIVE_ADAPTIVE_STATE_FILE" ] || die "must not write into a world-writable adaptive state dir"
FWLIVE_ADAPTIVE_STATE_FILE=$_saved_state
rm -rf "$_ww"
ok "world-writable adaptive state dir fails closed"

# One find per record: the directory check runs before the lock, not again
# inside the state write.
_find_log="$WORKDIR/find-calls.log"
_find_bin="$WORKDIR/find-on-path"
_real_find=$(command -v find)
mkdir -p "$_find_bin"
cat >"$_find_bin/find" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$_find_log"
exec "$_real_find" "\$@"
EOF
chmod +x "$_find_bin/find"
rm -f "$_find_log" "$FWLIVE_ADAPTIVE_STATE_FILE" "$(fwlive_adaptive_lock_path)"
fwlive_adaptive_write_state 0 2000 cold 0 0 0
rm -f "$_find_log"
PATH="$_find_bin${PATH:+:$PATH}" fwlive_adaptive_record 40 50
_finds=0
if [ -f "$_find_log" ]; then
	_finds=$(wc -l <"$_find_log" | tr -d ' ')
fi
[ "$_finds" = 1 ] || die "record find count $_finds want 1"
set -- $(fwlive_adaptive_read_state)
[ "$1" = 40 ] || die "find-count record did not run, duration=$1"
ok "record checks state dir once"

# Table-driven characterization of fwlive_adaptive_compute_limit (#1046).
# Captured before the limit-policy refactor. Clock is stubbed.
# Columns: label ms planning prev_limit prev_bucket prev_warm prev_completed_cs now req expected
(
	FWLIVE_ADAPTIVE_STATE_FILE="$WORKDIR/char-state.json"
	FWLIVE_ADAPTIVE_OFF_FILE="$WORKDIR/char-off"
	export FWLIVE_ADAPTIVE_STATE_FILE FWLIVE_ADAPTIVE_OFF_FILE
	# shellcheck disable=SC1090
	. "$ADAPTIVE_SH"
	_char_now=0
	fwlive_adaptive_clock_cs() { printf '%s\n' "$_char_now"; }
	_char_n=0
	while read -r _label _ms _plan _prev_l _prev_b _prev_w _prev_c _now _req _want; do
		[ -n "$_label" ] || continue
		_char_now=$_now
		_got=$(fwlive_adaptive_compute_limit "$_req" "$_ms" "$_prev_l" "$_prev_b" "$_prev_w" "$_prev_c" "$_plan")
		[ "$_got" = "$_want" ] || die \
			"compute_limit $_label got $_got want $_want"
		_char_n=$((_char_n + 1))
	done <<'EOF'
cold-p0-cold-none-above 40 0 500 cold 0 0 1000 2000 1000
cold-p0-cold-none-below 40 0 500 cold 0 0 1000 100 100
cold-p0-cold-active-above 40 0 500 cold 0 1000 1100 2000 1000
cold-p0-cold-active-below 40 0 500 cold 0 1000 1100 100 100
cold-p0-cold-expired-above 40 0 500 cold 0 1000 2000 2000 1000
cold-p0-cold-expired-below 40 0 500 cold 0 1000 2000 100 100
cold-p0-cool-none-above 40 0 500 cool 0 0 1000 2000 1000
cold-p0-cool-none-below 40 0 500 cool 0 0 1000 100 100
cold-p0-cool-active-above 40 0 500 cool 0 1000 1100 2000 1000
cold-p0-cool-active-below 40 0 500 cool 0 1000 1100 100 100
cold-p0-cool-expired-above 40 0 500 cool 0 1000 2000 2000 1000
cold-p0-cool-expired-below 40 0 500 cool 0 1000 2000 100 100
cold-p0-warm-none-above 40 0 500 warm 0 0 1000 2000 1000
cold-p0-warm-none-below 40 0 500 warm 0 0 1000 100 100
cold-p0-warm-active-above 40 0 500 warm 0 1000 1100 2000 1000
cold-p0-warm-active-below 40 0 500 warm 0 1000 1100 100 100
cold-p0-warm-expired-above 40 0 500 warm 0 1000 2000 2000 1000
cold-p0-warm-expired-below 40 0 500 warm 0 1000 2000 100 100
cold-p0-hot-none-above 40 0 500 hot 0 0 1000 2000 1000
cold-p0-hot-none-below 40 0 500 hot 0 0 1000 100 100
cold-p0-hot-active-above 40 0 500 hot 0 1000 1100 2000 1000
cold-p0-hot-active-below 40 0 500 hot 0 1000 1100 100 100
cold-p0-hot-expired-above 40 0 500 hot 0 1000 2000 2000 1000
cold-p0-hot-expired-below 40 0 500 hot 0 1000 2000 100 100
cold-p1-cold-none-above 40 1 500 cold 0 0 1000 2000 500
cold-p1-cold-none-below 40 1 500 cold 0 0 1000 100 100
cold-p1-cold-active-above 40 1 500 cold 0 1000 1100 2000 500
cold-p1-cold-active-below 40 1 500 cold 0 1000 1100 100 100
cold-p1-cold-expired-above 40 1 500 cold 0 1000 2000 2000 500
cold-p1-cold-expired-below 40 1 500 cold 0 1000 2000 100 100
cold-p1-cool-none-above 40 1 500 cool 0 0 1000 2000 500
cold-p1-cool-none-below 40 1 500 cool 0 0 1000 100 100
cold-p1-cool-active-above 40 1 500 cool 0 1000 1100 2000 500
cold-p1-cool-active-below 40 1 500 cool 0 1000 1100 100 100
cold-p1-cool-expired-above 40 1 500 cool 0 1000 2000 2000 500
cold-p1-cool-expired-below 40 1 500 cool 0 1000 2000 100 100
cold-p1-warm-none-above 40 1 500 warm 0 0 1000 2000 500
cold-p1-warm-none-below 40 1 500 warm 0 0 1000 100 100
cold-p1-warm-active-above 40 1 500 warm 0 1000 1100 2000 500
cold-p1-warm-active-below 40 1 500 warm 0 1000 1100 100 100
cold-p1-warm-expired-above 40 1 500 warm 0 1000 2000 2000 1000
cold-p1-warm-expired-below 40 1 500 warm 0 1000 2000 100 100
cold-p1-hot-none-above 40 1 500 hot 0 0 1000 2000 500
cold-p1-hot-none-below 40 1 500 hot 0 0 1000 100 100
cold-p1-hot-active-above 40 1 500 hot 0 1000 1100 2000 500
cold-p1-hot-active-below 40 1 500 hot 0 1000 1100 100 100
cold-p1-hot-expired-above 40 1 500 hot 0 1000 2000 2000 1000
cold-p1-hot-expired-below 40 1 500 hot 0 1000 2000 100 100
cool-p0-cold-none-above 150 0 500 cold 0 0 1000 2000 250
cool-p0-cold-none-below 150 0 500 cold 0 0 1000 100 100
cool-p0-cold-active-above 150 0 500 cold 0 1000 1100 2000 500
cool-p0-cold-active-below 150 0 500 cold 0 1000 1100 100 100
cool-p0-cold-expired-above 150 0 500 cold 0 1000 2000 2000 250
cool-p0-cold-expired-below 150 0 500 cold 0 1000 2000 100 100
cool-p0-cool-none-above 150 0 500 cool 0 0 1000 2000 250
cool-p0-cool-none-below 150 0 500 cool 0 0 1000 100 100
cool-p0-cool-active-above 150 0 500 cool 0 1000 1100 2000 500
cool-p0-cool-active-below 150 0 500 cool 0 1000 1100 100 100
cool-p0-cool-expired-above 150 0 500 cool 0 1000 2000 2000 250
cool-p0-cool-expired-below 150 0 500 cool 0 1000 2000 100 100
cool-p0-warm-none-above 150 0 500 warm 0 0 1000 2000 250
cool-p0-warm-none-below 150 0 500 warm 0 0 1000 100 100
cool-p0-warm-active-above 150 0 500 warm 0 1000 1100 2000 500
cool-p0-warm-active-below 150 0 500 warm 0 1000 1100 100 100
cool-p0-warm-expired-above 150 0 500 warm 0 1000 2000 2000 1000
cool-p0-warm-expired-below 150 0 500 warm 0 1000 2000 100 100
cool-p0-hot-none-above 150 0 500 hot 0 0 1000 2000 250
cool-p0-hot-none-below 150 0 500 hot 0 0 1000 100 100
cool-p0-hot-active-above 150 0 500 hot 0 1000 1100 2000 500
cool-p0-hot-active-below 150 0 500 hot 0 1000 1100 100 100
cool-p0-hot-expired-above 150 0 500 hot 0 1000 2000 2000 1000
cool-p0-hot-expired-below 150 0 500 hot 0 1000 2000 100 100
cool-p1-cold-none-above 150 1 500 cold 0 0 1000 2000 250
cool-p1-cold-none-below 150 1 500 cold 0 0 1000 100 100
cool-p1-cold-active-above 150 1 500 cold 0 1000 1100 2000 500
cool-p1-cold-active-below 150 1 500 cold 0 1000 1100 100 100
cool-p1-cold-expired-above 150 1 500 cold 0 1000 2000 2000 250
cool-p1-cold-expired-below 150 1 500 cold 0 1000 2000 100 100
cool-p1-cool-none-above 150 1 500 cool 0 0 1000 2000 250
cool-p1-cool-none-below 150 1 500 cool 0 0 1000 100 100
cool-p1-cool-active-above 150 1 500 cool 0 1000 1100 2000 500
cool-p1-cool-active-below 150 1 500 cool 0 1000 1100 100 100
cool-p1-cool-expired-above 150 1 500 cool 0 1000 2000 2000 250
cool-p1-cool-expired-below 150 1 500 cool 0 1000 2000 100 100
cool-p1-warm-none-above 150 1 500 warm 0 0 1000 2000 250
cool-p1-warm-none-below 150 1 500 warm 0 0 1000 100 100
cool-p1-warm-active-above 150 1 500 warm 0 1000 1100 2000 500
cool-p1-warm-active-below 150 1 500 warm 0 1000 1100 100 100
cool-p1-warm-expired-above 150 1 500 warm 0 1000 2000 2000 1000
cool-p1-warm-expired-below 150 1 500 warm 0 1000 2000 100 100
cool-p1-hot-none-above 150 1 500 hot 0 0 1000 2000 250
cool-p1-hot-none-below 150 1 500 hot 0 0 1000 100 100
cool-p1-hot-active-above 150 1 500 hot 0 1000 1100 2000 500
cool-p1-hot-active-below 150 1 500 hot 0 1000 1100 100 100
cool-p1-hot-expired-above 150 1 500 hot 0 1000 2000 2000 1000
cool-p1-hot-expired-below 150 1 500 hot 0 1000 2000 100 100
warm-p0-cold-none-above 400 0 500 cold 0 0 1000 2000 250
warm-p0-cold-none-below 400 0 500 cold 0 0 1000 100 100
warm-p0-cold-active-above 400 0 500 cold 0 1000 1100 2000 250
warm-p0-cold-active-below 400 0 500 cold 0 1000 1100 100 100
warm-p0-cold-expired-above 400 0 500 cold 0 1000 2000 2000 250
warm-p0-cold-expired-below 400 0 500 cold 0 1000 2000 100 100
warm-p0-cool-none-above 400 0 500 cool 0 0 1000 2000 250
warm-p0-cool-none-below 400 0 500 cool 0 0 1000 100 100
warm-p0-cool-active-above 400 0 500 cool 0 1000 1100 2000 250
warm-p0-cool-active-below 400 0 500 cool 0 1000 1100 100 100
warm-p0-cool-expired-above 400 0 500 cool 0 1000 2000 2000 250
warm-p0-cool-expired-below 400 0 500 cool 0 1000 2000 100 100
warm-p0-warm-none-above 400 0 500 warm 0 0 1000 2000 250
warm-p0-warm-none-below 400 0 500 warm 0 0 1000 100 100
warm-p0-warm-active-above 400 0 500 warm 0 1000 1100 2000 250
warm-p0-warm-active-below 400 0 500 warm 0 1000 1100 100 100
warm-p0-warm-expired-above 400 0 500 warm 0 1000 2000 2000 1000
warm-p0-warm-expired-below 400 0 500 warm 0 1000 2000 100 100
warm-p0-hot-none-above 400 0 500 hot 0 0 1000 2000 250
warm-p0-hot-none-below 400 0 500 hot 0 0 1000 100 100
warm-p0-hot-active-above 400 0 500 hot 0 1000 1100 2000 250
warm-p0-hot-active-below 400 0 500 hot 0 1000 1100 100 100
warm-p0-hot-expired-above 400 0 500 hot 0 1000 2000 2000 1000
warm-p0-hot-expired-below 400 0 500 hot 0 1000 2000 100 100
warm-p1-cold-none-above 400 1 500 cold 0 0 1000 2000 250
warm-p1-cold-none-below 400 1 500 cold 0 0 1000 100 100
warm-p1-cold-active-above 400 1 500 cold 0 1000 1100 2000 250
warm-p1-cold-active-below 400 1 500 cold 0 1000 1100 100 100
warm-p1-cold-expired-above 400 1 500 cold 0 1000 2000 2000 250
warm-p1-cold-expired-below 400 1 500 cold 0 1000 2000 100 100
warm-p1-cool-none-above 400 1 500 cool 0 0 1000 2000 250
warm-p1-cool-none-below 400 1 500 cool 0 0 1000 100 100
warm-p1-cool-active-above 400 1 500 cool 0 1000 1100 2000 250
warm-p1-cool-active-below 400 1 500 cool 0 1000 1100 100 100
warm-p1-cool-expired-above 400 1 500 cool 0 1000 2000 2000 250
warm-p1-cool-expired-below 400 1 500 cool 0 1000 2000 100 100
warm-p1-warm-none-above 400 1 500 warm 0 0 1000 2000 250
warm-p1-warm-none-below 400 1 500 warm 0 0 1000 100 100
warm-p1-warm-active-above 400 1 500 warm 0 1000 1100 2000 250
warm-p1-warm-active-below 400 1 500 warm 0 1000 1100 100 100
warm-p1-warm-expired-above 400 1 500 warm 0 1000 2000 2000 1000
warm-p1-warm-expired-below 400 1 500 warm 0 1000 2000 100 100
warm-p1-hot-none-above 400 1 500 hot 0 0 1000 2000 250
warm-p1-hot-none-below 400 1 500 hot 0 0 1000 100 100
warm-p1-hot-active-above 400 1 500 hot 0 1000 1100 2000 250
warm-p1-hot-active-below 400 1 500 hot 0 1000 1100 100 100
warm-p1-hot-expired-above 400 1 500 hot 0 1000 2000 2000 1000
warm-p1-hot-expired-below 400 1 500 hot 0 1000 2000 100 100
hot-p0-cold-none-above 900 0 500 cold 0 0 1000 2000 250
hot-p0-cold-none-below 900 0 500 cold 0 0 1000 100 100
hot-p0-cold-active-above 900 0 500 cold 0 1000 1100 2000 250
hot-p0-cold-active-below 900 0 500 cold 0 1000 1100 100 100
hot-p0-cold-expired-above 900 0 500 cold 0 1000 2000 2000 250
hot-p0-cold-expired-below 900 0 500 cold 0 1000 2000 100 100
hot-p0-cool-none-above 900 0 500 cool 0 0 1000 2000 250
hot-p0-cool-none-below 900 0 500 cool 0 0 1000 100 100
hot-p0-cool-active-above 900 0 500 cool 0 1000 1100 2000 250
hot-p0-cool-active-below 900 0 500 cool 0 1000 1100 100 100
hot-p0-cool-expired-above 900 0 500 cool 0 1000 2000 2000 250
hot-p0-cool-expired-below 900 0 500 cool 0 1000 2000 100 100
hot-p0-warm-none-above 900 0 500 warm 0 0 1000 2000 250
hot-p0-warm-none-below 900 0 500 warm 0 0 1000 100 100
hot-p0-warm-active-above 900 0 500 warm 0 1000 1100 2000 500
hot-p0-warm-active-below 900 0 500 warm 0 1000 1100 100 100
hot-p0-warm-expired-above 900 0 500 warm 0 1000 2000 2000 250
hot-p0-warm-expired-below 900 0 500 warm 0 1000 2000 100 100
hot-p0-hot-none-above 900 0 500 hot 0 0 1000 2000 250
hot-p0-hot-none-below 900 0 500 hot 0 0 1000 100 100
hot-p0-hot-active-above 900 0 500 hot 0 1000 1100 2000 500
hot-p0-hot-active-below 900 0 500 hot 0 1000 1100 100 100
hot-p0-hot-expired-above 900 0 500 hot 0 1000 2000 2000 250
hot-p0-hot-expired-below 900 0 500 hot 0 1000 2000 100 100
hot-p1-cold-none-above 900 1 500 cold 0 0 1000 2000 250
hot-p1-cold-none-below 900 1 500 cold 0 0 1000 100 100
hot-p1-cold-active-above 900 1 500 cold 0 1000 1100 2000 250
hot-p1-cold-active-below 900 1 500 cold 0 1000 1100 100 100
hot-p1-cold-expired-above 900 1 500 cold 0 1000 2000 2000 250
hot-p1-cold-expired-below 900 1 500 cold 0 1000 2000 100 100
hot-p1-cool-none-above 900 1 500 cool 0 0 1000 2000 250
hot-p1-cool-none-below 900 1 500 cool 0 0 1000 100 100
hot-p1-cool-active-above 900 1 500 cool 0 1000 1100 2000 250
hot-p1-cool-active-below 900 1 500 cool 0 1000 1100 100 100
hot-p1-cool-expired-above 900 1 500 cool 0 1000 2000 2000 250
hot-p1-cool-expired-below 900 1 500 cool 0 1000 2000 100 100
hot-p1-warm-none-above 900 1 500 warm 0 0 1000 2000 250
hot-p1-warm-none-below 900 1 500 warm 0 0 1000 100 100
hot-p1-warm-active-above 900 1 500 warm 0 1000 1100 2000 500
hot-p1-warm-active-below 900 1 500 warm 0 1000 1100 100 100
hot-p1-warm-expired-above 900 1 500 warm 0 1000 2000 2000 1000
hot-p1-warm-expired-below 900 1 500 warm 0 1000 2000 100 100
hot-p1-hot-none-above 900 1 500 hot 0 0 1000 2000 250
hot-p1-hot-none-below 900 1 500 hot 0 0 1000 100 100
hot-p1-hot-active-above 900 1 500 hot 0 1000 1100 2000 500
hot-p1-hot-active-below 900 1 500 hot 0 1000 1100 100 100
hot-p1-hot-expired-above 900 1 500 hot 0 1000 2000 2000 1000
hot-p1-hot-expired-below 900 1 500 hot 0 1000 2000 100 100
edge-prev0-cold-full 40 0 0 cold 0 0 1000 2000 2000
edge-prev0-cold-short 40 0 0 cold 0 0 1000 100 100
edge-prev0-plan 40 1 0 cold 0 0 1000 2000 2000
edge-prev1-double 40 0 1 cold 0 0 1000 250 2
edge-warm-hold 400 0 1000 warm 1 1000 1100 2000 1000
edge-warm-hold-plan 400 1 1000 warm 1 1000 1100 2000 1000
edge-cool-probe 150 0 500 cool 0 1000 1200 2000 500
edge-req-eq-prev 40 0 500 cold 0 0 1000 500 1000
EOF
	[ "$_char_n" = 200 ] || die "characterization rows $_char_n want 200"
)
ok "compute_limit characterization"

# rpcd sources this helper under `set -eu` and runs it with dash. A helper
# whose last `[` fails must still return 0, or plan prints nothing.
dash -c '
set -eu
export FWLIVE_ADAPTIVE=1
export FWLIVE_ADAPTIVE_STATE_FILE="$2"
export FWLIVE_ADAPTIVE_OFF_FILE="$3"
export POLL_LINES_MAX=2000
rm -f "$FWLIVE_ADAPTIVE_STATE_FILE" "$FWLIVE_ADAPTIVE_OFF_FILE"
. "$1"
fwlive_adaptive_clock_cs() { printf "%s\n" 1000; }
_out=$(fwlive_adaptive_plan 500)
[ "$_out" = "500 0 cold" ] || exit 1
_out=$(fwlive_adaptive_merge_reply "{}" 0 50 0 0)
[ "$_out" = "{\"adaptive\":1,\"messages_received\":0,\"truncated\":0}" ] || exit 1
' sh "$ADAPTIVE_SH" "$WORKDIR/dash-eu-state.json" "$WORKDIR/dash-eu-off" \
	|| die "dash set -eu plan/merge"
ok "dash set -eu plan and merge"
echo "fwlive-adaptive-cap tests passed"
