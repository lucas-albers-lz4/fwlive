#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# QEMU guest flood evidence for #306 Layer 1 adaptive shedding.
#
# Measurement path: PATH-shim C1 (fixture-backed log.read), same class as
# memory-census C1 / budget-split fixture filter — not stock-ring logd.
# Adaptive measures processing duration; the 2000-entry fixture filter is the
# reliable way to exceed the hot threshold on armsr TCG.
#
# Binding AC (armsr): OWRT_QEMU_SMP=1 OWRT_QEMU_MEM=256; induce hot; next 3
# polls truncated:1 and ≤250 delivered msgs; A/B with /var/run/fwlive-adaptive-off.
#
# Usage (guest already running + fwlive installed):
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-adaptive-flood.sh
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-adaptive-flood.sh --raise-log
#
# Emits FLOOD_* lines. Host exits non-zero unless FLOOD_VERDICT ac_pass=1
# (override with FWLIVE_FLOOD_STRICT=0).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
FIXTURE="${FWLIVE_FLOOD_FIXTURE:-${ROOT}/tests/fixtures/logread-2000.json}"
REMOTE_FIXTURE=/tmp/fwlive-logread-2000.json
KNOWN_HOSTS="${FWLIVE_KNOWN_HOSTS:-${ROOT}/lab/qemu-known_hosts}"
LOG_SIZE_KIB="${FWLIVE_FLOOD_LOG_SIZE_KIB:-1024}"
# C1 fixture path does not need a raised ring; optional for rig documentation.
RAISE_LOG=0
REQUESTED_LINES="${FWLIVE_FLOOD_LINES:-2000}"
FOLLOW_POLLS="${FWLIVE_FLOOD_FOLLOW_POLLS:-3}"
HOT_MS="${FWLIVE_FLOOD_HOT_MS:-800}"
MAX_SERVED="${FWLIVE_FLOOD_MAX_SERVED:-250}"
STRICT="${FWLIVE_FLOOD_STRICT:-1}"

case "$FOLLOW_POLLS" in
	''|*[!0-9]*)
		echo "FWLIVE_FLOOD_FOLLOW_POLLS must be a positive integer (got: $FOLLOW_POLLS)" >&2
		exit 1
		;;
esac
# Bash 10# avoids octal; reject 0 / 00 / 000 after normalize.
FOLLOW_POLLS=$((10#$FOLLOW_POLLS))
if [[ "$FOLLOW_POLLS" -lt 1 ]]; then
	echo "FWLIVE_FLOOD_FOLLOW_POLLS must be a positive integer (got: 0)" >&2
	exit 1
fi

usage() {
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--raise-log) RAISE_LOG=1; shift ;;
		--skip-raise-log) RAISE_LOG=0; shift ;;
		--fixture) FIXTURE="${2:?}"; shift 2 ;;
		--log-size) LOG_SIZE_KIB="${2:?}"; shift 2 ;;
		-h|--help) usage 0 ;;
		*) echo "unknown arg: $1" >&2; usage 1 ;;
	esac
done

