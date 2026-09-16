#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Static checks for the forwarding-SLO guest, traffic, viewer, and runner
# helpers. The full routed run remains a lab/manual test because it needs a
# booted armsr guest and root-owned namespaces.
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
shellcheck "$ROOT/scripts/qemu-forwarding-slo-guest.sh" \
	"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" \
	"$ROOT/scripts/qemu-forwarding-slo-run.sh"

"$ROOT/scripts/qemu-forwarding-slo-guest.sh" --help >/dev/null
"$ROOT/scripts/qemu-forwarding-slo-traffic.sh" --help >/dev/null
"$ROOT/scripts/qemu-forwarding-slo-run.sh" --help >/dev/null
node "$ROOT/tests/fwlive-forwarding-slo-viewer.mjs" --help >/dev/null

grep -Fq 'fwlive-slo-log-lan-to-wan' "$ROOT/scripts/qemu-forwarding-slo-guest.sh" ||
	die "guest helper must install the LAN-to-WAN log rule"
grep -Fq 'fwlive-slo-log-wan-to-lan' "$ROOT/scripts/qemu-forwarding-slo-guest.sh" ||
	die "guest helper must install the WAN-to-LAN log rule"
grep -Fq 'all_pairs_complete' "$ROOT/scripts/qemu-forwarding-slo-run.sh" ||
	die "runner must report incomplete pairs"

echo "qemu-forwarding-slo harness checks passed"
