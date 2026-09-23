#!/usr/bin/env bash
# Host proof: verify-reproducible-build.sh locates artifacts under the
# resolved SDK_MATRIX_PACKAGE_ARCH dir (issue #518) and fails closed when
# no artifact exists (issue #494). Docker is not required.
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

# Issue #494: empty hashes must not compare equal — fail closed with no artifact.
rm -rf "$TMP/out"
mkdir -p "$TMP/out"
sdk_matrix_feeds_ready() { return 0; }
sdk_matrix_make() { :; }
sdk_matrix_copy_out() { :; }
sdk_matrix_clean_package() { :; }
empty_log="$TMP/empty.log"
if verify_one 24.10 >"$empty_log" 2>&1; then
	bad "verify_one succeeded with empty out/"
else
	ok "verify_one fails with empty out/"
fi
if grep -q '== OK:' "$empty_log"; then
	bad "verify_one printed reproducible OK with empty out/"
else
	ok "verify_one did not print OK with empty out/"
fi
if grep -q 'no artifact after pass 1' "$empty_log"; then
	ok "verify_one reported missing pass-1 artifact"
else
	bad "verify_one did not report missing pass-1 artifact"
fi

# Pass-2 disappearance: pass 1 hashes an artifact, then copy_out deletes it.
sdk_matrix_resolve x86-64 24.10
pass1="$TMP/out/${SDK_MATRIX_PACKAGE_ARCH}/${label}/fwlive/luci-app-fwlive_0_all.ipk"
mkdir -p "$(dirname "$pass1")"
printf 'pass1\n' >"$pass1"
copy_calls=0
sdk_matrix_copy_out() {
	copy_calls=$((copy_calls + 1))
	if [[ "$copy_calls" -ge 2 ]]; then
		rm -f "$pass1"
	fi
}
pass2_log="$TMP/pass2.log"
if verify_one 24.10 >"$pass2_log" 2>&1; then
	bad "verify_one succeeded when pass 2 had no artifact"
else
	ok "verify_one fails when pass 2 drops the artifact"
fi
if grep -q 'no artifact after pass 2' "$pass2_log"; then
	ok "verify_one reported missing pass-2 artifact"
else
	bad "verify_one did not report missing pass-2 artifact: $(tr '\n' ' ' <"$pass2_log")"
fi

[ "$fail" = "0" ] || exit 1
echo "verify-reproducible-target-arch: ok"
