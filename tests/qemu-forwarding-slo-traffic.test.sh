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
	if [ "${FWLIVE_SLO_TEST_SERVER_WAIT:-0}" = 1 ]; then
		printf '{"server":"started"}\n'
		sleep_pid=''
		stop_server() {
			[ -z "$sleep_pid" ] || kill "$sleep_pid" 2>/dev/null || true
			[ -z "$sleep_pid" ] || wait "$sleep_pid" 2>/dev/null || true
			printf stopped >"$FWLIVE_SLO_TEST_SERVER_STOP_FILE"
			exit 0
		}
		trap stop_server TERM INT
		while :; do /bin/sleep 30 & sleep_pid=$!; wait "$sleep_pid"; sleep_pid=''; done
	fi
	printf '{"end":{"sum_sent":{"retransmits":5}}}\n'
	exit 0
fi
printf '%s\n' "$*" >"$FWLIVE_SLO_TEST_ARGS_FILE"
if [ "${FWLIVE_SLO_TEST_CLIENT_FAIL:-0}" = 1 ]; then
	echo 'iperf3 client stub: connection failed' >&2
	exit 1
fi
streams=1
rate=0
previous=
for arg in "$@"; do
	if [ "$previous" = -P ]; then streams=$arg; fi
	if [ "$previous" = -b ]; then rate=$arg; fi
	previous=$arg
done
connected_count=$streams
completed_count=$streams
[ "${FWLIVE_SLO_TEST_STREAM_MISMATCH:-0}" != 1 ] || connected_count=$((streams - 1))
make_rows() {
	count=$1
	rows=''
	i=0
	while [ "$i" -lt "$count" ]; do
		[ -z "$rows" ] || rows="$rows,"
		rows="${rows}{\"socket\":$((i + 3))}"
		i=$((i + 1))
	done
	printf '[%s]' "$rows"
}
if [ "${FWLIVE_SLO_TEST_UNKNOWN_STREAMS:-0}" = 1 ]; then
	printf '{"start":{"test_start":{"num_streams":%s}},"end":{"sum_received":{"bits_per_second":80000000000},"sum_sent":{"retransmits":7}}}\n' "$streams"
else
	connected=$(make_rows "$connected_count")
	completed=$(make_rows "$completed_count")
	printf '{"start":{"connected":%s,"test_start":{"num_streams":%s}},"end":{"streams":%s,"sum_received":{"bits_per_second":80000000000},"sum_sent":{"retransmits":7}}}\n' "$connected" "$streams" "$completed"
