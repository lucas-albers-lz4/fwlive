#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Run one routed forwarding-SLO traffic sample through the two endpoint
# namespaces. The caller supplies the viewer mode/label; this command does
# not open LuCI or infer whether a viewer is active.
#
# Usage:
#   sudo ./scripts/qemu-forwarding-slo-traffic.sh --label no-viewer
#   sudo ./scripts/qemu-forwarding-slo-traffic.sh --label no-viewer --bitrate 1G
#   sudo ./scripts/qemu-forwarding-slo-traffic.sh --label no-viewer --bitrate 80G --streams 4
#   sudo FWLIVE_SLO_IPERF3=/home/linuxbrew/.linuxbrew/bin/iperf3 \
#     ./scripts/qemu-forwarding-slo-traffic.sh --label active-viewer
set -euo pipefail

LAN_NS="${FWLIVE_SLO_LAN_NETNS:-fwlive-slo-lan}"
WAN_NS="${FWLIVE_SLO_WAN_NETNS:-fwlive-slo-wan}"
LAN_IP="${FWLIVE_SLO_LAN_ENDPOINT_IP:-192.0.2.2}"
WAN_IP="${FWLIVE_SLO_WAN_ENDPOINT_IP:-198.51.100.2}"
IPERF3="${FWLIVE_SLO_IPERF3:-}"
BITRATE="${FWLIVE_SLO_IPERF_BITRATE:-}"
STREAMS="${FWLIVE_SLO_IPERF_STREAMS:-1}"
DURATION="${FWLIVE_SLO_IPERF_DURATION:-10}"
PING_COUNT="${FWLIVE_SLO_PING_COUNT:-20}"
PING_INTERVAL="${FWLIVE_SLO_PING_INTERVAL_S:-}"
START_MARKER="${FWLIVE_SLO_TRAFFIC_START_FILE:-}"
STOP_MARKER="${FWLIVE_SLO_TRAFFIC_STOP_FILE:-}"
LABEL=""

die() { echo "forwarding-slo-traffic: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--label) LABEL="${2:-}"; shift 2 ;;
		--bitrate) BITRATE="${2:-}"; shift 2 ;;
		--streams) STREAMS="${2:-}"; shift 2 ;;
		--duration) DURATION="${2:-}"; shift 2 ;;
		--ping-count) PING_COUNT="${2:-}"; shift 2 ;;
		-h|--help)
			sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*) die "unknown argument: $1" ;;
	esac
done

[[ "$(id -u)" -eq 0 ]] || die "run as root (use sudo; endpoint namespaces are root-owned)"
command -v ip >/dev/null 2>&1 || die "missing required tool: ip"
command -v ping >/dev/null 2>&1 || die "missing required tool: ping"
command -v node >/dev/null 2>&1 || die "missing required tool: node"

[[ -n "$LABEL" ]] || die "--label is required"
case "$LABEL" in
	*[!A-Za-z0-9._-]*) die "label must contain only letters, digits, dot, underscore, or dash" ;;
esac
case "$DURATION" in
	''|*[!0-9]*) die "duration must be a positive integer" ;;
esac
case "$PING_COUNT" in
	''|*[!0-9]*) die "ping count must be a positive integer" ;;
esac
[[ "$STREAMS" =~ ^[1-9][0-9]?$ ]] || die "streams must be an integer from 1 through 64"
(( DURATION > 0 )) || die "duration must be greater than zero"
(( PING_COUNT > 0 )) || die "ping count must be greater than zero"
(( STREAMS >= 1 && STREAMS <= 64 )) || die "streams must be from 1 through 64"
if [[ -n "$BITRATE" ]] && [[ ! "$BITRATE" =~ ^[0-9]+([.][0-9]+)?([KMGkmg])?$ ]]; then
	die "bitrate must be a decimal bit rate with optional K, M, or G suffix"
fi
AGGREGATE_BPS=""
PER_STREAM_BPS=""
if [[ -n "$BITRATE" ]]; then
	AGGREGATE_BPS="$(node -e '
const text = process.argv[1];
const match = /^(\d+(?:\.\d+)?)([KMGkmg])?$/.exec(text);
if (!match) process.exit(2);
const suffix = (match[2] || "").toUpperCase();
const multiplier = suffix ? { K: 1000n, M: 1000000n, G: 1000000000n }[suffix] : 1n;
const parts = match[1].split(".");
const scale = 10n ** BigInt((parts[1] || "").length);
const numerator = BigInt(parts.join("")) * multiplier;
if (numerator % scale !== 0n) process.exit(2);
const bps = numerator / scale;
if (bps < 1n || bps > 1000000000000000n) process.exit(2);
process.stdout.write(String(bps));
' "$BITRATE")" || die "bitrate must resolve to an integer from 1 through 1000000000000000 bits per second"
	PER_STREAM_BPS=$((AGGREGATE_BPS / STREAMS))
	(( PER_STREAM_BPS > 0 )) || die "aggregate bitrate is too small for the requested stream count"
fi
if [[ -z "$PING_INTERVAL" ]]; then
	PING_INTERVAL="$(awk -v duration="$DURATION" -v count="$PING_COUNT" 'BEGIN { printf "%.3f", duration / count }')"
