#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fwlive-slo-traffic-test.XXXXXX")"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
BIN="$WORK/bin"
mkdir "$BIN"

cat >"$BIN/id" <<'STUB'
#!/bin/sh
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
STUB
cat >"$BIN/ip" <<'STUB'
#!/bin/sh
if [ "${1:-}" = netns ] && [ "${2:-}" = list ]; then
	printf '%s\n' "${FWLIVE_SLO_LAN_NETNS:-fwlive-slo-lan}" "${FWLIVE_SLO_WAN_NETNS:-fwlive-slo-wan}"
	exit 0
fi
if [ "${1:-}" = netns ] && [ "${2:-}" = exec ]; then
	shift 3
	exec "$@"
fi
echo "unexpected ip invocation: $*" >&2
exit 2
STUB
cat >"$BIN/ping" <<'STUB'
#!/bin/sh
printf 'PING 198.51.100.2 (198.51.100.2): 56 data bytes\n'
loss=${FWLIVE_SLO_TEST_PING_LOSS:-0}
received=4
[ "$loss" = 0 ] || received=3
printf '4 packets transmitted, %s received, %s%% packet loss, time 3ms\n' "$received" "$loss"
printf 'rtt min/avg/max/mdev = 0.1/0.2/0.3/0.05 ms\n'
STUB
cat >"$BIN/iperf3" <<'STUB'
#!/bin/sh
if [ "${1:-}" = --version ]; then
	echo 'iperf 3 test stub'
	exit 0
fi
if [ "${1:-}" = -s ]; then
	printf '{"end":{"sum_sent":{"retransmits":5}}}\n'
	exit 0
fi
printf '%s\n' "$*" >"$FWLIVE_SLO_TEST_ARGS_FILE"
streams=1
rate=0
previous=
for arg in "$@"; do
	if [ "$previous" = -P ]; then streams=$arg; fi
	if [ "$previous" = -b ]; then rate=$arg; fi
	previous=$arg
done
printf '{"start":{"test_start":{"num_streams":%s}},"end":{"sum_received":{"bits_per_second":80000000000},"sum_sent":{"retransmits":7}}}\n' "$streams"
STUB
cat >"$BIN/sleep" <<'STUB'
exit 0
STUB
chmod +x "$BIN"/*

common_env=(
	"PATH=$BIN:/usr/bin:/bin"
	"TMPDIR=$WORK"
	"FWLIVE_SLO_IPERF3=$BIN/iperf3"
	"FWLIVE_SLO_LAN_NETNS=fwlive-slo-lan"
	"FWLIVE_SLO_WAN_NETNS=fwlive-slo-wan"
	"FWLIVE_SLO_TEST_ARGS_FILE=$WORK/iperf-args"
)
output="$(env "${common_env[@]}" "$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	--label stream-test --bitrate 80G --streams 4 --duration 1 --ping-count 4)"
grep -q 'aggregate_bitrate_bps=80000000000 per_stream_bitrate_bps=20000000000 streams=4 observed_streams=4 effective_aggregate_bitrate_bps=80000000000' <<<"$output" || {
	echo "aggregate bitrate/stream output is incorrect: $output" >&2
	exit 1
}
grep -q 'retransmits=7 ping_loss_pct=0' <<<"$output" || {
	echo "retransmit/ping-loss output is missing: $output" >&2
	exit 1
}
grep -q -- '-P 4 -b 20000000000' "$WORK/iperf-args" || {
	echo 'iperf3 did not receive the divided per-stream bitrate' >&2
	exit 1
}
grep -q '^SLO_ARTIFACT name=iperf-client.json data_b64=' <<<"$output" || {
	echo 'raw iperf client output was not retained' >&2
	exit 1
}

rounded_output="$(env "${common_env[@]}" "$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	--label rounding-test --bitrate 100M --streams 3 --duration 1 --ping-count 4)"
grep -q 'aggregate_bitrate_bps=100000000 per_stream_bitrate_bps=33333333 streams=3 observed_streams=3 effective_aggregate_bitrate_bps=99999999' <<<"$rounded_output" || {
	echo 'non-divisible aggregate rate was not accurately reported' >&2
	exit 1
}

if env "${common_env[@]}" "$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	--label invalid-stream --streams 65 >/dev/null 2>&1; then
	echo 'stream count over the supported bound was accepted' >&2
	exit 1
fi

invalid_output="$(env "${common_env[@]}" FWLIVE_SLO_TEST_PING_LOSS=25 \
	"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	--label invalid-traffic --bitrate 100M --streams 2 --duration 1 --ping-count 4)"
grep -q 'SLO_SAMPLE status=invalid reason=ping_packet_loss' <<<"$invalid_output" || {
	echo 'ping loss did not invalidate the traffic sample' >&2
	exit 1
}
grep -q '^SLO_ARTIFACT name=ping.txt data_b64=' <<<"$invalid_output" || {
	echo 'raw ping output was not retained for an invalid sample' >&2
	exit 1
}

echo 'qemu forwarding SLO traffic tests passed'
