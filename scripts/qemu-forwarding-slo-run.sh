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
#   ./scripts/qemu-forwarding-slo-run.sh --adaptive on --bitrate 80G --streams 4
#   ./scripts/qemu-forwarding-slo-run.sh --adaptive off --pairs 5 --duration 10
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
USER="${OPENWRT_USER:-root}"
KNOWN_HOSTS="${FWLIVE_KNOWN_HOSTS:-${ROOT}/lab/qemu-known_hosts}"
IPERF3="${FWLIVE_SLO_IPERF3:-}"
BITRATE="${FWLIVE_SLO_IPERF_BITRATE:-}"
STREAMS="${FWLIVE_SLO_IPERF_STREAMS:-1}"
DURATION="${FWLIVE_SLO_IPERF_DURATION:-10}"
PING_COUNT="${FWLIVE_SLO_PING_COUNT:-20}"
PING_INTERVAL="${FWLIVE_SLO_PING_INTERVAL_S:-}"
PAIRS="${FWLIVE_SLO_PAIRS:-5}"
DRAIN_MS="${FWLIVE_SLO_DRAIN_MS:-3000}"
REPORT_FILE="${FWLIVE_SLO_REPORT_FILE:-}"
LAN_NS="${FWLIVE_SLO_LAN_NETNS:-fwlive-slo-lan}"
WAN_NS="${FWLIVE_SLO_WAN_NETNS:-fwlive-slo-wan}"
LAN_ENDPOINT_IP="${FWLIVE_SLO_LAN_ENDPOINT_IP:-192.0.2.2}"
WAN_ENDPOINT_IP="${FWLIVE_SLO_WAN_ENDPOINT_IP:-198.51.100.2}"
LAN_MAC="${FWLIVE_SLO_LAN_MAC:-52:54:00:30:77:01}"
WAN_MAC="${FWLIVE_SLO_WAN_MAC:-52:54:00:30:77:02}"
LAN_TAP="${FWLIVE_SLO_LAN_TAP:-fwlive-slo-lan-tap}"
WAN_TAP="${FWLIVE_SLO_WAN_TAP:-fwlive-slo-wan-tap}"
CONSOLE_LOG="${OWRT_CONSOLE_LOG:-}"
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
		--streams) STREAMS="${2:-}"; shift 2 ;;
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
for value in "$PAIRS" "$DURATION" "$PING_COUNT" "$DRAIN_MS" "$STREAMS"; do
	case "$value" in ''|*[!0-9]*) die "numeric options must be decimal integers" ;; esac
done
(( PAIRS > 0 )) || die "pairs must be greater than zero"
(( DURATION > 0 )) || die "duration must be greater than zero"
(( PING_COUNT > 0 )) || die "ping count must be greater than zero"
(( DRAIN_MS > 0 )) || die "drain-ms must be greater than zero"
[[ "$STREAMS" =~ ^[1-9][0-9]?$ ]] || die "streams must be an integer from 1 through 64"
(( STREAMS >= 1 && STREAMS <= 64 )) || die "streams must be from 1 through 64"
if [[ -n "$BITRATE" ]] && [[ ! "$BITRATE" =~ ^[0-9]+([.][0-9]+)?([KMGkmg])?$ ]]; then
	die "bitrate must be a decimal aggregate bit rate with optional K, M, or G suffix"
fi
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
RUN_METADATA="$WORK/run-metadata.json"
VIEWER_PID=""
CURRENT_VIEWER_DIR=""

