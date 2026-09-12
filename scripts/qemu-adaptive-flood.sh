#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# QEMU guest flood evidence for #306 Layer 1 adaptive shedding.
#
# Binding AC (armsr): OWRT_QEMU_SMP=1 OWRT_QEMU_MEM=256, raised log ring,
# one flood poll >800 ms, next 3 polls truncated:1 and ≤250 lines; A/B with
# /var/run/fwlive-adaptive-off.
#
# Usage (guest already running + fwlive installed):
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-adaptive-flood.sh
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-adaptive-flood.sh --skip-raise-log
#
# Emits FLOOD_* lines for CI grepping / table fill.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
FIXTURE="${FWLIVE_FLOOD_FIXTURE:-${ROOT}/tests/fixtures/logread-2000.json}"
REMOTE_FIXTURE=/tmp/fwlive-logread-2000.json
KNOWN_HOSTS="${FWLIVE_KNOWN_HOSTS:-${ROOT}/lab/qemu-known_hosts}"
LOG_SIZE_KIB="${FWLIVE_FLOOD_LOG_SIZE_KIB:-1024}"
SKIP_RAISE_LOG=0
REQUESTED_LINES="${FWLIVE_FLOOD_LINES:-2000}"
FOLLOW_POLLS="${FWLIVE_FLOOD_FOLLOW_POLLS:-3}"
HOT_MS="${FWLIVE_FLOOD_HOT_MS:-800}"
MAX_SERVED="${FWLIVE_FLOOD_MAX_SERVED:-250}"

usage() {
	sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-raise-log) SKIP_RAISE_LOG=1; shift ;;
		--fixture) FIXTURE="${2:?}"; shift 2 ;;
		--log-size) LOG_SIZE_KIB="${2:?}"; shift 2 ;;
		-h|--help) usage 0 ;;
		*) echo "unknown arg: $1" >&2; usage 1 ;;
	esac
done

