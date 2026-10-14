#!/usr/bin/env bash
# Cadence-independent adaptive-cap trajectories (#1241).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTIVE_SH="$ROOT/openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-adaptive-cap.sh"

die() { echo "fwlive-adaptive-trajectory test FAIL: $*" >&2; exit 1; }
ok() { echo "fwlive-adaptive-trajectory test OK: $*"; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
export POLL_LINES_MAX=2000
unset FWLIVE_ADAPTIVE

# Run a scripted duration sequence at a fixed clock cadence. Prints the
# plan-limit sequence (effective_limit per poll). Clock is only the
# completed_cs prior-decision marker; the decision must not use elapsed time.
run_plans() {
	local interval_cs=$1
	shift
	local durations="$*"
	(
		FWLIVE_ADAPTIVE_STATE_FILE="$WORKDIR/traj-$$-$interval_cs.json"
		FWLIVE_ADAPTIVE_OFF_FILE="$WORKDIR/traj-$$-$interval_cs.off"
		export FWLIVE_ADAPTIVE_STATE_FILE FWLIVE_ADAPTIVE_OFF_FILE POLL_LINES_MAX
		# shellcheck disable=SC1090
		. "$ADAPTIVE_SH"
		_clock=$interval_cs
		fwlive_adaptive_clock_cs() { printf '%s\n' "$_clock"; }
		rm -f "$FWLIVE_ADAPTIVE_STATE_FILE" "$FWLIVE_ADAPTIVE_OFF_FILE"
		_seq=
		for _ms in $durations; do
			_plan=$(fwlive_adaptive_plan 2000)
			_limit=${_plan%% *}
			_seq="${_seq:+$_seq }$_limit"
			fwlive_adaptive_record "$_ms" "$_limit"
			_clock=$((_clock + interval_cs))
		done
		printf '%s\n' "$_seq"
	)
}

# Cost-based workload: duration_ms = served * us_per_line / 1000.
run_cost_plans() {
	local interval_cs=$1 us_per_line=$2 n=$3
	(
		FWLIVE_ADAPTIVE_STATE_FILE="$WORKDIR/cost-$$-$interval_cs.json"
		FWLIVE_ADAPTIVE_OFF_FILE="$WORKDIR/cost-$$-$interval_cs.off"
		export FWLIVE_ADAPTIVE_STATE_FILE FWLIVE_ADAPTIVE_OFF_FILE POLL_LINES_MAX
		# shellcheck disable=SC1090
		. "$ADAPTIVE_SH"
		_clock=$interval_cs
		fwlive_adaptive_clock_cs() { printf '%s\n' "$_clock"; }
		rm -f "$FWLIVE_ADAPTIVE_STATE_FILE" "$FWLIVE_ADAPTIVE_OFF_FILE"
		_seq=
		_i=0
		while [ "$_i" -lt "$n" ]; do
			_plan=$(fwlive_adaptive_plan 2000)
			_limit=${_plan%% *}
			_seq="${_seq:+$_seq }$_limit"
			_ms=$((_limit * us_per_line / 1000))
			fwlive_adaptive_record "$_ms" "$_limit"
			_clock=$((_clock + interval_cs))
			_i=$((_i + 1))
		done
		printf '%s\n' "$_seq"
	)
}

# Overload-then-recovery: first hot_n polls are 900 ms, then cost-based.
run_recovery_plans() {
	local interval_cs=$1 us_per_line=$2 hot_n=$3 n=$4
	(
		FWLIVE_ADAPTIVE_STATE_FILE="$WORKDIR/rec-$$-$interval_cs.json"
		FWLIVE_ADAPTIVE_OFF_FILE="$WORKDIR/rec-$$-$interval_cs.off"
		export FWLIVE_ADAPTIVE_STATE_FILE FWLIVE_ADAPTIVE_OFF_FILE POLL_LINES_MAX
		# shellcheck disable=SC1090
		. "$ADAPTIVE_SH"
		_clock=$interval_cs
		fwlive_adaptive_clock_cs() { printf '%s\n' "$_clock"; }
		rm -f "$FWLIVE_ADAPTIVE_STATE_FILE" "$FWLIVE_ADAPTIVE_OFF_FILE"
		_seq=
		_i=0
		while [ "$_i" -lt "$n" ]; do
			_plan=$(fwlive_adaptive_plan 2000)
			_limit=${_plan%% *}
			_seq="${_seq:+$_seq }$_limit"
			if [ "$_i" -lt "$hot_n" ]; then
				_ms=900
			else
				_ms=$((_limit * us_per_line / 1000))
			fi
			fwlive_adaptive_record "$_ms" "$_limit"
			_clock=$((_clock + interval_cs))
			_i=$((_i + 1))
		done
		printf '%s\n' "$_seq"
	)
}

# T1 — for every scenario, the limit sequence at 100 cs equals 500 cs.
t1_eq() {
	local name=$1 short=$2 long=$3
	[ "$short" = "$long" ] || die "T1 $name: 100cs [$short] != 500cs [$long]"
	ok "T1 $name cadence-equal"
}

_steady75_100=$(run_cost_plans 100 75 12)
_steady75_500=$(run_cost_plans 500 75 12)
t1_eq "steady-cool-75us" "$_steady75_100" "$_steady75_500"

_steady200_100=$(run_cost_plans 100 200 12)
_steady200_500=$(run_cost_plans 500 200 12)
t1_eq "steady-warm-200us" "$_steady200_100" "$_steady200_500"

_rec_100=$(run_recovery_plans 100 75 4 16)
_rec_500=$(run_recovery_plans 500 75 4 16)
t1_eq "overload-then-recovery" "$_rec_100" "$_rec_500"

_scripted_100=$(run_plans 100 150 40 40 40 150 150 150)
_scripted_500=$(run_plans 500 150 40 40 40 150 150 150)
t1_eq "scripted-cool-cold" "$_scripted_100" "$_scripted_500"

# T2 — a steady scenario reaches a value within N polls and never leaves it.
t2_stable() {
	local name=$1 seq=$2 n=$3
	# shellcheck disable=SC2086
	set -- $seq
	[ "$#" -ge "$n" ] || die "T2 $name: too few polls ($# < $n)"
	local i=0 last= reached=0 stable=
	for _l in "$@"; do
		i=$((i + 1))
		if [ "$i" -eq 1 ]; then
			last=$_l
			continue
		fi
		if [ "$_l" = "$last" ]; then
			if [ "$reached" -eq 0 ] && [ "$i" -le "$n" ]; then
				reached=1
				stable=$_l
			fi
			[ "$reached" -eq 1 ] || die "T2 $name: plateau after poll $n: $seq"
			[ "$_l" = "$stable" ] || die "T2 $name: left $stable at poll $i: $seq"
		else
			[ "$reached" -eq 0 ] || die "T2 $name: left $stable at poll $i: $seq"
			last=$_l
		fi
	done
	[ "$reached" -eq 1 ] || die "T2 $name: never stabilized within $n polls: $seq"
	ok "T2 $name reaches $stable and stays"
}

t2_stable "steady-cool-75us-100cs" "$_steady75_100" 8
t2_stable "steady-cool-75us-500cs" "$_steady75_500" 8
t2_stable "steady-warm-200us-100cs" "$_steady200_100" 8
t2_stable "steady-warm-200us-500cs" "$_steady200_500" 8

# T3 — a faster sample never yields a smaller cap than a slower one at the
# same retained limit.
(
	FWLIVE_ADAPTIVE_STATE_FILE="$WORKDIR/t3-state.json"
	FWLIVE_ADAPTIVE_OFF_FILE="$WORKDIR/t3-off"
	export FWLIVE_ADAPTIVE_STATE_FILE FWLIVE_ADAPTIVE_OFF_FILE POLL_LINES_MAX
	# shellcheck disable=SC1090
	. "$ADAPTIVE_SH"
	_prev_l=2000
	_prev_b=cool
	_prev_w=0
	_prev_c=1
	_faster_ms="40 75 150 200 400 500 600 900"
	_i=0
	_prev_ms=
	_prev_cap=
	for _ms in $_faster_ms; do
		_cap=$(fwlive_adaptive_compute_limit 2000 "$_ms" "$_prev_l" "$_prev_b" "$_prev_w" "$_prev_c" 0)
		if [ -n "$_prev_ms" ]; then
			[ "$_prev_cap" -ge "$_cap" ] || die \
				"T3 faster ${_prev_ms}ms cap=$_prev_cap < slower ${_ms}ms cap=$_cap at limit=$_prev_l"
		fi
		_prev_ms=$_ms
		_prev_cap=$_cap
		_i=$((_i + 1))
	done
	# Same check from a prior hot floor, and from a prior warm half.
	for _state in "250 hot 0" "1000 warm 1"; do
		# shellcheck disable=SC2086
		set -- $_state
		_prev_l=$1
		_prev_b=$2
		_prev_w=$3
		_prev_ms=
		_prev_cap=
		for _ms in $_faster_ms; do
			_cap=$(fwlive_adaptive_compute_limit 2000 "$_ms" "$_prev_l" "$_prev_b" "$_prev_w" "$_prev_c" 0)
			if [ -n "$_prev_ms" ]; then
				[ "$_prev_cap" -ge "$_cap" ] || die \
					"T3 faster ${_prev_ms}ms cap=$_prev_cap < slower ${_ms}ms cap=$_cap at $_prev_l/$_prev_b"
			fi
			_prev_ms=$_ms
			_prev_cap=$_cap
		done
	done
)
ok "T3 faster sample never yields a smaller cap"

echo "fwlive-adaptive-trajectory tests passed"