require_positive_int() {
	_name=$1
	_val=$2
	case "$_val" in
		''|*[!0-9]*)
			echo "$_name must be a positive integer (got: $_val)" >&2
			exit 1
			;;
	esac
	_val=$((10#$_val))
	if [[ "$_val" -lt 1 ]]; then
		echo "$_name must be a positive integer (got: 0)" >&2
		exit 1
	fi
	printf '%s' "$_val"
}

REQUESTED_LINES=$(require_positive_int FWLIVE_FLOOD_LINES "$REQUESTED_LINES")
HOT_MS=$(require_positive_int FWLIVE_FLOOD_HOT_MS "$HOT_MS")
MAX_SERVED=$(require_positive_int FWLIVE_FLOOD_MAX_SERVED "$MAX_SERVED")
LOG_SIZE_KIB=$(require_positive_int FWLIVE_FLOOD_LOG_SIZE_KIB "$LOG_SIZE_KIB")

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

if ! ssh "${SSH_OPTS[@]}" "root@$HOST" 'test -f /usr/libexec/fwlive-adaptive-cap.sh'; then
	echo "FLOOD_ERROR reason=adaptive_helper_missing hint=run_qemu-install-fwlive.sh" >&2
	exit 1
fi

OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

ssh "${SSH_OPTS[@]}" "root@$HOST" sh -s -- \
	"$REMOTE_FIXTURE" "$RUN_ID" "$GIT_SHA" "$LOG_SIZE_KIB" "$RAISE_LOG" \
	"$REQUESTED_LINES" "$FOLLOW_POLLS" "$HOT_MS" "$MAX_SERVED" \
	<<'REMOTE' | tee "$OUT_FILE"
set -eu
fixture=$1
run_id=$2
git_sha=$3
log_size_kib=$4
raise_log=$5
requested=$6
follow_n=$7
hot_ms=$8
max_served=$9

STATE=/var/run/fwlive-state.json
OFF=/var/run/fwlive-adaptive-off
POLL_OUT=/tmp/fwlive-flood-poll.json
SHIM_DIR=/tmp/fwlive-flood-shims
ENTRIES=/tmp/fwlive-flood-entries.txt
# Always clear adaptive-off so a failed off-mode poll cannot leave the guest disabled.
trap 'rm -f "$OFF"' EXIT HUP INT TERM

# Match product fwlive_adaptive_clock_cs (no octal; two frac digits).
clock_cs() {
	_up=
	read -r _up _ </proc/uptime 2>/dev/null || { printf '%s\n' 0; return 0; }
	_sec=${_up%.*}
	_frac=${_up#*.}
	[ "$_frac" = "$_up" ] && _frac=0
	case "$_frac" in
		'') _frac=0 ;;
		?) _frac="${_frac}0" ;;
		??) ;;
		*)
			_a=${_frac%${_frac#?}}
			_r=${_frac#?}
			_b=${_r%${_r#?}}
			_frac="${_a}${_b}"
			;;
	esac
	_atoi() {
		_s=$1
		_n=0
		case "$_s" in ''|*[!0-9]*) printf '0'; return ;; esac
		while [ -n "$_s" ]; do
			_d=${_s%"${_s#?}"}
			_s=${_s#?}
			_n=$((_n * 10 + _d))
		done
		printf '%s' "$_n"
	}
	_sec=$(_atoi "$_sec")
	_frac=$(_atoi "$_frac")
	printf '%s\n' $((_sec * 100 + _frac))
}

json_int() {
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
	# Prefer jsonfilter when present (off product hot path).
	_json=$1
	if command -v jsonfilter >/dev/null 2>&1; then
		_n=$(printf '%s' "$_json" | jsonfilter -e '@.log[*]' 2>/dev/null | wc -l | tr -d ' \n')
		case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
		printf '%s\n' "$_n"
		return 0
	fi
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

# Pre-split fixture entries once (one jsonfilter pass).
prepare_entries() {
	if command -v jsonfilter >/dev/null 2>&1; then
		jsonfilter -i "$fixture" -e '@.log[*]' >"$ENTRIES" 2>/dev/null || : >"$ENTRIES"
	else
		: >"$ENTRIES"
	fi
	printf 'FLOOD_META fixture_entries=%s\n' "$(wc -l <"$ENTRIES" | tr -d ' ')"
}

setup_shim() {
	rm -rf "$SHIM_DIR"
	mkdir -p "$SHIM_DIR"
	# Honor lines= from ubus JSON arg (Bugbot/Luna/Grok P1).
	cat >"$SHIM_DIR/ubus" <<'UBUS'
#!/bin/sh
if [ "$1" = call ] && [ "$2" = log ] && [ "$3" = read ]; then
	arg=${4:-}
	lines=2000
	case "$arg" in
		*\"lines\":*)
			rest=${arg#*\"lines\":}
			while case "$rest" in ' '*) true;; *) false;; esac; do
				rest=${rest# }
			done
			num=
			while :; do
				case "$rest" in '') break ;; esac
				c=${rest%"${rest#?}"}
				case "$c" in
					[0-9]) num="${num}${c}"; rest=${rest#?} ;;
					*) break ;;
				esac
			done
			case "$num" in ''|*[!0-9]*) ;; *) lines=$num ;; esac
			;;
	esac
	entries=/tmp/fwlive-flood-entries.txt
	out=/tmp/fwlive-flood-shim-out.json
	{
		printf '{"log":['
		i=0
		first=1
		while IFS= read -r ent; do
			[ "$i" -ge "$lines" ] && break
			[ "$first" = 1 ] || printf ','
			first=0
			printf '%s' "$ent"
			i=$((i + 1))
		done <"$entries"
		printf ']}'
	} >"$out"
	exec /bin/cat "$out"
fi
exec /bin/ubus "$@"
UBUS
	chmod +x "$SHIM_DIR/ubus"
}

raise_log_ring() {
	[ "$raise_log" = 1 ] || {
		printf 'FLOOD_META log_uci=skipped path=c1_fixture_shim\n'
		return 0
	}
	key=
	if uci -q get system.@system[0].log_size >/dev/null 2>&1; then
		key=log_size
	elif uci -q get system.@system[0].log_buffer_size >/dev/null 2>&1; then
		key=log_buffer_size
	else
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
	# Reply may be large — avoid stuffing into ash vars when possible.
	adaptive=$(jsonfilter -i "$POLL_OUT" -e '@.adaptive' 2>/dev/null || echo 0)
	truncated=$(jsonfilter -i "$POLL_OUT" -e '@.truncated' 2>/dev/null || echo 0)
	case "$truncated" in ''|*[!0-9]*) truncated=0 ;; esac
	case "$adaptive" in ''|*[!0-9]*) adaptive=0 ;; esac
	msgs=$(count_log_msgs "$(cat "$POLL_OUT")")
	shed_limit=$(jsonfilter -i "$POLL_OUT" -e '@.shed.limit' 2>/dev/null || echo 0)
	case "$shed_limit" in ''|*[!0-9]*) shed_limit=0 ;; esac
	shed=0
	jsonfilter -i "$POLL_OUT" -e '@.shed' >/dev/null 2>&1 && shed=1
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
	printf '%s\n' "$wall_ms" >/tmp/fwlive-flood-last-wall
	printf '%s\n' "$truncated" >/tmp/fwlive-flood-last-trunc
	printf '%s\n' "$msgs" >/tmp/fwlive-flood-last-msgs
	printf '%s\n' "$adaptive" >/tmp/fwlive-flood-last-adapt
	printf '%s\n' "$state_bucket" >/tmp/fwlive-flood-last-bucket
	printf '%s\n' "$shed" >/tmp/fwlive-flood-last-shed
	printf '%s\n' "$shed_limit" >/tmp/fwlive-flood-last-shed-limit
	printf '%s\n' "$state_dur" >/tmp/fwlive-flood-last-state-dur
}

