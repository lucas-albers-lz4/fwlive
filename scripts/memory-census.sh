#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Measure fwlive process-tree RSS on a running OpenWrt guest (#319).
#
# Budget series is summed VmRSS (kB). Peak is the max of a concurrent ~50 ms
# sampler, not VmPeak. Soft ceilings bind on RSS; PSS is an x86 companion.
#
# Usage:
#   OPENWRT_SSH_PORT=2222 ./scripts/memory-census.sh [fixture]
#   ./scripts/memory-census.sh --help
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
FIXTURE="${1:-${ROOT}/tests/fixtures/logread-2000.json}"
REMOTE_FIXTURE=/tmp/fwlive-logread-2000.json
KNOWN_HOSTS="${FWLIVE_KNOWN_HOSTS:-${ROOT}/lab/qemu-known_hosts}"

usage() {
	sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"
SSH_OPTS=(-o StrictHostKeyChecking="${FWLIVE_STRICT_HOST_KEY_CHECKING:-accept-new}" -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -p "$PORT")

[[ -f "$FIXTURE" ]] || { echo "fixture not found: $FIXTURE" >&2; exit 1; }
ssh "${SSH_OPTS[@]}" "root@$HOST" 'echo connected' >/dev/null

echo "Copying $(basename "$FIXTURE") to root@$HOST:$PORT:$REMOTE_FIXTURE" >&2
if scp -O -q -P "$PORT" -o StrictHostKeyChecking="${FWLIVE_STRICT_HOST_KEY_CHECKING:-accept-new}" -o UserKnownHostsFile="$KNOWN_HOSTS" \
	"$FIXTURE" "root@$HOST:$REMOTE_FIXTURE" 2>/dev/null; then
	:
else
	ssh "${SSH_OPTS[@]}" "root@$HOST" "cat > $REMOTE_FIXTURE" <"$FIXTURE"
fi

RUN_ID="${FWLIVE_PROFILE_RUN_ID:-$(date +%Y%m%dT%H%M%S)-$RANDOM}"

ssh "${SSH_OPTS[@]}" "root@$HOST" sh -s -- "$REMOTE_FIXTURE" "$RUN_ID" <<'REMOTE'
set -eu
fixture=$1
run_id=$2

DUMP=/tmp/fwlive-mem-dump
PEAK=/tmp/fwlive-mem-peak
C1_IN=/tmp/fwlive-mem-c1-in
POLL_OUT=/tmp/fwlive-mem-poll-out
HAS_PSS=0
TREE_RSS=0
TREE_PSS=0
TREE_HWM=0
TREE_NPROCS=0

clock_cs() {
	read uptime _ </proc/uptime
	seconds=${uptime%.*}
	fraction=${uptime#*.}
	fraction=${fraction#0}
	[ -n "$fraction" ] || fraction=0
	printf '%s\n' $((seconds * 100 + fraction))
}

wait_cs() {
	target=$(($(clock_cs) + $1))
	while [ "$(clock_cs)" -lt "$target" ]; do
		:
	done
}

read_self_pid() {
	line=
	read line </proc/self/stat || true
	printf '%s\n' "${line%% *}"
}

read_starttime() {
	pid=$1
	line=
	read line <"/proc/$pid/stat" || true
	[ -n "$line" ] || { printf '%s\n' 0; return; }
	rest=${line##*)}
	set -- $rest
	printf '%s\n' "${20:-0}"
}

read_pss() {
	pid=$1
	[ -r "/proc/$pid/smaps_rollup" ] || { printf '%s\n' 0; return; }
	while read key val unit; do
		case "$key" in
			Pss:) printf '%s\n' "${val:-0}"; return ;;
		esac
	done <"/proc/$pid/smaps_rollup"
	printf '%s\n' 0
}

find_named_pid() {
	name=$1
	pid=
	if command -v pidof >/dev/null 2>&1; then
		pid=$(pidof "$name" 2>/dev/null || true)
		pid=${pid%% *}
	fi
	if [ -z "$pid" ]; then
		for status in /proc/[0-9]*/status; do
			[ -r "$status" ] || continue
			n=$(sed -n 's/^Name:[[:space:]]*//p' "$status" 2>/dev/null || true)
			if [ "$n" = "$name" ]; then
				pid=${status#/proc/}
				pid=${pid%/status}
				break
			fi
		done
	fi
	printf '%s\n' "$pid"
}

rpcd_pid() {
	pid=$(find_named_pid rpcd)
	[ -n "$pid" ] || { echo "PROFILE_ERROR reason=rpcd_not_running" >&2; exit 1; }
	printf '%s\n' "$pid"
}

probe_pss() {
	[ -r /proc/self/smaps_rollup ] || return 1
	while read key val unit; do
		case "$key" in
			Pss:) return 0 ;;
		esac
	done </proc/self/smaps_rollup
	return 1
}

scan_proc() {
	: >"$DUMP"
	for status in /proc/[0-9]*/status; do
		[ -r "$status" ] || continue
		pid=${status#/proc/}
		pid=${pid%/status}
		ppid=0
		rss=0
		hwm=0
		while read key val unit; do
			case "$key" in
				PPid:) ppid=${val:-0} ;;
				VmRSS:) rss=${val:-0} ;;
				VmHWM:) hwm=${val:-0} ;;
			esac
		done <"$status"
		printf '%s %s %s %s\n' "$pid" "$ppid" "$rss" "$hwm" >>"$DUMP"
	done
}

# BFS under root. Peak walks always include root RSS; descendants contribute
# only when starttime >= min_start (empty min_start = no filter). Sampler PID
# is omitted entirely, including its children.
walk_tree() {
	root=$1
	exclude=$2
	min_start=$3

	scan_proc
	TREE_RSS=0
	TREE_PSS=0
	TREE_HWM=0
	TREE_NPROCS=0

	queue=$root
	seen=" $root "

	while [ -n "$queue" ]; do
		set -- $queue
		pid=$1
		shift
		queue=$*

		[ "$pid" != "$exclude" ] || continue

		found=0
		rss=0
		hwm=0
		while read dpid dppid drss dhwm; do
			if [ "$dpid" = "$pid" ]; then
				rss=$drss
				hwm=$dhwm
				found=1
				break
			fi
		done <"$DUMP"
		[ "$found" = 1 ] || continue

		include=1
		if [ "$pid" != "$root" ] && [ -n "$min_start" ]; then
			st=$(read_starttime "$pid")
			[ "$st" -ge "$min_start" ] 2>/dev/null || include=0
		fi
		if [ "$include" = 1 ]; then
			TREE_RSS=$((TREE_RSS + rss))
			[ "$hwm" -gt "$TREE_HWM" ] && TREE_HWM=$hwm
			TREE_NPROCS=$((TREE_NPROCS + 1))
			if [ "$HAS_PSS" = 1 ]; then
				pss=$(read_pss "$pid")
				TREE_PSS=$((TREE_PSS + pss))
			fi
		fi

		while read dpid dppid drss dhwm; do
			[ "$dppid" = "$pid" ] || continue
			[ "$dpid" != "$exclude" ] || continue
			case "$seen" in
				*" $dpid "*) continue ;;
			esac
			seen="$seen$dpid "
			queue="$queue $dpid"
		done <"$DUMP"
	done
}

