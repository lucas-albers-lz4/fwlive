#!/usr/bin/env bash
# Host proof: verify-reproducible-build.sh locates artifacts under the
# resolved SDK_MATRIX_PACKAGE_ARCH dir (issue #518). Docker is not required.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/verify-reproducible-build.sh
source "$REPO/scripts/verify-reproducible-build.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

if grep -q 'out/x86_64' "$REPO/scripts/verify-reproducible-build.sh"; then
	bad "verify-reproducible-build.sh still hardcodes out/x86_64"
else
	ok "no hardcoded out/x86_64"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP"

label="$(sdk_matrix_version_label 24.10)"
mkdir -p "$TMP/out/x86_64/${label}/fwlive" "$TMP/out/aarch64_generic/${label}/fwlive"
printf 'x86-decoy\n' >"$TMP/out/x86_64/${label}/fwlive/luci-app-fwlive_0_all.ipk"
printf 'arm-real\n' >"$TMP/out/aarch64_generic/${label}/fwlive/luci-app-fwlive_0_all.ipk"

sdk_matrix_resolve armsr-armv8 24.10
got="$(artifact_sha "$label")" || {
	bad "artifact_sha failed for armsr-armv8"
	got=""
}
got_path="${got#* }"
if [[ "$got_path" == *"/out/aarch64_generic/"* && "$got_path" != *"/out/x86_64/"* ]]; then
	ok "armsr-armv8 looks under out/aarch64_generic/"
else
	bad "armsr-armv8 path: ${got_path:-<empty>}"
fi

want_hash="$(sha256sum "$TMP/out/aarch64_generic/${label}/fwlive/luci-app-fwlive_0_all.ipk" | awk '{print $1}')"
got_hash="${got%% *}"
if [[ -n "$got_hash" && "$got_hash" == "$want_hash" ]]; then
	ok "armsr-armv8 hashes aarch64_generic artifact (not x86_64 decoy)"
else
	bad "armsr-armv8 hash '${got_hash}' want '${want_hash}'"
fi

rm -rf "$TMP/out/aarch64_generic"
if artifact_sha "$label" >/dev/null 2>&1; then
	bad "artifact_sha succeeded with only x86_64 present after armsr resolve"
else
	ok "exist-guard: missing aarch64_generic dir fails closed"
fi

sdk_matrix_resolve x86-64 24.10
got="$(artifact_sha "$label")" || {
	bad "artifact_sha failed for x86-64"
	got=""
}
got_path="${got#* }"
if [[ "$got_path" == *"/out/x86_64/"* ]]; then
	ok "x86-64 looks under out/x86_64/"
else
	bad "x86-64 path: ${got_path:-<empty>}"
fi

[ "$fail" = "0" ] || exit 1
echo "verify-reproducible-target-arch: ok"
