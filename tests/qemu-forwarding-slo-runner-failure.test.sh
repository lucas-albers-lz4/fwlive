#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fwlive-slo-runner-failure-test.XXXXXX")"
chmod 700 "$TEST_ROOT"
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM
BIN="$TEST_ROOT/bin"
SCRATCH="$TEST_ROOT/scratch"
mkdir -m 700 "$BIN" "$SCRATCH"
REAL_NODE="$(command -v node)"
SNAPSHOT_COUNT="$TEST_ROOT/snapshot-count"

cat >"$TEST_ROOT/snapshot.txt" <<'SNAPSHOT'
###identity
stub snapshot
###printk
4 4 1 7
###proc_stat
cpu0 100 0 100 1000 0 0 0 0 0 0
###interrupts
           CPU0
  1:          0
###softirqs
                    CPU0
 HI:                0
###softnet_stat
00000001 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
###dmesg_ring
0 0
###console_log
unavailable
###meminfo
MemTotal: 1024 kB
SNAPSHOT

cat >"$BIN/sudo" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == env ]]; then
	start_marker=''
	stop_marker=''
	for arg in "$@"; do
		case "$arg" in
			FWLIVE_SLO_TRAFFIC_START_FILE=*) start_marker=${arg#*=} ;;
			FWLIVE_SLO_TRAFFIC_STOP_FILE=*) stop_marker=${arg#*=} ;;
		esac
	done
	[[ -z "$start_marker" ]] || : >"$start_marker"
	[[ -z "$stop_marker" ]] || sleep 0.1
	[[ -z "$stop_marker" ]] || : >"$stop_marker"
	cat <<'SAMPLE'
SLO_SAMPLE status=valid reason=ok label=adaptive-on-pair-1-no-viewer duration_s=1 ping_count=1 bitrate=1G aggregate_bitrate_bps=1000000000 per_stream_bitrate_bps=1000000000 streams=1 requested_streams=1 observed_streams=1 connected_streams=1 completed_streams=1 stream_evidence_mismatch=0 effective_aggregate_bitrate_bps=1000000000 throughput_bps=999000000 retransmits=0 ping_loss_pct=0 ping_rtt_stddev_ms=0.1 generator_cpu_pct=1 generator_cpu_affinity=unknown
SLO_ARTIFACT name=iperf-client.json data_b64=e30=
SLO_ARTIFACT name=iperf-server.json data_b64=e30=
SLO_ARTIFACT name=ping.txt data_b64=cGluZwo=
SAMPLE
	exit 0
fi
if [[ "${1:-}" == */qemu-forwarding-slo-snapshot.sh && "${2:-}" == host ]]; then
	count=0
	[[ ! -f "$FWLIVE_TEST_SNAPSHOT_COUNT" ]] || count=$(cat "$FWLIVE_TEST_SNAPSHOT_COUNT")
	count=$((count + 1))
	printf '%s\n' "$count" >"$FWLIVE_TEST_SNAPSHOT_COUNT"
	if (( count == 3 )) && [[ "${FWLIVE_TEST_FAIL_ACTIVE_SNAPSHOT:-1}" == 1 ]]; then
		echo 'snapshot stub: active pre-traffic collection failed' >&2
		exit 1
	fi
	cat "$FWLIVE_TEST_SNAPSHOT"
	exit 0
fi
echo "unexpected sudo call: $*" >&2
exit 2
STUB

cat >"$BIN/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'sh -s -- guest '* ]]; then
	cat "$FWLIVE_TEST_SNAPSHOT"
	exit 0
fi
input=$(cat || true)
if [[ "$input" == *'if [ -e /var/run/fwlive-adaptive-off ]'* ]]; then
	echo absent
fi
exit 0
STUB

cat >"$BIN/node" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == */tests/fwlive-forwarding-slo-viewer.mjs ]]; then
	shift
	exec "$FWLIVE_TEST_REAL_NODE" "$FWLIVE_TEST_VIEWER_STUB" "$@"
fi
exec "$FWLIVE_TEST_REAL_NODE" "$@"
STUB

cat >"$TEST_ROOT/viewer-stub.mjs" <<'STUB'
import fs from 'node:fs';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const option = (name) => args[args.indexOf(name) + 1];
const ready = option('--ready-file');
const start = option('--start-file');
const stop = option('--stop-file');
const result = option('--result-file');
const { waitForMeasurementStartOrStop } = await import(pathToFileURL(process.env.FWLIVE_TEST_VIEWER_HELPER));
fs.writeFileSync(ready, 'ready\n');
const outcome = await waitForMeasurementStartOrStop(start, stop, 60000);
if (outcome === 'started') {
	while (!fs.existsSync(stop)) await new Promise((resolve) => setTimeout(resolve, 10));
	fs.writeFileSync(result, `${JSON.stringify({
		viewer: 'active', polls_in_window: 1,
		poll_responses: [{ requested_lines: 2000, received_rows: 1900, truncated: false, shed: null }],
		in_flight_after_drain: 0, pending_response_parses_at_drain: 0,
		pending_response_parses_after_navigation: 0, request_failures: 0
	})}\n`);
}
fs.writeFileSync(process.env.FWLIVE_TEST_VIEWER_OUTCOME, `${outcome}\n`);
STUB

chmod +x "$BIN/sudo" "$BIN/ssh" "$BIN/node"

