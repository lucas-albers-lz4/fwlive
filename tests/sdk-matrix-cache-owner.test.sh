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
# closed on errors) with buildbot-writable modes; roots must be real
# directories (no symlinks, no trailing-slash bypass); wrong ownership/modes
# are repaired by root or fail closed for non-root. Non-root needs
# passwordless sudo to set up buildbot-owned dirs (SKIPs otherwise); root
# runs without sudo. Each case isolates ONE root as the fault so the other
# cannot mask a regression (luna r7).
# shellcheck disable=SC2317
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/lib/sdk-matrix.sh
source "$ROOT/scripts/lib/sdk-matrix.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
	if ! sudo -n true 2>/dev/null; then
		echo "SKIP: passwordless sudo unavailable (cannot simulate buildbot-owned cache)"
		exit 0
	fi
	SUDO="sudo"
fi

WORK="$(mktemp -d /tmp/sdk-cache-owner.XXXXXX)"
trap "$SUDO rm -rf '$WORK'" EXIT

DL="$WORK/dl"
FEEDS="$WORK/feeds/24.10.8"
mkdir -p "$DL" "$FEEDS"
SDK_MATRIX_VERSION_LABEL=24.10.8
export OWRT_SDK_DL_CACHE="$DL" OWRT_SDK_FEEDS_CACHE="$FEEDS"

# Workflow-equivalent prep: buildbot ownership + least-privilege modes, same
# as the "Prepare SDK cache dirs" step (u=rwX,g=rX,o=rX keeps the uid-1001
# runner able to traverse the tree).
prep_workflow() {
	$SUDO chown -R 1000:1000 "$WORK"
	$SUDO chmod -R u=rwX,g=rX,o=rX "$WORK"
}

# Replace a root with a real, valid buildbot-owned directory (isolates the
# other root as the single fault in each case).
restore_root() {
	$SUDO rm -rf "$1"
	$SUDO mkdir -p "$1"
	$SUDO chown 1000:1000 "$1"
	$SUDO chmod u=rwX,g=rX,o=rX "$1"
}

symlink_root() {
	$SUDO rm -rf "$1"
	$SUDO ln -s "$2" "$1"
	$SUDO mkdir -p "$2"
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
	$SUDO chown -R 0:0 "$WORK"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "root-owned cache trees must fail closed for a non-root runner"
	else
		ok "root-owned cache trees fail closed for a non-root runner"
	fi
	# Case 3: fail-closed — wrong owner on the FEEDS tree only (download tree
	# looks fine): the skip decision must cover both cache trees.
	prep_workflow
	$SUDO chown -R 0:0 "$FEEDS"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "feeds-only wrong ownership must fail closed for a non-root runner"
	else
		ok "feeds-only wrong ownership fails closed for a non-root runner"
	fi
	# Case 4: fail-closed — nested stray wrong-owned file inside an otherwise
	# buildbot-owned tree (roots look fine). Entries inside the 1000:1000 tree
	# must be created with sudo (the runner has no write access there).
	prep_workflow
	$SUDO touch "$DL/stray"
	$SUDO chown 0:0 "$DL/stray"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "nested wrong-owned file must fail closed for a non-root runner"
	else
		ok "nested wrong-owned file fails closed for a non-root runner"
	fi
	# Case 5: fail-closed — buildbot-owned subtree with no group/other read or
	# traverse (mode check; the scan-error branch is defense-in-depth, since
	# any mode that denies find traversal also fails the mode checks below).
	prep_workflow
	$SUDO mkdir -p "$DL/nested"
	$SUDO chown 1000:1000 "$DL/nested"
	$SUDO chmod 700 "$DL/nested"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "unreadable subtree must fail closed for a non-root runner"
	else
		ok "unreadable subtree fails closed for a non-root runner"
	fi
	# Case 7: fail-closed — correct ownership but unwritable modes (owner
	# 1000, 0555): buildbot cannot write the cache, must not pass.
	prep_workflow
	$SUDO chmod -R 555 "$DL"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "unwritable modes must fail closed for a non-root runner"
	else
		ok "unwritable modes fail closed for a non-root runner"
	fi
	# Case 8: fail-closed — symlinked DL root (FEEDS stays a real dir; luna r5).
	prep_workflow
	symlink_root "$DL" "$WORK/dl-target"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "symlinked cache root must fail closed for a non-root runner"
	else
		ok "symlinked cache root fails closed for a non-root runner"
	fi
	# Case 10: fail-closed — symlinked FEEDS root (DL restored to a real dir,
	# so the FEEDS symlink is the single fault; luna r7).
	prep_workflow
	restore_root "$DL"
	symlink_root "$FEEDS" "$WORK/feeds-target"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "symlinked feeds root must fail closed for a non-root runner"
	else
		ok "symlinked feeds root fails closed for a non-root runner"
	fi
	# Case 11: fail-closed — trailing forms of a symlinked DL root (FEEDS
	# restored): 'dl/', 'dl//', 'dl/.' must not bypass the -L rejection
	# (luna r6/r7).
	prep_workflow
	restore_root "$FEEDS"
	symlink_root "$DL" "$WORK/dl-target"
	for _form in "$DL/" "$DL//" "$DL/."; do
		export OWRT_SDK_DL_CACHE="$_form"
		if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
			bad "trailing form '$_form' of symlinked root must fail closed for a non-root runner"
		else
			ok "trailing form '$_form' of symlinked root fails closed for a non-root runner"
		fi
	done
	export OWRT_SDK_DL_CACHE="$DL"
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
	# Case 9 (root): symlinked DL root fails closed — no repair is possible
	# (chown -R would fix the target, not the link).
	prep_workflow
	symlink_root "$DL" "$WORK/dl-target"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "symlinked cache root must fail closed for root as well"
	else
		ok "symlinked cache root fails closed for root"
	fi
	# Case 12 (root): trailing-slash form must not bypass the symlink rejection
	# (FEEDS restored to isolate DL).
	prep_workflow
	restore_root "$FEEDS"
	symlink_root "$DL" "$WORK/dl-target"
	export OWRT_SDK_DL_CACHE="$DL/"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "trailing-slash symlinked root must fail closed for root as well"
	else
		ok "trailing-slash symlinked root fails closed for root"
	fi
	export OWRT_SDK_DL_CACHE="$DL"
	# Case 13 (root): symlinked FEEDS root fails closed (DL restored).
	prep_workflow
	restore_root "$DL"
	symlink_root "$FEEDS" "$WORK/feeds-target"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "symlinked feeds root must fail closed for root as well"
	else
		ok "symlinked feeds root fails closed for root"
	fi
fi

[ "$fail" = "0" ] || exit 1
echo "ALL TESTS PASSED"
