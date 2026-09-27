#!/usr/bin/env bash
# Same-file #anchor links must be checked against the source file (#942).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

git -C "$TMP" init -q
git -C "$TMP" config user.email 'fwlive-test@example.com'
git -C "$TMP" config user.name 'fwlive-test'
printf '# Hello\n\n[bad](#missing)\n' >"$TMP/a.md"
git -C "$TMP" add a.md
if FWLIVE_LINKCHECK_ROOT="$TMP" "$ROOT/scripts/fwlive-linkcheck.sh" >"$TMP/bad.out" 2>&1; then
	fail "same-file missing anchor must fail"
fi
grep -q 'anchor missing' "$TMP/bad.out" || fail "missing-anchor message ($(cat "$TMP/bad.out"))"

printf '# Hello\n\n[ok](#hello)\n' >"$TMP/a.md"
git -C "$TMP" add a.md
FWLIVE_LINKCHECK_ROOT="$TMP" "$ROOT/scripts/fwlive-linkcheck.sh" >"$TMP/ok.out" 2>&1 \
	|| fail "same-file heading must pass ($(cat "$TMP/ok.out"))"

echo "fwlive linkcheck same-file anchor test passed"
