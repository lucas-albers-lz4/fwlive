#!/usr/bin/env bash
# Host test: sdk_matrix_copy_out must not succeed with an empty out/ tree (#435).
# Docker and cache-dir setup are stubbed — no daemon needed.
# shellcheck disable=SC2317
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/lib/sdk-matrix.sh
source "$ROOT/scripts/lib/sdk-matrix.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

sdk_matrix_root() { printf '%s' "$TMP"; }
sdk_matrix_cache_dirs() {
	# Real cache_dirs sets these; the compose env expansion needs them under set -u.
	SDK_MATRIX_DL_CACHE="${TMP}/.ci-sdk-cache/dl"
	SDK_MATRIX_FEEDS_CACHE="${TMP}/.ci-sdk-cache/feeds"
	return 0
}
# Default: copy is a no-op (compose never plants an artifact).
docker() { return 0; }

sdk_matrix_resolve x86-64 24.10
dest="${TMP}/out/${SDK_MATRIX_PACKAGE_ARCH}/${SDK_MATRIX_VERSION_LABEL}"

err="$TMP/empty.err"
if sdk_matrix_copy_out >"$TMP/empty.out" 2>"$err"; then
	bad "empty dest must make sdk_matrix_copy_out fail"
else
	ok "empty dest: copy_out returns non-zero"
fi
grep -q 'no luci-app-fwlive package artifact' "$err" \
	&& ok "empty dest: clear error message" \
	|| bad "empty dest: missing artifact error"

mkdir -p "${dest}/fwlive"
: >"${dest}/fwlive/Packages"
err="$TMP/decoy.err"
if sdk_matrix_copy_out >"$TMP/decoy.out" 2>"$err"; then
	bad "non-matching files must not count as a package artifact"
else
	ok "decoy-only dest: copy_out returns non-zero"
fi

# Stale matching IPK from an earlier build must not satisfy the post-copy check
# when this invocation copies nothing.
: >"${dest}/fwlive/luci-app-fwlive_0.1.0_all.ipk"
err="$TMP/stale.err"
if sdk_matrix_copy_out >"$TMP/stale.out" 2>"$err"; then
	bad "stale matching ipk must not make sdk_matrix_copy_out succeed"
else
	ok "stale matching ipk with no-op copy: copy_out returns non-zero"
fi
if [[ -e "${dest}/fwlive/luci-app-fwlive_0.1.0_all.ipk" ]]; then
	bad "stale matching ipk must be removed before copy"
else
	ok "stale matching ipk: cleared before copy"
fi
grep -q 'no luci-app-fwlive package artifact' "$err" \
	&& ok "stale matching ipk: clear error message" \
	|| bad "stale matching ipk: missing artifact error"

docker() {
	mkdir -p "${dest}/fwlive"
	: >"${dest}/fwlive/luci-app-fwlive_0.1.0_all.ipk"
	return 0
}
if sdk_matrix_copy_out >/dev/null 2>&1; then
	ok "matching ipk from this copy: copy_out succeeds"
else
	bad "matching ipk planted by copy must make sdk_matrix_copy_out succeed"
fi

rm -f "${dest}/fwlive/luci-app-fwlive_0.1.0_all.ipk"
docker() {
	mkdir -p "$dest"
	: >"${dest}/luci-app-fwlive-0.1.0-r1.apk"
	return 0
}
if sdk_matrix_copy_out >/dev/null 2>&1; then
	ok "matching apk at dest root from this copy: copy_out succeeds"
else
	bad "matching apk planted at dest root must make sdk_matrix_copy_out succeed"
fi

rm -f "${dest}/luci-app-fwlive-0.1.0-r1.apk"
docker() {
	mkdir -p "${dest}/fwlive"
	: >"${dest}/fwlive/luci-app-fwlive_0.1.0-r1.apk"
	return 0
}
if sdk_matrix_copy_out >/dev/null 2>&1; then
	ok "matching _*.apk from this copy: copy_out succeeds"
else
	bad "matching luci-app-fwlive_*.apk planted by copy must make sdk_matrix_copy_out succeed"
fi

[ "$fail" = "0" ] || exit 1
echo "sdk matrix copy-out test passed"
