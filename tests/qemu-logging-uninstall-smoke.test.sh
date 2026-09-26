#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Host-only checks for the logging-uninstall smoke. The guest run remains
# lab evidence; this does not claim a live QEMU/package-payload result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/qemu-logging-uninstall-smoke.sh"

[[ -x "$SCRIPT" ]] || { echo "logging-uninstall smoke is not executable" >&2; exit 1; }
bash -n "$SCRIPT"
shellcheck --severity=warning "$SCRIPT"

grep -Fq 'apk del luci-app-fwlive' "$SCRIPT" \
	|| { echo "smoke must uninstall 25.12 with apk del" >&2; exit 1; }
grep -Fq 'opkg remove --force-depends luci-app-fwlive' "$SCRIPT" \
	|| { echo "smoke must uninstall 24.10 with opkg remove" >&2; exit 1; }
grep -Fq -- '--artifact-only' "$SCRIPT" \
	|| { echo "smoke must reinstall with qemu-install-fwlive.sh --artifact-only" >&2; exit 1; }
grep -Fq -- '--force-reinstall' "$SCRIPT" \
	|| { echo "smoke must document same-version APK --force-reinstall" >&2; exit 1; }
grep -Fq 'post-upgrade' "$SCRIPT" \
	|| { echo "smoke must call out post-upgrade preservation" >&2; exit 1; }
grep -Fq 'pre-deinstall' "$SCRIPT" \
	|| { echo "smoke must call out pre-deinstall uninstall proof" >&2; exit 1; }
grep -Fq 'PKG_UPGRADE=1' "$SCRIPT" \
	|| { echo "smoke must record the version-changing upgrade residual" >&2; exit 1; }
grep -Fq 'two-version' "$SCRIPT" \
	|| { echo "smoke must record that version-changing upgrades need a two-version experiment" >&2; exit 1; }

echo "qemu logging-uninstall source-contract checks passed"