cleanup() {
	local status=$?
	trap - EXIT HUP INT TERM
	if [[ -n "$VIEWER_PID" ]]; then
		kill "$VIEWER_PID" 2>/dev/null || true
		wait "$VIEWER_PID" 2>/dev/null || true
		VIEWER_PID=""
	fi
	if [[ -n "$ORIGINAL_ADAPTIVE_OFF_STATE" ]]; then
		if ! restore_adaptive_state; then
			echo "forwarding-slo-run: failed to restore adaptive sentinel state" >&2
			(( status == 0 )) && status=1
		fi
	fi
	if ! rm -rf "$WORK"; then
		echo "forwarding-slo-run: failed to remove temporary work directory: $WORK" >&2
		(( status == 0 )) && status=1
	fi
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

node - "$RUN_METADATA" "$ROOT" "$BITRATE" "$STREAMS" "$LAN_NS" "$WAN_NS" \
	"$LAN_ENDPOINT_IP" "$WAN_ENDPOINT_IP" "$LAN_MAC" "$WAN_MAC" "$LAN_TAP" "$WAN_TAP" \
	"$CONSOLE_LOG" <<'NODE'
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const [file, root, bitrate, streams, lanNs, wanNs, lanIp, wanIp, lanMac, wanMac, lanTap, wanTap, consoleLog] = process.argv.slice(2);
const git = (args) => {
	try { return execFileSync('git', args, { cwd: root, encoding: 'utf8' }).trim(); }
	catch (_) { return null; }
};
const names = [
	'OWRT_QEMU_SMP', 'OWRT_QEMU_MEM', 'OWRT_QEMU_DISK_FORMAT',
	'FWLIVE_SLO_QEMU_NET_MODEL', 'FWLIVE_SLO_QEMU_VHOST', 'FWLIVE_SLO_QEMU_QUEUES',
	'FWLIVE_SLO_LOG_RATE', 'FWLIVE_SLO_CONSOLE_LEVEL'
];
const metadata = {
	source: { revision: git(['rev-parse', 'HEAD']), dirty: !!git(['status', '--porcelain']) },
	launcher_selection: Object.fromEntries(names.map((name) => [name, process.env[name] ?? null])),
	traffic_configuration: {
		bitrate_input: bitrate || 'unlimited',
		bitrate_semantics: 'aggregate across all TCP streams; per-stream -b is aggregate divided by stream count',
		streams: Number(streams),
		lan_namespace: lanNs,
		wan_namespace: wanNs,
		lan_endpoint_ip: lanIp,
		wan_endpoint_ip: wanIp,
		lan_mac: lanMac,
		wan_mac: wanMac,
		lan_tap: lanTap,
		wan_tap: wanTap,
		console_log_path: consoleLog || null
	}
};
fs.writeFileSync(file, `${JSON.stringify(metadata)}\n`, { mode: 0o600 });
NODE

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
	local pair=$1 mode=$2 sample_file=$3 viewer_file=$4 telemetry_file=$5
	node - "$RECORDS" "$pair" "$ADAPTIVE" "$mode" \
		"$viewer_file" "$DRAIN_MS" "$sample_file" "$telemetry_file" "$RUN_METADATA" <<'NODE'
const fs = require('node:fs');
const [file, pair, adaptive, mode, viewerFile, drainMs, sampleFile, telemetryFile, metadataFile] = process.argv.slice(2);
const viewer = viewerFile === '-'
	? { viewer: 'none', polls_in_window: 0, poll_responses: [], requests: {}, in_flight_after_drain: 0 }
	: JSON.parse(fs.readFileSync(viewerFile, 'utf8'));
const lines = fs.readFileSync(sampleFile, 'utf8').split(/\r?\n/);
const metricLine = lines.find((line) => line.startsWith('SLO_SAMPLE '));
if (!metricLine) throw new Error(`traffic probe has no SLO_SAMPLE row: ${sampleFile}`);
const fields = Object.fromEntries([...metricLine.matchAll(/([a-z0-9_]+)=([^\s]*)/g)].map((match) => [match[1], match[2]]));
const numberOrNull = (value) => value === undefined || value === 'unknown' || value === 'unlimited' ? null : Number(value);
const artifacts = {};
for (const line of lines) {
	const match = /^SLO_ARTIFACT name=([A-Za-z0-9._-]+) data_b64=([A-Za-z0-9+/=]*)$/.exec(line);
	if (match) artifacts[match[1]] = Buffer.from(match[2], 'base64').toString('utf8');
}
const requiredArtifacts = ['iperf-client.json', 'iperf-server.json', 'ping.txt'];
if (requiredArtifacts.some((name) => typeof artifacts[name] !== 'string'))
	throw new Error(`traffic probe omitted raw iperf/ping artifacts: ${sampleFile}`);
const telemetry = JSON.parse(fs.readFileSync(telemetryFile, 'utf8'));
const metadata = JSON.parse(fs.readFileSync(metadataFile, 'utf8'));
const traffic = {
	status: fields.status,
	reason: fields.reason,
	label: fields.label,
	duration_s: Number(fields.duration_s),
	ping_count: Number(fields.ping_count),
	bitrate_input: fields.bitrate,
	aggregate_bitrate_bps: numberOrNull(fields.aggregate_bitrate_bps),
	per_stream_bitrate_bps: numberOrNull(fields.per_stream_bitrate_bps),
	streams: Number(fields.streams),
	observed_streams: numberOrNull(fields.observed_streams),
	effective_aggregate_bitrate_bps: numberOrNull(fields.effective_aggregate_bitrate_bps),
	throughput_bps: numberOrNull(fields.throughput_bps),
	retransmits: numberOrNull(fields.retransmits),
	ping_loss_pct: numberOrNull(fields.ping_loss_pct),
	ping_rtt_stddev_ms: numberOrNull(fields.ping_rtt_stddev_ms),
	generator_cpu_pct: numberOrNull(fields.generator_cpu_pct),
	generator_cpu_affinity: fields.generator_cpu_affinity === 'unknown' ? null : fields.generator_cpu_affinity
};
const row = {
	pair: Number(pair),
	adaptive,
	mode,
	throughput_bps: traffic.throughput_bps,
	ping_rtt_stddev_ms: traffic.ping_rtt_stddev_ms,
	drain_ms: Number(drainMs),
	traffic,
	telemetry,
	raw: artifacts,
	viewer,
	metadata
};
fs.appendFileSync(file, `${JSON.stringify(row)}\n`);
console.log(`SLO_PAIR pair=${pair} adaptive=${adaptive} mode=${mode} traffic=${traffic.status} throughput_bps=${traffic.throughput_bps ?? 'unknown'} ping_rtt_stddev_ms=${traffic.ping_rtt_stddev_ms ?? 'unknown'} streams=${traffic.streams} retransmits=${traffic.retransmits ?? 'unknown'} generator_cpu_pct=${traffic.generator_cpu_pct ?? 'unknown'} viewer_polls=${viewer.polls_in_window}`);
NODE
}

