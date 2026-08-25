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
# Correct behavior: skip chown only when BOTH cache trees are fully
# buildbot-owned (roots AND nested entries, verified by a scan that fails
# closed on errors) and only chmod as root/owner; wrong ownership is repaired
# by root or fails closed for non-root. Requires passwordless sudo to set up
# buildbot-owned dirs; SKIPs otherwise (GH runners have it).
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
trap 'sudo rm -rf "$WORK"' EXIT

DL="$WORK/dl"
FEEDS="$WORK/feeds/24.10.8"
mkdir -p "$DL" "$FEEDS"
SDK_MATRIX_VERSION_LABEL=24.10.8
export OWRT_SDK_DL_CACHE="$DL" OWRT_SDK_FEEDS_CACHE="$FEEDS"

# Workflow-equivalent prep: buildbot ownership + least-privilege modes, same
# as the "Prepare SDK cache dirs" step (u=rwX,g=rX,o=rX keeps the uid-1001
# runner able to traverse the tree).
prep_workflow() {
	sudo chown -R 1000:1000 "$WORK"
	sudo chmod -R u=rwX,g=rX,o=rX "$WORK"
}

# Case 1 (the regression): CI state — both trees buildbot-owned. Must pass
# for any uid (root or a 1001 runner).
prep_workflow
if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL"; then
	ok "buildbot-owned cache trees pass (no redundant chown)"
else
	bad "buildbot-owned cache trees must pass (v0.1.36 chown regression)"
fi

if [[ "$(id -u)" -ne 0 ]]; then
	# Case 2: fail-closed — wrong owner at a tree root with no way to fix.
	sudo chown -R 0:0 "$WORK"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "root-owned cache trees must fail closed for a non-root runner"
	else
		ok "root-owned cache trees fail closed for a non-root runner"
	fi
	# Case 3: fail-closed — wrong owner on the FEEDS tree only (download tree
	# looks fine): the skip decision must cover both cache trees.
	prep_workflow
	sudo chown -R 0:0 "$FEEDS"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "feeds-only wrong ownership must fail closed for a non-root runner"
	else
		ok "feeds-only wrong ownership fails closed for a non-root runner"
	fi
	# Case 4: fail-closed — nested stray wrong-owned file inside an otherwise
	# buildbot-owned tree (roots look fine).
	prep_workflow
	touch "$DL/stray"
	sudo chown 0:0 "$DL/stray"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "nested wrong-owned file must fail closed for a non-root runner"
	else
		ok "nested wrong-owned file fails closed for a non-root runner"
	fi
	# Case 5: fail-closed — unreadable subtree: the ownership scan must not
	# read as a clean tree when it cannot traverse everything.
	prep_workflow
	mkdir -p "$DL/nested"
	sudo chmod 700 "$DL/nested"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "unreadable subtree must fail closed for a non-root runner"
	else
		ok "unreadable subtree fails closed for a non-root runner"
	fi
else
	echo "skip: running as root — non-root fail-closed cases not applicable"
	# Case 6 (root): nested stray wrong-owned file must be REPAIRED (recursive
	# chown), not chmodded into a state uid 1000 cannot write.
	mkdir -p "$DL/nested"
	touch "$DL/nested/stray"
	chown 0:0 "$DL/nested/stray"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL"; then
		if [[ "$(stat -c %u "$DL/nested/stray")" == "1000" ]]; then
			ok "root caller repairs nested wrong-owned file (uid 1000 after)"
		else
			bad "root caller must repair nested wrong-owned file (got uid $(stat -c %u "$DL/nested/stray"))"
		fi
	else
		bad "root caller must succeed by repairing nested wrong ownership"
	fi
fi

[ "$fail" = "0" ] || exit 1
echo "ALL TESTS PASSED"
