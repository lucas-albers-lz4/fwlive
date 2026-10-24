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
DOCKER_COMMAND_FILE="$TMP/docker-command"
CAN_TEST_EFFECTIVE_OWNERSHIP=0
if [[ "$(id -u)" -ne 0 ]] && sudo -n true 2>/dev/null; then
	CAN_TEST_EFFECTIVE_OWNERSHIP=1
fi
cleanup() {
	if [[ "$CAN_TEST_EFFECTIVE_OWNERSHIP" -eq 1 ]]; then
		sudo -n rm -rf -- "$TMP"
	else
		rm -rf -- "$TMP"
	fi
}
trap cleanup EXIT

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

# A failed rm must not fall through to the existence check. Docker exiting 0
# without planting a new artifact would otherwise accept the leftover ipk.
# Root bypasses directory write permission, so chmod a-w cannot make rm fail and
# the scenario is meaningless there; skip it like the ownership check below.
if [[ "$(id -u)" -eq 0 ]]; then
	echo "SKIP: failed stale removal needs a non-root caller (root bypasses directory permissions)"
else
	: >"${dest}/fwlive/luci-app-fwlive_0.1.0_all.ipk"
	chmod a-w "${dest}/fwlive"
	err="$TMP/rmfail.err"
	if sdk_matrix_copy_out >"$TMP/rmfail.out" 2>"$err"; then
		bad "failed stale removal must not make sdk_matrix_copy_out succeed"
	else
		ok "failed stale removal: copy_out returns non-zero"
	fi
	chmod u+w "${dest}/fwlive"
	if [[ -e "${dest}/fwlive/luci-app-fwlive_0.1.0_all.ipk" ]]; then
		ok "failed stale removal: leftover ipk was not treated as this copy"
	else
		bad "failed stale removal: ipk disappeared despite rm failure"
	fi
	rm -f "${dest}/fwlive/luci-app-fwlive_0.1.0_all.ipk"
fi

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
	local script="${!#}"
	printf '%s' "$script" >"$DOCKER_COMMAND_FILE"
	if [[ "$CAN_TEST_EFFECTIVE_OWNERSHIP" -eq 1 ]]; then
		local source_dir="$TMP/builder/bin/packages/${SDK_MATRIX_PACKAGE_ARCH}/fwlive"
		sudo -n mkdir -p "$source_dir" "$dest/fwlive" || return 1
		sudo -n touch "$source_dir/luci-app-fwlive_0.1.0-r1.apk" || return 1
		sudo -n chown -R 0:0 "$TMP/builder" "$dest" || return 1
		script="$(printf '%s' "$script" |
			sed -e "s|/out|$TMP/out|g" -e "s|/builder|$TMP/builder|g")"
		sudo -n sh -ec "$script" || return 1
	else
		mkdir -p "${dest}/fwlive"
		: >"${dest}/fwlive/luci-app-fwlive_0.1.0-r1.apk"
	fi
	return 0
}
if sdk_matrix_copy_out >/dev/null 2>&1; then
	ok "matching _*.apk from this copy: copy_out succeeds"
else
	bad "matching luci-app-fwlive_*.apk planted by copy must make sdk_matrix_copy_out succeed"
fi
DOCKER_COMMAND="$(cat "$DOCKER_COMMAND_FILE")"
printf -v owner_fix 'find "$dest" -type d -exec chown %s:%s {} +' "$(id -u)" "$(id -g)"
if [[ "$DOCKER_COMMAND" == *"$owner_fix"* ]]; then
	ok "copy-out restores caller ownership on output directories"
else
	bad "copy-out must restore caller ownership on output directories"
fi
if [[ "$CAN_TEST_EFFECTIVE_OWNERSHIP" -eq 1 ]]; then
	expected_owner="$(id -u):$(id -g)"
	for output_dir in "$dest" "$dest/fwlive"; do
		if [[ "$(stat -c '%u:%g' "$output_dir")" == "$expected_owner" ]]; then
			ok "copy-out applies caller ownership to $output_dir"
		else
			bad "copy-out did not apply caller ownership to $output_dir"
		fi
	done
else
	echo "SKIP: effective ownership check needs a non-root caller with passwordless sudo"
fi

mv "$TMP/out" "$TMP/out-real"
ln -s "$TMP/out-real" "$TMP/out"
rm -f "$DOCKER_COMMAND_FILE"
err="$TMP/symlink.err"
if sdk_matrix_copy_out >"$TMP/symlink.out" 2>"$err"; then
	bad "symlinked output root must make sdk_matrix_copy_out fail"
else
	ok "symlinked output root: copy_out returns non-zero"
fi
grep -q 'output path must not traverse symlinks' "$err" \
	&& ok "symlinked output root: clear error message" \
	|| bad "symlinked output root: missing path guard error"
[[ ! -e "$DOCKER_COMMAND_FILE" ]] \
	&& ok "symlinked output root: Docker was not invoked" \
	|| bad "symlinked output root: Docker must not be invoked"

[ "$fail" = "0" ] || exit 1
echo "sdk matrix copy-out test passed"