fi
[[ "$PING_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "ping interval must be a positive decimal"
awk -v interval="$PING_INTERVAL" 'BEGIN { exit !(interval > 0) }' || die "ping interval must be greater than zero"
for marker in "$START_MARKER" "$STOP_MARKER"; do
	if [[ -n "$marker" && ( "$marker" == *$'\n'* || "$marker" == *$'\r'* ) ]]; then
		die "traffic marker path contains a newline"
	fi
done
if [[ -n "$START_MARKER" && -n "$STOP_MARKER" && "$START_MARKER" == "$STOP_MARKER" ]]; then
	die "traffic start and stop marker paths must differ"
fi

ip netns list | awk '{print $1}' | grep -Fxq "$LAN_NS" || die "missing LAN namespace: $LAN_NS"
ip netns list | awk '{print $1}' | grep -Fxq "$WAN_NS" || die "missing WAN namespace: $WAN_NS"

if [[ -z "$IPERF3" ]]; then
	for candidate in /usr/bin/iperf3 /usr/local/bin/iperf3 /home/linuxbrew/.linuxbrew/bin/iperf3; do
		if [[ -x "$candidate" ]]; then
			IPERF3="$candidate"
			break
		fi
	done
fi
[[ -x "$IPERF3" ]] || die "iperf3 not found; set FWLIVE_SLO_IPERF3 to its absolute path"

TMP_ROOT="${TMPDIR:-/tmp}"
[[ -d "$TMP_ROOT" ]] || die "temporary directory is missing: $TMP_ROOT"
[[ -O "$TMP_ROOT" || -k "$TMP_ROOT" ]] || die "temporary directory must be owner-controlled or sticky: $TMP_ROOT"
WORK="$(mktemp -d "$TMP_ROOT/fwlive-slo-traffic.XXXXXX")"
chmod 700 "$WORK"
cleanup() {
	if [[ -n "${SERVER_PID:-}" ]]; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
	if [[ -n "${PING_PID:-}" ]]; then
		kill "$PING_PID" 2>/dev/null || true
		wait "$PING_PID" 2>/dev/null || true
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

LC_ALL=C ip netns exec "$WAN_NS" "$IPERF3" -s -1 -J -B "$WAN_IP" \
	>"$WORK/server.out" 2>"$WORK/server.err" &
SERVER_PID=$!
sleep 1

# Keep the ping window inside the 10-second iperf window at the default
# 20-count sample; the standard one-second ping interval would otherwise keep
# the active viewer alive long after throughput measurement ended.
LC_ALL=C ip netns exec "$LAN_NS" ping -I endpoint0 -c "$PING_COUNT" -i "$PING_INTERVAL" -W 1 "$WAN_IP" \
	>"$WORK/ping.out" 2>"$WORK/ping.err" &
PING_PID=$!

if [[ -n "$START_MARKER" ]]; then
	touch "$START_MARKER"
fi

client_args=(-t "$DURATION" -J)
if [[ -n "$BITRATE" ]]; then
	# iperf3 applies -b independently to every parallel stream. Divide the
	# requested aggregate rate so --bitrate remains an aggregate-rate option.
	client_args=(-b "$PER_STREAM_BPS" "${client_args[@]}")
fi
client_args=(-P "$STREAMS" "${client_args[@]}")
TIMEFORMAT='SLO_TIME user_s=%3U sys_s=%3S real_s=%3R'
if ! { time LC_ALL=C ip netns exec "$LAN_NS" "$IPERF3" -c "$WAN_IP" -B "$LAN_IP" \
	"${client_args[@]}" >"$WORK/client.json" 2>"$WORK/client.err"; } 2>"$WORK/client.time"; then
	CLIENT_FAILED=1
	if [[ -n "$STOP_MARKER" ]]; then
		touch "$STOP_MARKER"
	fi
	cat "$WORK/client.err" "$WORK/server.err" "$WORK/ping.err" >&2 || true
else
	CLIENT_FAILED=0
fi
if [[ -n "$STOP_MARKER" ]]; then
	touch "$STOP_MARKER"
fi
wait "$PING_PID" || true
PING_PID=""
wait "$SERVER_PID" || true
SERVER_PID=""

iperf_metrics="$(node -e '
const fs = require("fs");
let client = null;
let server = null;
try { client = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (_) {}
try { server = JSON.parse(fs.readFileSync(process.argv[2], "utf8")); } catch (_) {}
const bps = client?.end?.sum_received?.bits_per_second;
const sent = client?.end?.sum_sent || {};
const serverSent = server?.end?.sum_sent || {};
const retransmits = Number.isFinite(sent.retransmits) ? sent.retransmits
	: Number.isFinite(serverSent.retransmits) ? serverSent.retransmits : null;
process.stdout.write(JSON.stringify({
	throughput_bps: Number.isFinite(bps) && bps > 0 ? bps : null,
	retransmits,
	requested_streams: Number.isInteger(client?.start?.test_start?.num_streams)
		? client.start.test_start.num_streams : null,
	client_json_valid: !!client,
	server_json_valid: !!server
}));
' "$WORK/client.json" "$WORK/server.out")"
throughput_bps="$(node -e 'const n=JSON.parse(process.argv[1]).throughput_bps; process.stdout.write(n === null ? "unknown" : String(n))' "$iperf_metrics")"
retransmits="$(node -e 'const n=JSON.parse(process.argv[1]).retransmits; process.stdout.write(n === null ? "unknown" : String(n))' "$iperf_metrics")"
observed_streams="$(node -e 'const n=JSON.parse(process.argv[1]).requested_streams; process.stdout.write(n === null ? "unknown" : String(n))' "$iperf_metrics")"

ping_stddev_ms="$(awk -F= '/^(rtt|round-trip)/ {
	split($2, values, "/");
	sub(/[[:space:]].*$/, "", values[4]);
    if (values[4] ~ /^[0-9]+([.][0-9]+)?$/) print values[4];
}' "$WORK/ping.out" | tail -1)"
ping_loss_pct="$(sed -n 's/.*,[[:space:]]*\([0-9][0-9.]*\)% packet loss.*/\1/p' "$WORK/ping.out" | tail -1)"
generator_cpu="$(awk '
/^SLO_TIME / {
	for (i = 1; i <= NF; i++) {
		if ($i ~ /^user_s=/) { split($i, a, "="); user = a[2] }
		if ($i ~ /^sys_s=/) { split($i, a, "="); sys = a[2] }
		if ($i ~ /^real_s=/) { split($i, a, "="); real = a[2] }
	}
}
END {
	if (real > 0) printf "%.3f", 100 * (user + sys) / real;
}' "$WORK/client.time")"
[[ "$generator_cpu" =~ ^[0-9]+([.][0-9]+)?$ ]] || generator_cpu="unknown"
generator_affinity="unknown"
if command -v taskset >/dev/null 2>&1; then
	affinity_output="$(taskset -pc "$$" 2>/dev/null || true)"
	affinity_candidate="${affinity_output##*: }"
	[[ "$affinity_candidate" =~ ^[0-9,-]+$ ]] && generator_affinity="$affinity_candidate"
fi

sample_status=valid
sample_reason=none
mark_invalid() {
	sample_status=invalid
	if [[ "$sample_reason" = none ]]; then sample_reason=$1; else sample_reason="${sample_reason},$1"; fi
}
(( CLIENT_FAILED == 0 )) || mark_invalid iperf_client_failed
[[ "$throughput_bps" =~ ^[0-9]+([.][0-9]+)?$ ]] || mark_invalid iperf_receive_rate_missing
[[ "$observed_streams" = "$STREAMS" ]] || mark_invalid iperf_stream_count_mismatch
[[ "$ping_stddev_ms" =~ ^[0-9]+([.][0-9]+)?$ ]] || mark_invalid ping_rtt_stddev_missing
[[ "$ping_loss_pct" =~ ^[0-9]+([.][0-9]+)?$ ]] || mark_invalid ping_loss_missing
[[ "$ping_loss_pct" = 0 || "$ping_loss_pct" = 0.0 || "$ping_loss_pct" = 0.00 ]] || mark_invalid ping_packet_loss

emit_artifact() {
	local name=$1 file=$2 encoded
	[[ -f "$file" ]] || return 0
	encoded="$(node -e 'const fs = require("node:fs"); process.stdout.write(fs.readFileSync(process.argv[1]).toString("base64"))' "$file")"
	printf 'SLO_ARTIFACT name=%s data_b64=%s\n' "$name" "$encoded"
}

effective_aggregate_bps=""
[[ -z "$PER_STREAM_BPS" ]] || effective_aggregate_bps=$((PER_STREAM_BPS * STREAMS))

printf 'SLO_SAMPLE status=%s reason=%s label=%s duration_s=%s ping_count=%s bitrate=%s aggregate_bitrate_bps=%s per_stream_bitrate_bps=%s streams=%s observed_streams=%s effective_aggregate_bitrate_bps=%s throughput_bps=%s retransmits=%s ping_loss_pct=%s ping_rtt_stddev_ms=%s generator_cpu_pct=%s generator_cpu_affinity=%s\n' \
	"$sample_status" "$sample_reason" \
	"$LABEL" "$DURATION" "$PING_COUNT" "${BITRATE:-unlimited}" \
	"${AGGREGATE_BPS:-unlimited}" "${PER_STREAM_BPS:-unlimited}" "$STREAMS" "$observed_streams" \
	"${effective_aggregate_bps:-unlimited}" "$throughput_bps" "$retransmits" \
	"$ping_loss_pct" "$ping_stddev_ms" "$generator_cpu" "$generator_affinity"

emit_artifact iperf-client.json "$WORK/client.json"
emit_artifact iperf-server.json "$WORK/server.out"
emit_artifact ping.txt "$WORK/ping.out"
emit_artifact iperf-client.stderr "$WORK/client.err"
emit_artifact iperf-server.stderr "$WORK/server.err"
emit_artifact ping.stderr "$WORK/ping.err"
emit_artifact iperf-time.txt "$WORK/client.time"
