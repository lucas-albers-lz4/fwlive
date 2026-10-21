#!/usr/bin/env bash
# Default rollback-trace case count. No capture and no TLC.
# Production replay omits --generated. The release matrix is the
# deterministic rows plus that default of 24 schedules (33 + 24).
# --generated 4 stays the separate 37-row sample used by the expanded test.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$ROOT/tests/lib/rollback-trace-cases.py"
production_generated=24

count_lines() {
	python3 "$GEN" "$@" | wc -l
}

deterministic="$(count_lines --generated 0)"
if [[ "$deterministic" -ne 33 ]]; then
	echo "deterministic rollback cases must stay 33, got ${deterministic}" >&2
	exit 1
fi
default_lines="$(count_lines)"
expected_default=$((deterministic + production_generated))
if [[ "$default_lines" -ne "$expected_default" ]]; then
	echo "default rollback cases must be ${expected_default}, got ${default_lines}" >&2
	exit 1
fi
sampled="$(count_lines --generated 4)"
expected_sampled=$((deterministic + 4))
if [[ "$sampled" -ne "$expected_sampled" ]]; then
	echo "generated-4 rollback cases must be ${expected_sampled}, got ${sampled}" >&2
	exit 1
fi
echo "rollback trace counts: deterministic ${deterministic}, default ${default_lines}, sample ${sampled}"
