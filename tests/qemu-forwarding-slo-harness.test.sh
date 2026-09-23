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
	"$ROOT/scripts/qemu-forwarding-slo-run.sh"; do
	[[ -x "$script" ]] || die "helper is not executable: $script"
	bash -n "$script" || die "shell syntax failed: $script"
done
node --check "$ROOT/tests/fwlive-forwarding-slo-viewer.mjs"
node --check "$ROOT/tests/lib/fwlive-forwarding-slo-report.mjs"
node --check "$ROOT/tests/fwlive-forwarding-slo-report.test.mjs"
shellcheck "$ROOT/scripts/qemu-forwarding-slo-guest.sh" \
	"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	"$ROOT/scripts/qemu-forwarding-slo-run.sh" \
	"$ROOT/scripts/lib/qemu-forwarding-slo-net.sh"

"$ROOT/scripts/qemu-forwarding-slo-guest.sh" --help >/dev/null
"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" --help >/dev/null
"$ROOT/scripts/qemu-forwarding-slo-run.sh" --help >/dev/null
node "$ROOT/tests/fwlive-forwarding-slo-viewer.mjs" --help >/dev/null
node "$ROOT/tests/fwlive-forwarding-slo-report.test.mjs"

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
for override in FWLIVE_SLO_LAN_NETNS FWLIVE_SLO_WAN_NETNS \
	FWLIVE_SLO_LAN_ENDPOINT_IP FWLIVE_SLO_WAN_ENDPOINT_IP; do
	grep -Fq "$override" "$ROOT/scripts/qemu-forwarding-slo-run.sh" ||
		die "runner must pass through $override to the traffic probe"
done
grep -Fq '[[ -e "$stop" ]] || touch "$stop"' "$ROOT/scripts/qemu-forwarding-slo-run.sh" ||
	die "runner failure path may touch a root-owned stop marker"
grep -Fq "fwlive-forwarding-slo/v1" "$ROOT/tests/lib/fwlive-forwarding-slo-report.mjs" ||
	die "report module must identify its report schema"

echo "qemu-forwarding-slo source-contract checks passed"