resolve_check() {
	mode=$1
	# ubus may pretty-print ("disabled": "load") or compact ("disabled":"load").
	out=$(ubus call fwlive resolve '{"addresses":["192.0.2.1"]}' 2>/dev/null || echo '{}')
	case "$out" in
		*'"disabled"'*:*'"load"'*)
			printf 'FLOOD_RESOLVE mode=%s disabled=load\n' "$mode"
			printf '1\n' >/tmp/fwlive-flood-last-resolve
			;;
		*)
			printf 'FLOOD_RESOLVE mode=%s disabled=none\n' "$mode"
			printf '0\n' >/tmp/fwlive-flood-last-resolve
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

	poll_once induce "$mode" || return 1
	bucket=$(cat /tmp/fwlive-flood-last-bucket)
	state_dur=$(cat /tmp/fwlive-flood-last-state-dur)
	wall=$(cat /tmp/fwlive-flood-last-wall)

	hot_ok=0
	if [ "$mode" = on ]; then
		# Gate on product state after induce record — not harness wall (Grok P2).
		if [ "$bucket" = hot ] || [ "$state_dur" -gt "$hot_ms" ]; then
			hot_ok=1
		fi
		printf 'FLOOD_INDUCE mode=on wall_ms=%s state_duration_ms=%s state_bucket=%s hot_ok=%s\n' \
			"$wall" "$state_dur" "$bucket" "$hot_ok"
		if [ "$hot_ok" = 1 ]; then
			resolve_check on
		else
			printf '0\n' >/tmp/fwlive-flood-last-resolve
			printf 'FLOOD_RESOLVE mode=on skipped=induce_not_hot\n'
		fi
	else
		printf 'FLOOD_INDUCE mode=off wall_ms=%s\n' "$wall"
		printf '0\n' >/tmp/fwlive-flood-last-resolve
	fi

	i=1
	pass_follow=1
	while [ "$i" -le "$follow_n" ]; do
		poll_once "follow$i" "$mode" || return 1
		trunc=$(cat /tmp/fwlive-flood-last-trunc)
		msgs=$(cat /tmp/fwlive-flood-last-msgs)
		adapt=$(cat /tmp/fwlive-flood-last-adapt)
		shed=$(cat /tmp/fwlive-flood-last-shed)
		slimit=$(cat /tmp/fwlive-flood-last-shed-limit)
		if [ "$mode" = on ]; then
			if [ "$trunc" != 1 ] || [ "$msgs" -gt "$max_served" ]; then
				pass_follow=0
			fi
			if [ "$adapt" != 1 ]; then
				pass_follow=0
			fi
			# When shed is present, limit must be the hot floor.
			if [ "$shed" = 1 ] && [ "$slimit" -gt 0 ] && [ "$slimit" -gt "$max_served" ]; then
				pass_follow=0
			fi
		else
			if [ "$adapt" != 0 ]; then
				pass_follow=0
			fi
			if [ "$shed" = 1 ]; then
				pass_follow=0
			fi
			# Off: still full fixture-scale payload (firewall msgs >> max_served).
			if [ "$msgs" -le "$max_served" ]; then
				pass_follow=0
			fi
		fi
		i=$((i + 1))
	done

	resolve_pass=$(cat /tmp/fwlive-flood-last-resolve 2>/dev/null || echo 0)
	printf 'FLOOD_MODE_RESULT mode=%s follow_pass=%s induce_hot_ok=%s resolve_pass=%s\n' \
		"$mode" "$pass_follow" "${hot_ok:-0}" "$resolve_pass"
	printf '%s\n' "$pass_follow" >"/tmp/fwlive-flood-verdict-${mode}-follow"
	printf '%s\n' "${hot_ok:-0}" >"/tmp/fwlive-flood-verdict-${mode}-hot"
	printf '%s\n' "$resolve_pass" >"/tmp/fwlive-flood-verdict-${mode}-resolve"
}

