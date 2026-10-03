#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Source-contract / static wiring checks for the forwarding-SLO guest, traffic,
# viewer, and runner helpers (syntax, ShellCheck, --help, grep pins). Also
# runs the host Node report unit test. The full routed guest run remains a
# lab/manual test because it needs a booted armsr guest and root-owned
# namespaces; these checks do not prove guest forwarding behavior.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
die() { echo "qemu-forwarding-slo-harness test FAIL: $*" >&2; exit 1; }

for script in \
	"$ROOT/scripts/qemu-forwarding-slo-guest.sh" \
	"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	"$ROOT/scripts/qemu-forwarding-slo-run.sh" \
	"$ROOT/scripts/qemu-forwarding-slo-snapshot.sh" \
	"$ROOT/tests/qemu-forwarding-slo-traffic.test.sh"; do
	[[ -x "$script" ]] || die "helper is not executable: $script"
	bash -n "$script" || die "shell syntax failed: $script"
done
node --check "$ROOT/tests/fwlive-forwarding-slo-viewer.mjs"
node --check "$ROOT/tests/lib/fwlive-forwarding-slo-report.mjs"
node --check "$ROOT/tests/lib/fwlive-forwarding-slo-telemetry.mjs"
node --check "$ROOT/tests/lib/fwlive-forwarding-slo-viewer.mjs"
node --check "$ROOT/tests/fwlive-forwarding-slo-report.test.mjs"
node --check "$ROOT/tests/fwlive-forwarding-slo-telemetry.test.mjs"
node --check "$ROOT/tests/fwlive-forwarding-slo-viewer-metrics.test.mjs"
shellcheck "$ROOT/scripts/qemu-forwarding-slo-guest.sh" \
	"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	"$ROOT/scripts/qemu-forwarding-slo-run.sh" \
	"$ROOT/scripts/qemu-forwarding-slo-snapshot.sh" \
	"$ROOT/tests/qemu-forwarding-slo-traffic.test.sh" \
	"$ROOT/scripts/lib/qemu-forwarding-slo-net.sh"

"$ROOT/scripts/qemu-forwarding-slo-guest.sh" --help >/dev/null
"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" --help >/dev/null
"$ROOT/scripts/qemu-forwarding-slo-run.sh" --help >/dev/null
"$ROOT/scripts/qemu-forwarding-slo-snapshot.sh" --help >/dev/null
node "$ROOT/tests/fwlive-forwarding-slo-viewer.mjs" --help >/dev/null
node "$ROOT/tests/fwlive-forwarding-slo-report.test.mjs"
node "$ROOT/tests/fwlive-forwarding-slo-telemetry.test.mjs"
node "$ROOT/tests/fwlive-forwarding-slo-viewer-metrics.test.mjs"
"$ROOT/tests/qemu-forwarding-slo-traffic.test.sh"

management_nic="$(OWRT_LAB_NET_MODE=dhcp OWRT_QEMU_NIC_MODEL=virtio-net-pci bash -c \
	'source "$1"; qemu_lab_nic_user 8080 2222' bash \
	"$ROOT/scripts/lib/qemu-lab-net.sh")"
grep -Fq ',model=virtio-net-pci' <<<"$management_nic" ||
	die "x86 management NIC model override is not wired"

grep -Fq 'fwlive-slo-log-lan-to-wan' "$ROOT/scripts/qemu-forwarding-slo-guest.sh" ||
	die "guest helper must install the LAN-to-WAN log rule"
grep -Fq 'fwlive-slo-log-wan-to-lan' "$ROOT/scripts/qemu-forwarding-slo-guest.sh" ||
	die "guest helper must install the WAN-to-LAN log rule"
grep -Fq 'all_pairs_complete' "$ROOT/tests/lib/fwlive-forwarding-slo-report.mjs" ||
	die "report module must report incomplete pairs"
grep -Fq 'active_viewer_poll_observed' "$ROOT/tests/lib/fwlive-forwarding-slo-report.mjs" ||
	die "report module must reject a window with no active viewer poll"
grep -Fq 'FWLIVE_SLO_IPERF_BITRATE' "$ROOT/scripts/qemu-forwarding-slo-run.sh" ||
	die "runner must pass through an optional iperf bitrate"
