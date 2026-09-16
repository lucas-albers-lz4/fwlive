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
#   sudo FWLIVE_SLO_IPERF3=/home/linuxbrew/.linuxbrew/bin/iperf3 \
#     ./scripts/qemu-forwarding-slo-traffic.sh --label active-viewer
set -euo pipefail

LAN_NS="${FWLIVE_SLO_LAN_NETNS:-fwlive-slo-lan}"
WAN_NS="${FWLIVE_SLO_WAN_NETNS:-fwlive-slo-wan}"
LAN_IP="${FWLIVE_SLO_LAN_ENDPOINT_IP:-192.0.2.2}"
WAN_IP="${FWLIVE_SLO_WAN_ENDPOINT_IP:-198.51.100.2}"
IPERF3="${FWLIVE_SLO_IPERF3:-}"
BITRATE="${FWLIVE_SLO_IPERF_BITRATE:-}"
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
(( DURATION > 0 )) || die "duration must be greater than zero"
(( PING_COUNT > 0 )) || die "ping count must be greater than zero"
if [[ -n "$BITRATE" ]] && [[ ! "$BITRATE" =~ ^[0-9]+([.][0-9]+)?([KMGkmg])?$ ]]; then
	die "bitrate must be a decimal bit rate with optional K, M, or G suffix"
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

LC_ALL=C ip netns exec "$WAN_NS" "$IPERF3" -s -1 -B "$WAN_IP" \
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
	client_args=(-b "$BITRATE" "${client_args[@]}")
fi
if ! LC_ALL=C ip netns exec "$LAN_NS" "$IPERF3" -c "$WAN_IP" -B "$LAN_IP" \
	"${client_args[@]}" >"$WORK/client.json" 2>"$WORK/client.err"; then
	if [[ -n "$STOP_MARKER" ]]; then
		touch "$STOP_MARKER"
	fi
	cat "$WORK/client.err" "$WORK/server.err" "$WORK/ping.err" >&2 || true
	die "iperf3 client failed"
fi
if [[ -n "$STOP_MARKER" ]]; then
	touch "$STOP_MARKER"
fi
wait "$PING_PID" || true
PING_PID=""
wait "$SERVER_PID" || true
SERVER_PID=""

[[ -s "$WORK/client.json" ]] || die "iperf3 produced no JSON"
throughput_bps="$(node -e '
const fs = require("fs");
const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const bps = r?.end?.sum_received?.bits_per_second;
if (!Number.isFinite(bps) || bps <= 0) process.exit(1);
process.stdout.write(String(bps));
' "$WORK/client.json")" || die "iperf3 JSON has no positive receive rate"

ping_stddev_ms="$(awk -F= '/^(rtt|round-trip)/ {
	split($2, values, "/");
	sub(/[[:space:]].*$/, "", values[4]);
	if (values[4] ~ /^[0-9]+([.][0-9]+)?$/) print values[4];
}' "$WORK/ping.out" | tail -1)"
[[ "$ping_stddev_ms" =~ ^[0-9]+([.][0-9]+)?$ ]] \
	|| die "ping output has no RTT standard deviation"
grep -Eq ',[[:space:]]*0% packet loss' "$WORK/ping.out" \
	|| die "ping sample lost one or more packets"

printf 'SLO_SAMPLE label=%s duration_s=%s ping_count=%s bitrate=%s throughput_bps=%s ping_rtt_stddev_ms=%s\n' \
	"$LABEL" "$DURATION" "$PING_COUNT" "${BITRATE:-unlimited}" "$throughput_bps" "$ping_stddev_ms"
