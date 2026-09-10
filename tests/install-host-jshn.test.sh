#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/scripts/install-host-jshn.sh"
PREFIX="$(mktemp -d "${TMPDIR:-/tmp}/fwlive-jshn-test.XXXXXX")"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fwlive-jshn-pin-test.XXXXXX")"
trap 'rm -rf "$PREFIX" "$WORK"' EXIT

# CI already installs --all. Reuse those artifacts to test repeat runs;
# direct invocation still exercises a fresh real build when none exist.
installed="${FWLIVE_JSHN_PREFIX:-${HOME}/.cache/fwlive-jshn}"
if [[ -d "$installed/25.12" ]]; then
	cp -a "$installed/." "$PREFIX/"
fi
FWLIVE_JSHN_PREFIX="$PREFIX" "$INSTALLER" --all >"$WORK/first.log"
for release in 21.02 22.03 23.05 24.10 25.12; do
	test -x "$PREFIX/$release/bin/jshn"
	test -f "$PREFIX/$release/share/jshn.sh"
	test -f "$PREFIX/$release/manifest"
	grep -q "^release=${release}$" "$PREFIX/$release/manifest"
	"$PREFIX/$release/bin/jshn" -r '{}' >/dev/null
done

FWLIVE_JSHN_PREFIX="$PREFIX" "$INSTALLER" --all >"$WORK/second.log"
test "$(grep -c 'already installed and verified' "$WORK/second.log")" -eq 5

mkdir -p "$WORK/scripts"
cp "$INSTALLER" "$WORK/scripts/install-host-jshn.sh"
cp "$ROOT/scripts/jshn-pins.txt" "$WORK/scripts/jshn-pins.txt"
sed -i '0,/^21\.02 /s//21.02 0/' "$WORK/scripts/jshn-pins.txt"
if FWLIVE_JSHN_PREFIX="$WORK/output" "$WORK/scripts/install-host-jshn.sh" --release 24.10 >"$WORK/tampered.log" 2>&1; then
	echo "FAIL: tampered pin manifest was accepted" >&2
	exit 1
fi
grep -q 'pin manifest integrity check failed' "$WORK/tampered.log"
echo "install-host-jshn: real build, idempotence, and tamper checks passed"

sed -i 's/^commit=.*/commit=0000000000000000000000000000000000000000/' "$PREFIX/24.10/manifest"
if FWLIVE_JSHN_PREFIX="$PREFIX" "$INSTALLER" --release 24.10 >"$WORK/mismatch.log" 2>&1; then
	echo "FAIL: installed pin mismatch accepted" >&2
	exit 1
fi
grep -q 'manifest pin mismatch' "$WORK/mismatch.log"
echo 'installed pin mismatch: rejected'
