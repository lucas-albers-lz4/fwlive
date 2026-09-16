#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Run paired no-viewer/active-viewer forwarding samples. The guest and host
# topology must already be configured; this command owns only the temporary
# adaptive sentinel and the local Playwright viewer process.
#
# Usage:
#   ./scripts/qemu-forwarding-slo-run.sh --adaptive on
#   ./scripts/qemu-forwarding-slo-run.sh --adaptive on --bitrate 1G
#   ./scripts/qemu-forwarding-slo-run.sh --adaptive off --pairs 5 --duration 10
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
USER="${OPENWRT_USER:-root}"
KNOWN_HOSTS="${FWLIVE_KNOWN_HOSTS:-${ROOT}/lab/qemu-known_hosts}"
IPERF3="${FWLIVE_SLO_IPERF3:-}"
BITRATE="${FWLIVE_SLO_IPERF_BITRATE:-}"
DURATION="${FWLIVE_SLO_IPERF_DURATION:-10}"
PING_COUNT="${FWLIVE_SLO_PING_COUNT:-20}"
PING_INTERVAL="${FWLIVE_SLO_PING_INTERVAL_S:-}"
PAIRS="${FWLIVE_SLO_PAIRS:-5}"
DRAIN_MS="${FWLIVE_SLO_DRAIN_MS:-3000}"
REPORT_FILE="${FWLIVE_SLO_REPORT_FILE:-}"
ADAPTIVE=""
ENFORCE=0
RUN_STARTED_AT="$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')"
ORIGINAL_ADAPTIVE_OFF_STATE=""

die() { echo "forwarding-slo-run: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--adaptive) ADAPTIVE="${2:-}"; shift 2 ;;
		--pairs) PAIRS="${2:-}"; shift 2 ;;
		--bitrate) BITRATE="${2:-}"; shift 2 ;;
		--duration) DURATION="${2:-}"; shift 2 ;;
		--ping-count) PING_COUNT="${2:-}"; shift 2 ;;
		--drain-ms) DRAIN_MS="${2:-}"; shift 2 ;;
		--report-file) REPORT_FILE="${2:-}"; shift 2 ;;
		--enforce) ENFORCE=1; shift ;;
		-h|--help)
			sed -n '7,13p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*) die "unknown argument: $1" ;;
	esac
done

[[ "$ADAPTIVE" = on || "$ADAPTIVE" = off ]] || die "--adaptive must be on or off"
for value in "$PAIRS" "$DURATION" "$PING_COUNT" "$DRAIN_MS"; do
	case "$value" in ''|*[!0-9]*) die "numeric options must be decimal integers" ;; esac
done
(( PAIRS > 0 )) || die "pairs must be greater than zero"
(( DURATION > 0 )) || die "duration must be greater than zero"
(( PING_COUNT > 0 )) || die "ping count must be greater than zero"
(( DRAIN_MS > 0 )) || die "drain-ms must be greater than zero"
command -v node >/dev/null 2>&1 || die "missing required tool: node"
command -v ssh >/dev/null 2>&1 || die "missing required tool: ssh"
command -v sudo >/dev/null 2>&1 || die "missing required tool: sudo"

mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"
SSH_OPTS=(-o StrictHostKeyChecking="${FWLIVE_STRICT_HOST_KEY_CHECKING:-accept-new}"
	-o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -p "$PORT")

set_adaptive() {
	ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" sh -s -- "$1" <<'REMOTE'
set -eu
case "$1" in
on) rm -f /var/run/fwlive-adaptive-off ;;
off) : >/var/run/fwlive-adaptive-off ;;
*) echo "invalid adaptive mode" >&2; exit 2 ;;
esac
REMOTE
}

get_adaptive_state() {
	ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" sh -s <<'REMOTE'
set -eu
if [ -e /var/run/fwlive-adaptive-off ]; then
	echo present
else
	echo absent
fi
REMOTE
}

restore_adaptive_state() {
	case "$ORIGINAL_ADAPTIVE_OFF_STATE" in
		present)
			ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" 'umask 077; : >/var/run/fwlive-adaptive-off' ;;
		absent)
			ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" 'rm -f /var/run/fwlive-adaptive-off' ;;
		*) die "invalid saved adaptive sentinel state" ;;
	esac
}

TMP_ROOT="${TMPDIR:-/tmp}"
[[ -d "$TMP_ROOT" ]] || die "temporary directory is missing: $TMP_ROOT"
[[ -O "$TMP_ROOT" || -k "$TMP_ROOT" ]] || die "temporary directory must be owner-controlled or sticky: $TMP_ROOT"
WORK="$(mktemp -d "$TMP_ROOT/fwlive-slo-run.XXXXXX")"
chmod 700 "$WORK"
RECORDS="$WORK/records.jsonl"
VIEWER_PID=""
CURRENT_VIEWER_DIR=""