printf 'FLOOD_META run_id=%s git_sha=%s arch=%s path=c1_fixture_shim\n' \
	"$run_id" "$git_sha" "$(uname -m)"
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
prepare_entries

run_mode on
run_mode off

# Leave adaptive enabled for any follow-up UI work on the guest.
rm -f "$OFF"

on_hot=$(cat /tmp/fwlive-flood-verdict-on-hot 2>/dev/null || echo 0)
on_follow=$(cat /tmp/fwlive-flood-verdict-on-follow 2>/dev/null || echo 0)
on_resolve=$(cat /tmp/fwlive-flood-verdict-on-resolve 2>/dev/null || echo 0)
off_follow=$(cat /tmp/fwlive-flood-verdict-off-follow 2>/dev/null || echo 0)

ac_pass=0
if [ "$on_hot" = 1 ] && [ "$on_follow" = 1 ] && [ "$on_resolve" = 1 ] && [ "$off_follow" = 1 ]; then
	ac_pass=1
fi
printf 'FLOOD_VERDICT ac_pass=%s on_induce_hot=%s on_follow_pass=%s on_resolve_pass=%s off_follow_pass=%s\n' \
	"$ac_pass" "$on_hot" "$on_follow" "$on_resolve" "$off_follow"
printf 'FLOOD_DONE run_id=%s\n' "$run_id"
REMOTE

if [[ "$STRICT" == 1 ]]; then
	if ! grep -q 'FLOOD_VERDICT ac_pass=1' "$OUT_FILE"; then
		echo "FLOOD_ERROR host: ac_pass!=1 (set FWLIVE_FLOOD_STRICT=0 to ignore)" >&2
		exit 1
	fi
fi
