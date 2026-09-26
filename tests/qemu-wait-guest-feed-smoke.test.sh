#!/usr/bin/env bash
# Source-contract checks for qemu-wait-guest.sh (#839) and validate-feed-smoke.sh (#838).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAIT="$ROOT/scripts/qemu-wait-guest.sh"
SMOKE="$ROOT/scripts/validate-feed-smoke.sh"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

[[ -x "$WAIT" ]] || fail "qemu-wait-guest.sh is not executable"
[[ -x "$SMOKE" ]] || fail "validate-feed-smoke.sh is not executable"
bash -n "$WAIT" || fail "qemu-wait-guest.sh syntax"
bash -n "$SMOKE" || fail "validate-feed-smoke.sh syntax"

err=""
if err="$("$WAIT" --cmd 2>&1)"; then
	fail "--cmd without a value must fail"
fi
[[ "$err" == *"usage: qemu-wait-guest.sh --cmd CMD"* ]] ||
	fail "--cmd without a value must print usage (got: $err)"

grep -Fq 'BatchMode=yes' "$WAIT" || fail "wait must set BatchMode=yes"
grep -Fq 'NumberOfPasswordPrompts=0' "$WAIT" || fail "wait must disable password prompts"

grep -Fq 'cleanup_on_fail' "$SMOKE" || fail "feed smoke must define cleanup_on_fail"
grep -Fq 'trap cleanup_on_fail EXIT' "$SMOKE" || fail "feed smoke must trap EXIT"
grep -Fq 'validate_matrix_stop_qemu' "$SMOKE" || fail "feed smoke cleanup must stop QEMU"

echo "qemu-wait-guest / validate-feed-smoke source-contract checks passed"