emit() {
	printf 'MEMORY_SAMPLE'
	for kv in "$@"; do
		printf ' %s' "$kv"
	done
	printf '\n'
}

count_log_lines() {
	file=$1
	[ -s "$file" ] || { printf '%s\n' 0; return; }
	n=0
	if command -v jsonfilter >/dev/null 2>&1; then
		n=$(jsonfilter -e '@.log[*]' <"$file" 2>/dev/null | wc -l || true)
		n=$(printf '%s' "$n" | tr -d ' \n')
	fi
	[ -n "$n" ] || n=0
	printf '%s\n' "$n"
}

sample_idle_tree() {
	root=$(rpcd_pid)
	walk_tree "$root" "$(read_self_pid)" ""
}

emit_tree() {
	case=$1
	root_kind=$2
	metric=$3
	value=$4
	extra=${5:-}
	if [ -n "$extra" ]; then
		emit "case=$case" "root=$root_kind" "metric=$metric" "value=$value" "nprocs=$TREE_NPROCS" "$extra"
	else
		emit "case=$case" "root=$root_kind" "metric=$metric" "value=$value" "nprocs=$TREE_NPROCS"
	fi
}

emit_idle_metrics() {
	case=$1
	extra=${2:-}
	sample_idle_tree
	emit_tree "$case" rpcd rss_kb "$TREE_RSS" "$extra"
	if [ "$HAS_PSS" = 1 ]; then
		emit_tree "$case" rpcd pss_kb "$TREE_PSS" "$extra"
	fi
}

