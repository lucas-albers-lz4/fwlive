#!/usr/bin/env bash
# Host test for sdk_matrix_cache_dirs ownership handling.
#
# v0.1.36 publish regression (2026-08-25): the workflow "Prepare SDK cache
# dirs" step runs `sudo chown -R 1000:1000 .ci-sdk-cache` BEFORE the build, so
# on a GitHub-hosted runner (uid 1001) the cache dirs are already
# buildbot-owned when sdk_matrix_cache_dirs runs. The function's unconditional
# non-root `chown -R 1000:1000` then fails with EPERM (a non-owner cannot
# chown) and the fail-closed path aborts the whole publish.
#
# Correct behavior: skip the chown when ownership is already correct (CI state)
# and only chmod as root/owner; keep fail-closed for genuinely wrong owners.
# Requires passwordless sudo to set up buildbot-owned dirs; SKIPs otherwise.
# shellcheck disable=SC2317
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/lib/sdk-matrix.sh
source "$ROOT/scripts/lib/sdk-matrix.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

if ! sudo -n true 2>/dev/null; then
	echo "SKIP: passwordless sudo unavailable (cannot simulate buildbot-owned cache)"
	exit 0
fi

WORK="$(mktemp -d /tmp/sdk-cache-owner.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

DL="$WORK/dl"
FEEDS="$WORK/feeds/24.10.8"
mkdir -p "$DL" "$FEEDS"
SDK_MATRIX_VERSION_LABEL=24.10.8
export OWRT_SDK_DL_CACHE="$DL" OWRT_SDK_FEEDS_CACHE="$FEEDS"

# Case 1 (the regression): CI state — dirs already buildbot-owned by the
# workflow's sudo chown. Must pass for any uid (root or a 1001 runner).
sudo chown -R 1000:1000 "$WORK"
if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL"; then
	ok "buildbot-owned cache dirs pass (no redundant chown)"
else
	bad "buildbot-owned cache dirs must pass (v0.1.36 chown regression)"
fi

# Case 2: fail-closed still holds — wrong owner (root) and no way to fix as
# a non-root runner must abort. Not applicable when running as root.
if [[ "$(id -u)" -ne 0 ]]; then
	sudo chown -R 0:0 "$WORK"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "root-owned cache dirs must fail closed for a non-root runner"
	else
		ok "root-owned cache dirs fail closed for a non-root runner"
	fi
else
	echo "skip: running as root — fail-closed case not applicable"
fi

[ "$fail" = "0" ] || exit 1
echo "ALL TESTS PASSED"