run_traffic() {
	local label=$1 output=$2 telemetry_dir=$3 start_marker=${4:-} stop_marker=${5:-}
	mkdir -p "$telemetry_dir"
	chmod 700 "$telemetry_dir"
	collect_snapshots "$telemetry_dir/host-before.txt" "$telemetry_dir/guest-before.txt"
	sudo env \
		FWLIVE_SLO_IPERF3="$IPERF3" \
		FWLIVE_SLO_IPERF_BITRATE="$BITRATE" \
		FWLIVE_SLO_IPERF_STREAMS="$STREAMS" \
		FWLIVE_SLO_IPERF_DURATION="$DURATION" \
		FWLIVE_SLO_PING_COUNT="$PING_COUNT" \
		FWLIVE_SLO_PING_INTERVAL_S="$PING_INTERVAL" \
		FWLIVE_SLO_LAN_NETNS="$LAN_NS" \
		FWLIVE_SLO_WAN_NETNS="$WAN_NS" \
		FWLIVE_SLO_LAN_ENDPOINT_IP="$LAN_ENDPOINT_IP" \
		FWLIVE_SLO_WAN_ENDPOINT_IP="$WAN_ENDPOINT_IP" \
		FWLIVE_SLO_TRAFFIC_START_FILE="$start_marker" \
		FWLIVE_SLO_TRAFFIC_STOP_FILE="$stop_marker" \
		"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" --label "$label" |
		tee "$output" >/dev/null
	collect_snapshots "$telemetry_dir/host-after.txt" "$telemetry_dir/guest-after.txt"
	node "$ROOT/tests/lib/fwlive-forwarding-slo-telemetry.mjs" \
		"$telemetry_dir/host-before.txt" "$telemetry_dir/guest-before.txt" \
		"$telemetry_dir/host-after.txt" "$telemetry_dir/guest-after.txt" >"$telemetry_dir/telemetry.json"
}

collect_snapshots() {
	local host_file=$1 guest_file=$2
	# Host snapshot files are written by this user's redirect; sudo only grants
	# read access to /proc and the optionally selected console capture.
	# shellcheck disable=SC2024
	sudo "$ROOT/scripts/qemu-forwarding-slo-snapshot.sh" host \
		"$LAN_TAP" "$WAN_TAP" "$CONSOLE_LOG" >"$host_file"
	ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" sh -s -- guest "$LAN_MAC" "$WAN_MAC" \
		<"$ROOT/scripts/qemu-forwarding-slo-snapshot.sh" >"$guest_file"
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
	baseline_telemetry="$WORK/pair-${pair}-no-viewer-telemetry"
	run_traffic "adaptive-${ADAPTIVE}-pair-${pair}-no-viewer" "$baseline" "$baseline_telemetry"
	record_sample "$pair" no-viewer "$baseline" - "$baseline_telemetry/telemetry.json"

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
	active_telemetry="$CURRENT_VIEWER_DIR/telemetry"
	if ! run_traffic "adaptive-${ADAPTIVE}-pair-${pair}-active-viewer" "$active" "$active_telemetry" "$start" "$stop"; then
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
	record_sample "$pair" active-viewer "$active" "$viewer_result" "$active_telemetry/telemetry.json"
done

node "$ROOT/tests/lib/fwlive-forwarding-slo-report.mjs" \
	"$RECORDS" "$REPORT_FILE" "$ADAPTIVE" "$PAIRS" "$DURATION" "$PING_COUNT" \
	"$BITRATE" "$STREAMS" "$ENFORCE" "$RUN_STARTED_AT" "$RUN_METADATA"