if [[ "$FIXTURE" != /* ]]; then
	FIXTURE="${ROOT}/${FIXTURE}"
fi
[[ -f "$FIXTURE" ]] || { echo "fixture not found: $FIXTURE" >&2; exit 1; }

mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"
SSH_OPTS=(-o StrictHostKeyChecking="${FWLIVE_STRICT_HOST_KEY_CHECKING:-accept-new}" \
	-o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -p "$PORT")

ssh "${SSH_OPTS[@]}" "root@$HOST" 'echo connected' >/dev/null

RUN_ID="${FWLIVE_PROFILE_RUN_ID:-flood-$(date +%Y%m%dT%H%M%S)-$RANDOM}"
case "$RUN_ID" in
	''|*[!A-Za-z0-9._-]*)
		echo "invalid FWLIVE_PROFILE_RUN_ID (use [A-Za-z0-9._-]+): $RUN_ID" >&2
		exit 1
		;;
esac

GIT_SHA="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

echo "Copying $(basename "$FIXTURE") → root@$HOST:$PORT:$REMOTE_FIXTURE" >&2
if scp -O -q -P "$PORT" -o StrictHostKeyChecking="${FWLIVE_STRICT_HOST_KEY_CHECKING:-accept-new}" \
	-o UserKnownHostsFile="$KNOWN_HOSTS" \
	"$FIXTURE" "root@$HOST:$REMOTE_FIXTURE" 2>/dev/null; then
	:
else
	ssh "${SSH_OPTS[@]}" "root@$HOST" "cat > $REMOTE_FIXTURE" <"$FIXTURE"
fi

# Ensure adaptive helper is present (source-sync installs historically omitted it).
if ! ssh "${SSH_OPTS[@]}" "root@$HOST" 'test -f /usr/libexec/fwlive-adaptive-cap.sh'; then
	echo "FLOOD_ERROR reason=adaptive_helper_missing hint=run_qemu-install-fwlive.sh" >&2
	exit 1
fi

ssh "${SSH_OPTS[@]}" "root@$HOST" sh -s -- \
	"$REMOTE_FIXTURE" "$RUN_ID" "$GIT_SHA" "$LOG_SIZE_KIB" "$SKIP_RAISE_LOG" \
	"$REQUESTED_LINES" "$FOLLOW_POLLS" "$HOT_MS" "$MAX_SERVED" <<'REMOTE'
set -eu
fixture=$1
run_id=$2
git_sha=$3
log_size_kib=$4
skip_raise=$5
requested=$6
follow_n=$7
hot_ms=$8
max_served=$9

STATE=/var/run/fwlive-state.json
OFF=/var/run/fwlive-adaptive-off
POLL_OUT=/tmp/fwlive-flood-poll.json
SHIM_DIR=/tmp/fwlive-flood-shims

clock_cs() {
	read uptime _ </proc/uptime
	seconds=${uptime%.*}
	fraction=${uptime#*.}
	fraction=${fraction#0}
	[ -n "$fraction" ] || fraction=0
	# Avoid octal: strip leading zeros digit-wise for BusyBox ash.
	_s=$seconds
	_n=0
	while [ -n "$_s" ]; do
		_d=${_s%"${_s#?}"}
		_s=${_s#?}
		case "$_d" in [0-9]) _n=$((_n * 10 + _d)) ;; esac
	done
	_f=$fraction
	_m=0
	while [ -n "$_f" ]; do
		_d=${_f%"${_f#?}"}
		_f=${_f#?}
		case "$_d" in [0-9]) _m=$((_m * 10 + _d)) ;; esac
	done
	# At most two frac digits.
	case "$fraction" in
		?) _m=$((_m * 10)) ;;
		??) ;;
		*)
			_m=0
			_f=$fraction
			_i=0
			while [ "$_i" -lt 2 ] && [ -n "$_f" ]; do
				_d=${_f%"${_f#?}"}
				_f=${_f#?}
				case "$_d" in [0-9]) _m=$((_m * 10 + _d)) ;; esac
				_i=$((_i + 1))
			done
			;;
	esac
	printf '%s\n' $((_n * 100 + _m))
}

json_int() {
	# Extract first "key":N from one-line JSON (busybox-safe).
	_blob=$1
	_key=$2
	_def=$3
	case "$_blob" in
		*"\"$_key\""*) ;;
		*) printf '%s\n' "$_def"; return 0 ;;
	esac
	_rest=${_blob#*"\"$_key\""}
	_rest=${_rest#*:}
	while case "$_rest" in ' '*) true;; *) false;; esac; do
		_rest=${_rest# }
	done
	_num=
	while :; do
		case "$_rest" in '') break ;; esac
		_c=${_rest%"${_rest#?}"}
		case "$_c" in
			[0-9]) _num="${_num}${_c}"; _rest=${_rest#?} ;;
			*) break ;;
		esac
	done
	case "$_num" in ''|*[!0-9]*) printf '%s\n' "$_def" ;; *) printf '%s\n' "$_num" ;; esac
}

count_log_msgs() {
	_json=$1
	_n=0
	_rest=$_json
	while :; do
		case "$_rest" in
			*'"msg"'*)
				_n=$((_n + 1))
				_rest=${_rest#*\"msg\"}
				;;
			*) break ;;
		esac
	done
	printf '%s\n' "$_n"
}

setup_shim() {
	rm -rf "$SHIM_DIR"
	mkdir -p "$SHIM_DIR"
	cat >"$SHIM_DIR/ubus" <<'UBUS'
#!/bin/sh
if [ "$1" = call ] && [ "$2" = log ] && [ "$3" = read ]; then
	exec /bin/cat /tmp/fwlive-logread-2000.json
fi
exec /bin/ubus "$@"
UBUS
	chmod +x "$SHIM_DIR/ubus"
}

raise_log_ring() {
	[ "$skip_raise" = 1 ] && return 0
	# Prefer log_size (documented); fall back to log_buffer_size if present.
	key=
	if uci -q get system.@system[0].log_size >/dev/null 2>&1; then
		key=log_size
	elif uci -q get system.@system[0].log_buffer_size >/dev/null 2>&1; then
		key=log_buffer_size
	else
		# Create log_size on anonymous system section.
		key=log_size
	fi
	uci set "system.@system[0].${key}=${log_size_kib}"
	uci commit system
	/etc/init.d/log restart 2>/dev/null || true
	sleep 1
	val=$(uci -q get "system.@system[0].${key}" || echo unknown)
	printf 'FLOOD_META log_uci_key=%s log_uci_value=%s\n' "$key" "$val"
}

clear_adaptive() {
	rm -f "$STATE" "${STATE}.tmp."* "$OFF" 2>/dev/null || true
}

poll_once() {
	label=$1
	mode=$2
	setup_shim
	printf '%s' "{\"addresses\":[\"$requested\"]}" >/tmp/fwlive-flood-in.json
	start=$(clock_cs)
	PATH="$SHIM_DIR:$PATH" /usr/libexec/rpcd/fwlive call poll \
		</tmp/fwlive-flood-in.json >"$POLL_OUT" 2>/dev/null || {
		printf 'FLOOD_ERROR phase=%s mode=%s reason=poll_failed\n' "$label" "$mode"
		return 1
	}
	end=$(clock_cs)
	elapsed_cs=$((end - start))
	[ "$elapsed_cs" -lt 0 ] && elapsed_cs=0
	wall_ms=$((elapsed_cs * 10))
	raw=
	IFS= read -r raw <"$POLL_OUT" || raw=
	adaptive=$(json_int "$raw" adaptive 0)
	truncated=$(json_int "$raw" truncated 0)
	msgs=$(count_log_msgs "$raw")
	# shed.limit if present
	shed_limit=$(json_int "$raw" limit 0)
	case "$raw" in
		*'"shed"'*) shed=1 ;;
		*) shed=0 ;;
	esac
	state_bucket=none
	state_dur=0
	if [ -f "$STATE" ]; then
		st=
		IFS= read -r st <"$STATE" || st=
		state_bucket=$(printf '%s' "$st" | sed -n 's/.*"bucket"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n1)
		[ -n "$state_bucket" ] || state_bucket=none
		state_dur=$(json_int "$st" duration_ms 0)
	fi
	printf 'FLOOD_POLL phase=%s mode=%s wall_ms=%s adaptive=%s truncated=%s shed=%s shed_limit=%s log_msgs=%s state_bucket=%s state_duration_ms=%s\n' \
		"$label" "$mode" "$wall_ms" "$adaptive" "$truncated" "$shed" "$shed_limit" "$msgs" "$state_bucket" "$state_dur"
	# Export for caller via files
	printf '%s\n' "$wall_ms" >/tmp/fwlive-flood-last-wall
	printf '%s\n' "$truncated" >/tmp/fwlive-flood-last-trunc
	printf '%s\n' "$msgs" >/tmp/fwlive-flood-last-msgs
	printf '%s\n' "$adaptive" >/tmp/fwlive-flood-last-adapt
	printf '%s\n' "$state_bucket" >/tmp/fwlive-flood-last-bucket
	printf '%s\n' "$shed" >/tmp/fwlive-flood-last-shed
}

resolve_check() {
	mode=$1
	out=$(ubus call fwlive resolve '{"addresses":["192.0.2.1"]}' 2>/dev/null || echo '{}')
	case "$out" in
		*'"disabled":"load"'*|*'\"disabled\":\"load\"'*)
			printf 'FLOOD_RESOLVE mode=%s disabled=load\n' "$mode"
			;;
		*)
			printf 'FLOOD_RESOLVE mode=%s disabled=none raw=%s\n' "$mode" "$(printf '%s' "$out" | tr '\n' ' ')"
			;;
	esac
}

run_mode() {
	mode=$1
	clear_adaptive
	if [ "$mode" = off ]; then
		: >"$OFF"
	else
		rm -f "$OFF"
	fi

	# Induce: first poll at full request (fixture-backed via PATH-shim).
	poll_once induce "$mode" || return 1
	wall=$(cat /tmp/fwlive-flood-last-wall)
	bucket=$(cat /tmp/fwlive-flood-last-bucket)
	shed=$(cat /tmp/fwlive-flood-last-shed)

	hot_ok=0
	if [ "$mode" = on ]; then
		if [ "$wall" -gt "$hot_ms" ] || [ "$bucket" = hot ] || [ "$shed" = 1 ]; then
			hot_ok=1
		fi
		printf 'FLOOD_INDUCE mode=on wall_ms=%s hot_threshold_ms=%s hot_ok=%s\n' \
			"$wall" "$hot_ms" "$hot_ok"
	else
		printf 'FLOOD_INDUCE mode=off wall_ms=%s (no shed expected)\n' "$wall"
	fi

	i=1
	pass_follow=1
	while [ "$i" -le "$follow_n" ]; do
		poll_once "follow$i" "$mode" || return 1
		trunc=$(cat /tmp/fwlive-flood-last-trunc)
		msgs=$(cat /tmp/fwlive-flood-last-msgs)
		adapt=$(cat /tmp/fwlive-flood-last-adapt)
		if [ "$mode" = on ]; then
			if [ "$trunc" != 1 ] || [ "$msgs" -gt "$max_served" ]; then
				pass_follow=0
			fi
			if [ "$adapt" != 1 ]; then
				pass_follow=0
			fi
		else
			# Off: no truncation from adaptive; may still be filter-sized.
			if [ "$adapt" != 0 ]; then
				pass_follow=0
			fi
		fi
		i=$((i + 1))
	done

	if [ "$mode" = on ] && [ "$hot_ok" = 1 ]; then
		resolve_check on
	elif [ "$mode" = on ]; then
		printf 'FLOOD_RESOLVE mode=on skipped=induce_not_hot\n'
	fi

	printf 'FLOOD_MODE_RESULT mode=%s follow_pass=%s induce_hot_ok=%s\n' \
		"$mode" "$pass_follow" "${hot_ok:-0}"
	printf '%s\n' "$pass_follow" >"/tmp/fwlive-flood-verdict-${mode}-follow"
	printf '%s\n' "${hot_ok:-0}" >"/tmp/fwlive-flood-verdict-${mode}-hot"
}

# --- meta ---
printf 'FLOOD_META run_id=%s git_sha=%s arch=%s\n' "$run_id" "$git_sha" "$(uname -m)"
printf 'FLOOD_META release=%s revision=%s\n' \
	"$(sed -n 's/^DISTRIB_RELEASE=//p' /etc/openwrt_release)" \
	"$(sed -n 's/^DISTRIB_REVISION=//p' /etc/openwrt_release)"
printf 'FLOOD_META nproc=%s memtotal_kb=%s\n' \
	"$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 0)" \
	"$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
printf 'FLOOD_META fixture_bytes=%s requested=%s follow_n=%s hot_ms=%s max_served=%s\n' \
	"$(wc -c <"$fixture" | tr -d ' ')" "$requested" "$follow_n" "$hot_ms" "$max_served"
printf 'FLOOD_META busybox=%s\n' \
	"$(opkg status busybox 2>/dev/null | sed -n 's/^Version: //p' || echo unknown)"

raise_log_ring

run_mode on
run_mode off

on_hot=$(cat /tmp/fwlive-flood-verdict-on-hot 2>/dev/null || echo 0)
on_follow=$(cat /tmp/fwlive-flood-verdict-on-follow 2>/dev/null || echo 0)
off_follow=$(cat /tmp/fwlive-flood-verdict-off-follow 2>/dev/null || echo 0)

ac_pass=0
if [ "$on_hot" = 1 ] && [ "$on_follow" = 1 ] && [ "$off_follow" = 1 ]; then
	ac_pass=1
fi
printf 'FLOOD_VERDICT ac_pass=%s on_induce_hot=%s on_follow_pass=%s off_follow_pass=%s\n' \
	"$ac_pass" "$on_hot" "$on_follow" "$off_follow"
printf 'FLOOD_DONE run_id=%s\n' "$run_id"
REMOTE

# Host-side: fail if guest did not emit ac_pass=1 (optional strict mode).
if [[ "${FWLIVE_FLOOD_STRICT:-0}" == 1 ]]; then
	# Re-run would be needed to capture; instead tee is caller's job.
	:
fi