emit_logd() {
	case=$1
	pid=$(find_named_pid logd)
	if [ -z "$pid" ] || [ ! -r "/proc/$pid/status" ]; then
		emit "case=$case" metric=logd_rss_kb value=0
		return
	fi
	rss=0
	while read key val unit; do
		case "$key" in
			VmRSS:) rss=${val:-0}; break ;;
		esac
	done <"/proc/$pid/status"
	emit "case=$case" metric=logd_rss_kb "value=$rss"
}

# Concurrent ~50 ms sampler. Peak is the max tree RSS while watch_pid lives.
sampler_loop() {
	root=$1
	watch=$2
	min_start=$3
	out=$4
	exclude=$(read_self_pid)

	peak_rss=0
	peak_pss=0
	peak_hwm=0
	peak_n=0

	while kill -0 "$watch" 2>/dev/null; do
		walk_tree "$root" "$exclude" "$min_start"
		if [ "$TREE_RSS" -gt "$peak_rss" ]; then
			peak_rss=$TREE_RSS
			peak_pss=$TREE_PSS
			peak_hwm=$TREE_HWM
			peak_n=$TREE_NPROCS
		fi
		kill -0 "$watch" 2>/dev/null || break
		wait_cs 5
	done

	if [ "$peak_n" -eq 0 ]; then
		walk_tree "$root" "$exclude" "$min_start"
		peak_rss=$TREE_RSS
		peak_pss=$TREE_PSS
		peak_hwm=$TREE_HWM
		peak_n=$TREE_NPROCS
	fi

	printf '%s %s %s %s\n' "$peak_rss" "$peak_n" "$peak_pss" "$peak_hwm" >"$out"
}

measure_peak() {
	case=$1
	root_kind=$2
	sample_i=$3

	if [ "$root_kind" = fwlive ]; then
		printf '%s' '{"addresses":["2000"]}' >"$C1_IN"
		PATH="$shim_dir:$PATH" /usr/libexec/rpcd/fwlive call poll <"$C1_IN" >"$POLL_OUT" 2>/dev/null &
		root=$!
		watch=$root
	else
		root=$(rpcd_pid)
		ubus call fwlive poll '{"addresses":["50"]}' >"$POLL_OUT" 2>/dev/null &
		watch=$!
	fi

	min_start=$(read_starttime "$watch")
	rm -f "$PEAK"
	sampler_loop "$root" "$watch" "$min_start" "$PEAK" &
	sampler=$!
	wait "$watch" || echo "PROFILE_ERROR case=$case sample_i=$sample_i command_failed" >&2
	wait "$sampler" || true

	peak_rss=0
	peak_n=0
	peak_pss=0
	peak_hwm=0
	[ -s "$PEAK" ] && read peak_rss peak_n peak_pss peak_hwm <"$PEAK" || true
	lines=$(count_log_lines "$POLL_OUT")

	emit "case=$case" "root=$root_kind" metric=peak_rss_kb "value=$peak_rss" "nprocs=$peak_n" "sample_i=$sample_i" "lines=$lines"
	if [ "$HAS_PSS" = 1 ]; then
		emit "case=$case" "root=$root_kind" metric=pss_kb "value=$peak_pss" "nprocs=$peak_n" "sample_i=$sample_i"
	fi
	emit "case=$case" "root=$root_kind" metric=hwm_kb "value=$peak_hwm" "sample_i=$sample_i"
}

