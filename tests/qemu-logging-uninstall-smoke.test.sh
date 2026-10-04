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
	|| { echo "smoke must record PKG_UPGRADE=1 on the APK upgrade path" >&2; exit 1; }
grep -Fq 'two-version' "$SCRIPT" \
	|| { echo "smoke must point at the two-version APK upgrade evidence" >&2; exit 1; }
grep -Fq 'issue-848-2026-09-27.md' "$SCRIPT" \
	|| { echo "smoke must cite the #848 version-changing upgrade evidence" >&2; exit 1; }
grep -Fq "ubus call fwlive disable_wan_logging" "$SCRIPT" \
	|| { echo "smoke must disable logging before the operator-preservation check" >&2; exit 1; }
grep -Fq 'baseline marker remains after successful disable' "$SCRIPT" \
	|| { echo "smoke must assert disable retired the baseline marker" >&2; exit 1; }
grep -Fq 'disabled_log_value "$PRESERVE_BASE_LOG"' "$SCRIPT" \
	|| { echo "smoke must compare the normalized post-disable log mask" >&2; exit 1; }
grep -Fq 'log=0' "$SCRIPT" \
	|| { echo "smoke must exercise an explicit-zero pre-enable baseline" >&2; exit 1; }
grep -Fq "OPERATOR_LOG=2" "$SCRIPT" \
	|| { echo "smoke must apply a later operator log-mask change" >&2; exit 1; }
grep -Fq 'uninstall overwrote later operator log mask' "$SCRIPT" \
	|| { echo "smoke must assert uninstall preserved the operator log mask" >&2; exit 1; }

echo "qemu logging-uninstall source-contract checks passed"
