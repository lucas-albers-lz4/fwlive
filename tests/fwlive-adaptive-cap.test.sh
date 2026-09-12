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

# Lock path unopenable → fail-open still records (CodeRabbit CR1).
fwlive_adaptive_write_state 0 2000 cold 0 0 0
_lock_dir="$WORKDIR/lock-as-dir"
mkdir -p "$_lock_dir"
_saved_lock=${FWLIVE_ADAPTIVE_LOCK_FILE:-}
export FWLIVE_ADAPTIVE_LOCK_FILE="$_lock_dir"
fwlive_adaptive_record 900 2000
set -- $(fwlive_adaptive_read_state)
[ "$3" = hot ] || die "record must run when lock open fails, bucket=$3"
if [ -n "$_saved_lock" ]; then
	export FWLIVE_ADAPTIVE_LOCK_FILE="$_saved_lock"
else
	unset FWLIVE_ADAPTIVE_LOCK_FILE
fi
ok "lock-open failure fail-opens record"

# merge_reply shape
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
ok "merge_reply"

# count_log without jsonfilter
[ "$(fwlive_adaptive_count_log '{"log":[]}')" = 0 ] || die "empty count"
[ "$(fwlive_adaptive_count_log '{"log":[{"msg":"a"},{"msg":"b"}]}')" = 2 ] || die "count 2"
ok "count_log"

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

echo "fwlive-adaptive-cap tests passed"