setup_c1_shim() {
	shim_dir=/tmp/fwlive-mem-shims
	rm -rf "$shim_dir"
	mkdir "$shim_dir"
	cat >"$shim_dir/wrap" <<'WRAP'
#!/bin/sh
name=${0##*/}
case "$name" in
  cat) real=/bin/cat ;;
  jsonfilter) real=/usr/bin/jsonfilter ;;
  awk) real=/usr/bin/awk ;;
  dirname) real=/usr/bin/dirname ;;
  sed) real=/bin/sed ;;
  jshn) real=/usr/bin/jshn ;;
  ubus)
    if [ "$1" = call ] && [ "$2" = log ] && [ "$3" = read ]; then
      exec /bin/cat /tmp/fwlive-logread-2000.json
    fi
    real=/bin/ubus ;;
  *) exit 127 ;;
esac
exec "$real" "$@"
WRAP
	chmod +x "$shim_dir/wrap"
	for command in cat jsonfilter awk dirname sed jshn ubus; do
		ln -s wrap "$shim_dir/$command"
	done
}

if probe_pss; then
	HAS_PSS=1
	primitive=pss
else
	primitive=vmrss
fi

mem_kb=$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo)
mem_mib=$((${mem_kb:-0} / 1024))
smp=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)
[ -n "$smp" ] && [ "$smp" -gt 0 ] || smp=1

echo "PROFILE_META release=$(sed -n 's/^DISTRIB_RELEASE=//p' /etc/openwrt_release)"
echo "PROFILE_META revision=$(sed -n 's/^DISTRIB_REVISION=//p' /etc/openwrt_release)"
echo "PROFILE_META arch=$(uname -m) busybox=$(opkg status busybox 2>/dev/null | sed -n 's/^Version: //p')"
echo "PROFILE_META mem_mib=$mem_mib smp=$smp"
echo "PROFILE_META fixture=$(wc -c <"$fixture" | tr -d ' ')_bytes"
echo "PROFILE_META primitive=$primitive"
echo "PROFILE_META run_id=$run_id"
echo "PROFILE_META lines_c2=50 lines_c1=2000"

# --- idle ---
emit_idle_metrics idle
emit_logd idle

# --- nofork: 60s idle, zero polls; Z is sized from this delta later ---
emit_idle_metrics nofork sample_i=0
t0=$TREE_RSS
echo "waiting 60s (nofork)" >&2
sleep 60
emit_idle_metrics nofork sample_i=1
emit "case=nofork" root=rpcd metric=delta_rss_kb "value=$((TREE_RSS - t0))"

# --- C2: live ubus poll, root=rpcd, n=5 ---
i=1
while [ "$i" -le 5 ]; do
	measure_peak c2_live rpcd "$i"
	i=$((i + 1))
done

# --- retention: T0 idle → 10× C2 polls → 60s idle → T1 ---
emit_idle_metrics retention sample_i=0
t0=$TREE_RSS
j=1
while [ "$j" -le 10 ]; do
	ubus call fwlive poll '{"addresses":["50"]}' >/dev/null 2>&1 || \
		echo "PROFILE_ERROR case=retention poll=$j command_failed" >&2
	j=$((j + 1))
done
echo "waiting 60s (retention)" >&2
sleep 60
emit_idle_metrics retention sample_i=1
emit "case=retention" root=rpcd metric=delta_rss_kb "value=$((TREE_RSS - t0))"
emit_logd retention

# --- C1 last: PATH-shim direct plugin, fixture-backed log read, root=fwlive ---
setup_c1_shim
i=1
while [ "$i" -le 5 ]; do
	measure_peak c1_fixture fwlive "$i"
	i=$((i + 1))
done

echo "MEMORY_SKIP case=adaptive reason=needs_306"
echo "MEMORY_SKIP case=visibility reason=needs_306"
REMOTE