fi
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
capture_invalid_sample() {
	output_file=$1
	shift
	if "$@" >"$output_file" 2>"$output_file.stderr"; then
		echo 'traffic helper unexpectedly accepted an invalid sample' >&2
		exit 1
	fi
}
output="$(env "${common_env[@]}" "$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	--label stream-test --bitrate 80G --streams 4 --duration 1 --ping-count 4)"
grep -q 'aggregate_bitrate_bps=80000000000 per_stream_bitrate_bps=20000000000 streams=4 requested_streams=4 observed_streams=4 connected_streams=4 completed_streams=4 stream_evidence_mismatch=0 effective_aggregate_bitrate_bps=80000000000' <<<"$output" || {
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
grep -q 'aggregate_bitrate_bps=100000000 per_stream_bitrate_bps=33333333 streams=3 requested_streams=3 observed_streams=3 connected_streams=3 completed_streams=3 stream_evidence_mismatch=0 effective_aggregate_bitrate_bps=99999999' <<<"$rounded_output" || {
	echo 'non-divisible aggregate rate was not accurately reported' >&2
	exit 1
}

if env "${common_env[@]}" "$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	--label invalid-stream --streams 65 >/dev/null 2>&1; then
	echo 'stream count over the supported bound was accepted' >&2
	exit 1
fi

capture_invalid_sample "$WORK/mismatch-output" env "${common_env[@]}" FWLIVE_SLO_TEST_STREAM_MISMATCH=1 \
	"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	--label stream-mismatch --streams 4 --duration 1 --ping-count 4
mismatch_output="$(cat "$WORK/mismatch-output")"
grep -q 'SLO_SAMPLE status=invalid .*reason=iperf_observed_stream_count_unknown,iperf_stream_evidence_mismatch' <<<"$mismatch_output" || {
	echo 'observed stream disagreement did not invalidate the sample' >&2
	exit 1
}

capture_invalid_sample "$WORK/unknown-streams-output" env "${common_env[@]}" FWLIVE_SLO_TEST_UNKNOWN_STREAMS=1 \
	"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	--label unknown-streams --streams 4 --duration 1 --ping-count 4
unknown_streams_output="$(cat "$WORK/unknown-streams-output")"
grep -q 'SLO_SAMPLE status=invalid .*reason=iperf_observed_stream_count_unknown' <<<"$unknown_streams_output" || {
	echo 'unknown actual stream count did not invalidate the sample' >&2
	exit 1
}

capture_invalid_sample "$WORK/invalid-output" env "${common_env[@]}" FWLIVE_SLO_TEST_PING_LOSS=25 \
	"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	--label invalid-traffic --bitrate 100M --streams 2 --duration 1 --ping-count 4
invalid_output="$(cat "$WORK/invalid-output")"
grep -q 'SLO_SAMPLE status=invalid reason=ping_packet_loss' <<<"$invalid_output" || {
	echo 'ping loss did not invalidate the traffic sample' >&2
	exit 1
}
grep -q '^SLO_ARTIFACT name=ping.txt data_b64=' <<<"$invalid_output" || {
	echo 'raw ping output was not retained for an invalid sample' >&2
	exit 1
}

server_stopped="$WORK/server-stopped"
fail_started="$(date +%s%N)"
capture_invalid_sample "$WORK/failed-client-output" timeout 8s env "${common_env[@]}" \
	FWLIVE_SLO_TEST_SERVER_WAIT=1 FWLIVE_SLO_TEST_CLIENT_FAIL=1 \
	FWLIVE_SLO_TEST_SERVER_STOP_FILE="$server_stopped" \
	"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	--label failed-client --duration 1 --ping-count 4
failed_client_output="$(cat "$WORK/failed-client-output")"
fail_elapsed_ms=$(( ($(date +%s%N) - fail_started) / 1000000 ))
grep -q 'SLO_SAMPLE status=invalid .*iperf_client_failed' <<<"$failed_client_output" || {
	echo 'failed client did not produce an invalid sample' >&2
	exit 1
}
grep -q '^SLO_ARTIFACT name=iperf-server.json data_b64=' <<<"$failed_client_output" || {
	echo 'failed client sample did not retain server raw output' >&2
	exit 1
}
grep -q '^SLO_ARTIFACT name=iperf-client.stderr data_b64=' <<<"$failed_client_output" || {
	echo 'failed client sample did not retain client error output' >&2
	exit 1
}
grep -q '^SLO_ARTIFACT name=ping.txt data_b64=' <<<"$failed_client_output" || {
	echo 'failed client sample did not retain ping raw output' >&2
	exit 1
}
[[ -s "$server_stopped" ]] || {
	echo 'failed client did not terminate its waiting iperf server' >&2
	exit 1
}
(( fail_elapsed_ms <= 3000 )) || {
	echo "failed client cleanup was not prompt (${fail_elapsed_ms}ms)" >&2
	exit 1
}

if env "${common_env[@]}" FWLIVE_SLO_TEST_PING_LOSS=25 \
	"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	--label direct-invalid-status --duration 1 --ping-count 4 >/dev/null 2>&1; then
	echo 'standalone traffic helper returned success for an invalid sample' >&2
	exit 1
fi

echo 'qemu forwarding SLO traffic tests passed'
