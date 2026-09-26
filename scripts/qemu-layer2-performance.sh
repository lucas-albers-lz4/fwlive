#!/usr/bin/env bash
# Layer 2 browser performance harness for #306 / #339 (report-only by default).
# Set FWLIVE_ENFORCE=1 for sign-off threshold failures; see docs/developer/qemu-lab.md.
# Prereqs: running QEMU guest with fwlive installed, host Node + playwright.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [[ ! -d "${ROOT}/node_modules/playwright" ]]; then
	echo "layer2 performance: playwright missing — run npm install" >&2
	exit 1
fi

exec node "${ROOT}/tests/fwlive-layer2-performance.mjs"