cleanup() {
	if [[ -n "$VIEWER_PID" ]]; then
		kill "$VIEWER_PID" 2>/dev/null || true
		wait "$VIEWER_PID" 2>/dev/null || true
		VIEWER_PID=""
	fi
	if [[ -n "$ORIGINAL_ADAPTIVE_OFF_STATE" ]]; then
		restore_adaptive_state 2>/dev/null || true
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

wait_for_file() {
	local file=$1
	local limit=$2
	local i=0
	while (( i < limit )); do
		[[ -f "$file" ]] && return 0
		if [[ -n "$VIEWER_PID" ]] && ! kill -0 "$VIEWER_PID" 2>/dev/null; then
			return 1
		fi
		sleep 0.05
		i=$((i + 1))
	done
	return 1
}

record_sample() {
	local pair=$1 mode=$2 sample_file=$3 viewer_file=$4
	local throughput ping
	throughput="$(sed -n 's/.*throughput_bps=\([^[:space:]]*\).*/\1/p' "$sample_file" | tail -1)"
	ping="$(sed -n 's/.*ping_rtt_stddev_ms=\([^[:space:]]*\).*/\1/p' "$sample_file" | tail -1)"
	[[ "$throughput" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "traffic probe did not emit throughput: $sample_file"
	[[ "$ping" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "traffic probe did not emit ping spread: $sample_file"

	node - "$RECORDS" "$pair" "$ADAPTIVE" "$mode" "$throughput" "$ping" "$viewer_file" "$DRAIN_MS" <<'NODE'
const fs = require('node:fs');
const [file, pair, adaptive, mode, throughput, ping, viewerFile, drainMs] = process.argv.slice(2);
const viewer = viewerFile === '-'
	? { viewer: 'none', polls_in_window: 0, requests: {}, in_flight_after_drain: 0 }
	: JSON.parse(fs.readFileSync(viewerFile, 'utf8'));
const row = {
	pair: Number(pair),
	adaptive,
	mode,
	throughput_bps: Number(throughput),
	ping_rtt_stddev_ms: Number(ping),
	drain_ms: Number(drainMs),
	viewer
};
fs.appendFileSync(file, `${JSON.stringify(row)}\n`);
console.log(`SLO_PAIR pair=${pair} adaptive=${adaptive} mode=${mode} throughput_bps=${throughput} ping_rtt_stddev_ms=${ping} viewer_polls=${viewer.polls_in_window}`);
NODE
}

run_traffic() {
	local label=$1 output=$2 start_marker=${3:-} stop_marker=${4:-}
	sudo env \
		FWLIVE_SLO_IPERF3="$IPERF3" \
		FWLIVE_SLO_IPERF_BITRATE="$BITRATE" \
		FWLIVE_SLO_IPERF_DURATION="$DURATION" \
		FWLIVE_SLO_PING_COUNT="$PING_COUNT" \
		FWLIVE_SLO_PING_INTERVAL_S="$PING_INTERVAL" \
		FWLIVE_SLO_TRAFFIC_START_FILE="$start_marker" \
		FWLIVE_SLO_TRAFFIC_STOP_FILE="$stop_marker" \
		"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" --label "$label" |
		tee "$output" >/dev/null
}

ORIGINAL_ADAPTIVE_OFF_STATE="$(get_adaptive_state)"
set_adaptive "$ADAPTIVE"
for (( pair = 1; pair <= PAIRS; pair++ )); do
	# The active viewer from the preceding pair has closed and drained before
	# this wait. Keep the no-viewer baseline free of an intentional poll burst.
	if (( pair > 1 )); then
		drain_sleep="$(printf '%d.%03d' "$((DRAIN_MS / 1000))" "$((DRAIN_MS % 1000))")"
		sleep "$drain_sleep"
	fi
	baseline="$WORK/pair-${pair}-no-viewer.out"
	run_traffic "adaptive-${ADAPTIVE}-pair-${pair}-no-viewer" "$baseline"
	record_sample "$pair" no-viewer "$baseline" -

	CURRENT_VIEWER_DIR="$WORK/pair-${pair}-active-viewer"
	mkdir -p "$CURRENT_VIEWER_DIR"
	ready="$CURRENT_VIEWER_DIR/ready"
	start="$CURRENT_VIEWER_DIR/start"
	stop="$CURRENT_VIEWER_DIR/stop"
	viewer_result="$CURRENT_VIEWER_DIR/result.json"
	viewer_log="$CURRENT_VIEWER_DIR/viewer.log"
	rm -f "$ready" "$start" "$stop" "$viewer_result"
	node "$ROOT/tests/fwlive-forwarding-slo-viewer.mjs" \
		--ready-file "$ready" --start-file "$start" --stop-file "$stop" \
		--result-file "$viewer_result" --timeout-ms "$((DURATION * 1000 + 60000))" \
		--drain-ms "$DRAIN_MS" >"$viewer_log" 2>&1 &
	VIEWER_PID=$!
	if ! wait_for_file "$ready" 1200; then
		cat "$viewer_log" >&2 || true
		die "active viewer did not become ready for pair $pair"
	fi
	active="$CURRENT_VIEWER_DIR/active-viewer.out"
	if ! run_traffic "adaptive-${ADAPTIVE}-pair-${pair}-active-viewer" "$active" "$start" "$stop"; then
		# The privileged traffic helper signals stop before it exits on a
		# client failure. Only create the marker here when it is still absent;
		# otherwise a root-owned marker can be unwritable by the runner user.
		[[ -e "$stop" ]] || touch "$stop"
		wait "$VIEWER_PID" 2>/dev/null || true
		VIEWER_PID=""
		cat "$active" "$viewer_log" >&2 || true
		die "active-viewer traffic failed for pair $pair"
	fi
	if ! wait "$VIEWER_PID"; then
		cat "$viewer_log" >&2 || true
		VIEWER_PID=""
		die "active viewer failed for pair $pair"
	fi
	VIEWER_PID=""
	[[ -s "$viewer_result" ]] || die "active viewer produced no result for pair $pair"
	record_sample "$pair" active-viewer "$active" "$viewer_result"
done

node "$ROOT/tests/lib/fwlive-forwarding-slo-report.mjs" \
	"$RECORDS" "$REPORT_FILE" "$ADAPTIVE" "$PAIRS" "$DURATION" "$PING_COUNT" \
	"$BITRATE" "$ENFORCE" "$RUN_STARTED_AT"
