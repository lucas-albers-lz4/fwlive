#!/usr/bin/env bash
# Native SDK packages land under bin/packages/<arch>/fwlive/, not luci/ (#1289).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/docs/minimal-build-sdk.md"
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

grep -q 'bin/packages/.*/fwlive/luci-app-fwlive' "$DOC" \
	&& ok "minimal-build-sdk documents fwlive feed output path" \
	|| bad "minimal-build-sdk must document bin/packages/*/fwlive/luci-app-fwlive"

if grep -q 'bin/packages/.*/luci/luci-app-fwlive' "$DOC"; then
	bad "minimal-build-sdk must not document bin/packages/*/luci/luci-app-fwlive for src-link fwlive builds"
else
	ok "minimal-build-sdk has no luci-feed deploy glob"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin/packages/aarch64_generic/fwlive"
touch "$tmp/bin/packages/aarch64_generic/fwlive/luci-app-fwlive_0.0.0-1_all.ipk"

shopt -s nullglob
fwlive=( "$tmp"/bin/packages/*/fwlive/luci-app-fwlive_*.ipk )
luci=( "$tmp"/bin/packages/*/luci/luci-app-fwlive_*.ipk )
shopt -u nullglob

[[ ${#fwlive[@]} -eq 1 ]] \
	&& ok "fwlive feed glob resolves built ipk in fixture" \
	|| bad "fwlive feed glob must match native SDK output (got ${#fwlive[@]})"
[[ ${#luci[@]} -eq 0 ]] \
	&& ok "documented luci feed glob misses fwlive-built ipk" \
	|| bad "luci feed glob must not match fwlive-built ipk"

if [[ "$fail" -ne 0 ]]; then
	echo "FAIL: minimal-build-sdk deploy glob checks" >&2
	exit 1
fi
echo "ok: minimal-build-sdk deploy glob checks"
