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
PAIRS="${FWLIVE_SLO_PAIRS:-5}"
DRAIN_MS="${FWLIVE_SLO_DRAIN_MS:-3000}"
REPORT_FILE="${FWLIVE_SLO_REPORT_FILE:-}"
ADAPTIVE=""
ENFORCE=0

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fwlive-slo-run.XXXXXX")"
RECORDS="$WORK/records.jsonl"
VIEWER_PID=""
CURRENT_VIEWER_DIR=""

cleanup() {
	if [[ -n "$VIEWER_PID" ]]; then
		kill "$VIEWER_PID" 2>/dev/null || true
		wait "$VIEWER_PID" 2>/dev/null || true
		VIEWER_PID=""
	fi
	if [[ "$ADAPTIVE" = off ]]; then
		ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" 'rm -f /var/run/fwlive-adaptive-off' 2>/dev/null || true
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
	local label=$1 output=$2
	sudo env \
		FWLIVE_SLO_IPERF3="$IPERF3" \
		FWLIVE_SLO_IPERF_BITRATE="$BITRATE" \
		FWLIVE_SLO_IPERF_DURATION="$DURATION" \
		FWLIVE_SLO_PING_COUNT="$PING_COUNT" \
		"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" --label "$label" |
		tee "$output" >/dev/null
}

set_adaptive "$ADAPTIVE"
for (( pair = 1; pair <= PAIRS; pair++ )); do
	# The active viewer from the preceding pair has closed and drained before
	# this wait. Keep the no-viewer baseline free of an intentional poll burst.
	sleep "$((DRAIN_MS / 1000)).$((DRAIN_MS % 1000))"
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
	touch "$start"
	active="$CURRENT_VIEWER_DIR/active-viewer.out"
	if ! run_traffic "adaptive-${ADAPTIVE}-pair-${pair}-active-viewer" "$active"; then
		touch "$stop"
		wait "$VIEWER_PID" 2>/dev/null || true
		VIEWER_PID=""
		cat "$active" "$viewer_log" >&2 || true
		die "active-viewer traffic failed for pair $pair"
	fi
	touch "$stop"
	if ! wait "$VIEWER_PID"; then
		cat "$viewer_log" >&2 || true
		VIEWER_PID=""
		die "active viewer failed for pair $pair"
	fi
	VIEWER_PID=""
	[[ -s "$viewer_result" ]] || die "active viewer produced no result for pair $pair"
	record_sample "$pair" active-viewer "$active" "$viewer_result"
done

node - "$RECORDS" "$REPORT_FILE" "$ADAPTIVE" "$PAIRS" "$DURATION" "$PING_COUNT" "$BITRATE" "$ENFORCE" <<'NODE'
const fs = require('node:fs');
const [recordsFile, reportFile, adaptive, expectedPairs, duration, pingCount, bitrate, enforce] = process.argv.slice(2);
const records = fs.readFileSync(recordsFile, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
const median = (values) => {
	if (!values.length) return null;
	const sorted = values.slice().sort((a, b) => a - b);
	return sorted[Math.floor((sorted.length - 1) / 2)];
};
const stats = (values) => values.length ? {
	count: values.length,
	median: median(values),
	min: Math.min(...values),
	max: Math.max(...values),
	spread: Math.max(...values) - Math.min(...values)
} : { count: 0, median: null, min: null, max: null, spread: null };
const pairs = [];
for (let pair = 1; pair <= Number(expectedPairs); pair++) {
	const rows = records.filter((row) => row.pair === pair);
	const baseline = rows.find((row) => row.mode === 'no-viewer');
	const active = rows.find((row) => row.mode === 'active-viewer');
	if (!baseline || !active) {
		pairs.push({ pair, complete: false, rows });
		continue;
	}
	pairs.push({
		pair,
		complete: true,
		throughput_degradation_pct: (1 - active.throughput_bps / baseline.throughput_bps) * 100,
		ping_stddev_ratio: baseline.ping_rtt_stddev_ms === 0
			? null
			: active.ping_rtt_stddev_ms / baseline.ping_rtt_stddev_ms
	});
}
const baselines = records.filter((row) => row.mode === 'no-viewer');
const actives = records.filter((row) => row.mode === 'active-viewer');
const degradation = pairs.filter((row) => row.complete).map((row) => row.throughput_degradation_pct);
const ratios = pairs.filter((row) => row.complete && row.ping_stddev_ratio !== null).map((row) => row.ping_stddev_ratio);
const report = {
	issue: 306,
	child_issue: 344,
	adaptive,
	configuration: {
		pairs_requested: Number(expectedPairs),
		duration_s: Number(duration),
		ping_count: Number(pingCount),
		iperf_bitrate: bitrate || 'unlimited',
		viewer_baseline: 'no-viewer',
		viewer_comparison: 'active-viewer',
		traffic: 'iperf3 receive throughput plus routed ping RTT standard deviation'
	},
	acceptance: {
		all_pairs_complete: pairs.length === Number(expectedPairs) && pairs.every((row) => row.complete),
		active_viewer_poll_observed: actives.length === Number(expectedPairs) && actives.every((row) => row.viewer.polls_in_window > 0),
		viewer_requests_drained: actives.length === Number(expectedPairs) && actives.every((row) => row.viewer.in_flight_after_drain === 0),
		median_throughput_degradation_lt_10_pct: median(degradation) !== null && median(degradation) < 10,
		median_ping_stddev_ratio_lt_2: median(ratios) !== null && median(ratios) < 2
	},
	throughput_degradation_pct: stats(degradation),
	ping_stddev_ratio: stats(ratios),
	throughput_bps: {
		no_viewer: stats(baselines.map((row) => row.throughput_bps)),
		active_viewer: stats(actives.map((row) => row.throughput_bps))
	},
	ping_rtt_stddev_ms: {
		no_viewer: stats(baselines.map((row) => row.ping_rtt_stddev_ms)),
		active_viewer: stats(actives.map((row) => row.ping_rtt_stddev_ms))
	},
	pairs,
	samples: records,
	started_at: new Date().toISOString()
};
report.pass = Object.values(report.acceptance).every(Boolean);
const serialized = JSON.stringify(report, null, 2);
if (reportFile) fs.writeFileSync(reportFile, `${serialized}\n`, { mode: 0o600 });
console.log(serialized);
if (enforce === '1' && !report.pass) process.exit(1);
NODE