started_ns=$(date +%s%N)
if PATH="$BIN:/usr/bin:/bin" TMPDIR="$SCRATCH" FWLIVE_TEST_REAL_NODE="$REAL_NODE" \
	FWLIVE_TEST_SNAPSHOT="$TEST_ROOT/snapshot.txt" FWLIVE_TEST_SNAPSHOT_COUNT="$SNAPSHOT_COUNT" \
	FWLIVE_TEST_VIEWER_STUB="$TEST_ROOT/viewer-stub.mjs" \
	FWLIVE_TEST_VIEWER_HELPER="$ROOT/tests/lib/fwlive-forwarding-slo-viewer.mjs" \
	FWLIVE_TEST_VIEWER_OUTCOME="$TEST_ROOT/viewer-outcome" \
	OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 FWLIVE_KNOWN_HOSTS="$TEST_ROOT/known_hosts" \
	timeout 12s "$ROOT/scripts/qemu-forwarding-slo-run.sh" \
		--adaptive on --pairs 1 --bitrate 1G --duration 1 --ping-count 1 --drain-ms 100 \
		--report-file "$TEST_ROOT/report.json" >"$TEST_ROOT/stdout" 2>"$TEST_ROOT/stderr"; then
	echo 'runner unexpectedly succeeded after the active pre-traffic snapshot failed' >&2
	exit 1
fi
elapsed_ms=$(( ($(date +%s%N) - started_ns) / 1000000 ))
grep -q 'active-viewer traffic failed for pair 1' "$TEST_ROOT/stderr" || {
	cat "$TEST_ROOT/stderr" >&2
	echo 'runner did not report the active pre-traffic snapshot failure' >&2
	exit 1
}
preserved=$(sed -n 's/^forwarding-slo-run: preserving failed run evidence in //p' "$TEST_ROOT/stderr")
[[ -n "$preserved" && -d "$preserved" ]] || {
	cat "$TEST_ROOT/stderr" >&2
	echo 'failed runner did not preserve and report its private work directory' >&2
	exit 1
}
[[ -s "$preserved/records.jsonl" ]] || {
	echo 'failed runner did not retain the completed baseline record' >&2
	exit 1
}
[[ "$(cat "$TEST_ROOT/viewer-outcome")" == stopped ]] || {
	echo 'viewer did not stop after the runner signaled a pre-traffic failure' >&2
	exit 1
}
[[ -e "$preserved/pair-1-active-viewer/stop" && ! -e "$preserved/pair-1-active-viewer/start" ]] || {
	echo 'test did not exercise a stop signal before the measurement start marker' >&2
	exit 1
}
(( elapsed_ms < 5000 )) || {
	echo "viewer stop-aware wait was not prompt (${elapsed_ms}ms)" >&2
	exit 1
}
"$REAL_NODE" - "$preserved/records.jsonl" <<'NODE'
const fs = require('node:fs');
const [file] = process.argv.slice(2);
const rows = fs.readFileSync(file, 'utf8').trim().split('\n').map(JSON.parse);
if (rows.length !== 1 || rows[0].mode !== 'no-viewer') throw new Error('failed run lost its baseline record');
for (const name of ['iperf-client.json', 'iperf-server.json', 'ping.txt']) {
	if (typeof rows[0].raw?.[name] !== 'string') throw new Error(`failed run lost raw artifact ${name}`);
}
NODE

printf '0\n' >"$SNAPSHOT_COUNT"
if ! PATH="$BIN:/usr/bin:/bin" TMPDIR="$SCRATCH" FWLIVE_TEST_REAL_NODE="$REAL_NODE" \
	FWLIVE_TEST_SNAPSHOT="$TEST_ROOT/snapshot.txt" FWLIVE_TEST_SNAPSHOT_COUNT="$SNAPSHOT_COUNT" \
	FWLIVE_TEST_FAIL_ACTIVE_SNAPSHOT=0 FWLIVE_TEST_VIEWER_STUB="$TEST_ROOT/viewer-stub.mjs" \
	FWLIVE_TEST_VIEWER_HELPER="$ROOT/tests/lib/fwlive-forwarding-slo-viewer.mjs" \
	FWLIVE_TEST_VIEWER_OUTCOME="$TEST_ROOT/success-viewer-outcome" \
	OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 FWLIVE_KNOWN_HOSTS="$TEST_ROOT/success-known_hosts" \
	timeout 12s "$ROOT/scripts/qemu-forwarding-slo-run.sh" \
		--adaptive on --pairs 1 --bitrate 1G --duration 1 --ping-count 1 --drain-ms 100 \
		--report-file "$TEST_ROOT/success-report.json" >"$TEST_ROOT/success-stdout" 2>"$TEST_ROOT/success-stderr"; then
	cat "$TEST_ROOT/success-stderr" >&2
	echo 'runner failed its successful cleanup control' >&2
	exit 1
fi
[[ "$(cat "$TEST_ROOT/success-viewer-outcome")" == started ]] || {
	echo 'successful viewer run did not begin at the traffic start marker' >&2
	exit 1
}
[[ -s "$TEST_ROOT/success-report.json" ]] || {
	echo 'successful runner did not write its report' >&2
	exit 1
}
"$REAL_NODE" - "$TEST_ROOT/success-report.json" <<'NODE'
const fs = require('node:fs');
const [file] = process.argv.slice(2);
if (JSON.parse(fs.readFileSync(file, 'utf8')).pass !== true) throw new Error('success control report did not pass its gates');
NODE
leftover_success_work=$(find "$SCRATCH" -mindepth 1 -maxdepth 1 ! -path "$preserved" -print -quit)
[[ -z "$leftover_success_work" ]] || {
	echo 'successful runner did not remove its private work directory' >&2
	exit 1
}

echo 'qemu forwarding SLO runner failure retention/stop and success cleanup tests passed'