grep -Fq 'FWLIVE_SLO_IPERF_STREAMS' "$ROOT/scripts/qemu-forwarding-slo-run.sh" ||
	die "runner must pass through a validated iperf stream count"
grep -Fq 'aggregate across all TCP streams' "$ROOT/tests/lib/fwlive-forwarding-slo-report.mjs" ||
	die "report must define aggregate bitrate semantics"
for override in FWLIVE_SLO_LAN_NETNS FWLIVE_SLO_WAN_NETNS \
	FWLIVE_SLO_LAN_ENDPOINT_IP FWLIVE_SLO_WAN_ENDPOINT_IP; do
	grep -Fq "$override" "$ROOT/scripts/qemu-forwarding-slo-run.sh" ||
		die "runner must pass through $override to the traffic probe"
done
grep -Fq '[[ -e "$stop" ]] || touch "$stop"' "$ROOT/scripts/qemu-forwarding-slo-run.sh" ||
	die "runner failure path may touch a root-owned stop marker"
grep -Fq "fwlive-forwarding-slo/v1" "$ROOT/tests/lib/fwlive-forwarding-slo-report.mjs" ||
	die "report module must identify its report schema"
grep -Fq 'poll_responses' "$ROOT/tests/fwlive-forwarding-slo-viewer.mjs" ||
	die "viewer must retain response-side poll evidence"
grep -Fq 'ethtool -l "$dev"' "$ROOT/scripts/qemu-forwarding-slo-snapshot.sh" ||
	die "snapshot must capture active ethtool channels when available"
grep -Fq 'ethtool_channels=unknown' "$ROOT/scripts/qemu-forwarding-slo-snapshot.sh" ||
	die "snapshot must mark unavailable channel data as unknown"
grep -Fq 'status=invalid' "$ROOT/scripts/qemu-forwarding-slo-run.sh" ||
	die "runner must retain structured invalid traffic samples"
grep -Fq 'dirty_scope:' "$ROOT/scripts/qemu-forwarding-slo-run.sh" ||
	die "run metadata must name its dirty-state scope"

node - "$ROOT/scripts/qemu-forwarding-slo-run.sh" \
	"$ROOT/scripts/qemu-forwarding-slo-snapshot.sh" \
	"$ROOT/scripts/lib/qemu-forwarding-slo-net.sh" <<'NODE'
const fs = require('node:fs');
const [runFile, snapshotFile, netFile] = process.argv.slice(2);
const run = fs.readFileSync(runFile, 'utf8');
const snapshot = fs.readFileSync(snapshotFile, 'utf8');
const net = fs.readFileSync(netFile, 'utf8');
for (const [side, tap, snapshotVar, expected] of [
	['LAN', 'LAN_TAP', 'lan_dev', 'fwlive-slo-ltap'],
	['WAN', 'WAN_TAP', 'wan_dev', 'fwlive-slo-wtap']
]) {
	const envName = `FWLIVE_SLO_${tap}`;
	const parameter = (name, operator) => '${' + name + operator + expected + '}';
	const runHasDefault = run.includes(`${tap}="${parameter(envName, ':-')}"`);
	const libraryHasDefault = net.includes(`: "${parameter(envName, ':=')}"`);
	const position = side === 'LAN' ? '1' : '2';
	const snapshotHasDefault = snapshot.includes(`${snapshotVar}=${parameter(position, ':-')}`);
	if (!runHasDefault || !libraryHasDefault || !snapshotHasDefault) {
		throw new Error(`${side} TAP default is inconsistent between runner, network setup, and snapshot helper`);
	}
	if (expected.length > 15) throw new Error(`${side} TAP default exceeds Linux IFNAMSIZ: ${expected}`);
}
if (!run.includes('"$LAN_TAP" "$WAN_TAP" "$CONSOLE_LOG"')) {
	throw new Error('runner does not pass its selected TAP names to the host snapshot');
}
if (!run.includes("'--untracked-files=no'")) {
	throw new Error('runner source identity must explicitly exclude untracked files from dirty state');
}
console.log('qemu-forwarding-slo default TAP/snapshot wiring checks passed');
NODE

echo "qemu-forwarding-slo source-contract checks passed"
