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
	# Case 14: fail-closed — symlinked root via 'dl/sub/..' spelling (final
	# component is real; the component-wise walk must catch the link; luna r8).
	prep_workflow
	restore_root "$FEEDS"
	symlink_root "$DL" "$WORK/dl-target"
	$SUDO mkdir -p "$WORK/dl-target/sub"
	export OWRT_SDK_DL_CACHE="$DL/sub/.."
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "'dl/sub/..' spelling of a symlinked root must fail closed for a non-root runner"
	else
		ok "'dl/sub/..' spelling of a symlinked root fails closed for a non-root runner"
	fi
	export OWRT_SDK_DL_CACHE="$DL"
	# Case 15: fail-closed — regular file in place of the DL root (luna r8).
	prep_workflow
	restore_root "$FEEDS"
	$SUDO rm -rf "$DL"
	$SUDO touch "$DL"
	$SUDO chown 1000:1000 "$DL"
	$SUDO chmod 644 "$DL"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "regular file as cache root must fail closed for a non-root runner"
	else
		ok "regular file as cache root fails closed for a non-root runner"
	fi
	# Case 17: fail-closed — RELATIVE symlinked root ('rel/dl'): the walker
	# must probe relative components from '.', not '/', so a relative symlink
	# override is caught (luna r9).
	prep_workflow
	restore_root "$FEEDS"
	$SUDO mkdir -p "$WORK/rel"
	$SUDO ln -s "$WORK/dl-target" "$WORK/rel/dl"
	$SUDO mkdir -p "$WORK/dl-target"
	if ( cd "$WORK" \
		&& export OWRT_SDK_DL_CACHE="rel/dl" \
		&& sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null ); then
		bad "relative symlinked root must fail closed for a non-root runner"
	else
		ok "relative symlinked root fails closed for a non-root runner"
	fi
	# Case 18: fail-closed — world-writable modes (g+w/o+w) violate the
	# least-privilege policy even when owned by buildbot (luna r9).
	prep_workflow
	restore_root "$FEEDS"
	restore_root "$DL"
	$SUDO chmod -R 777 "$DL"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "world-writable cache must fail closed for a non-root runner"
	else
		ok "world-writable cache fails closed for a non-root runner"
	fi
	# Case 20: the legit feeds src-link symlink (fwlive -> /work/fwlive/
	# openwrt-feed) must PASS — link modes are meaningless (skipped by mode
	# checks) and the src-link target is the only allowed link (luna r10).
	prep_workflow
	$SUDO ln -s /work/fwlive/openwrt-feed "$FEEDS/fwlive"
	$SUDO chown -h 1000:1000 "$FEEDS/fwlive"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL"; then
		ok "legit src-link symlink in feeds cache passes"
	else
		bad "legit src-link symlink must pass for a non-root runner"
	fi
	# Case 21: fail-closed — disallowed nested symlink (target outside the
	# workspace) cannot be repaired by chmod; non-root fails closed (luna r10).
	prep_workflow
	$SUDO ln -s /etc/passwd "$DL/evil"
	$SUDO chown -h 1000:1000 "$DL/evil"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "disallowed nested symlink must fail closed for a non-root runner"
	else
		ok "disallowed nested symlink fails closed for a non-root runner"
	fi
	# Case 23: fail-closed — world-writable regular FILE inside DL (file-level
	# coverage for the g+w/o+w rejection; luna r10 Minor). The evil link from
	# case 21 must not mask this.
	prep_workflow
	$SUDO rm -f "$DL/evil"
	$SUDO touch "$DL/ww"
	$SUDO chown 1000:1000 "$DL/ww"
	$SUDO chmod 666 "$DL/ww"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "world-writable file must fail closed for a non-root runner"
	else
		ok "world-writable file fails closed for a non-root runner"
	fi
	# Case 25: OpenWrt `scripts/feeds update` creates relative *.index /
	# *.targetindex symlinks in the cached feeds tree — they are legit and
	# must PASS alongside the src-link (luna r11). Resolution-based validation
	# requires the index TARGETS to exist; the fwlive link from case 20 must
	# be reset first (set -e kills the branch at a duplicate ln).
	prep_workflow
	$SUDO rm -f "$FEEDS/fwlive" "$FEEDS/packages.index" "$FEEDS/packages.targetindex"
	$SUDO touch "$FEEDS/base.index" "$FEEDS/base.targetindex"
	$SUDO chown 1000:1000 "$FEEDS/base.index" "$FEEDS/base.targetindex"
	$SUDO ln -s /work/fwlive/openwrt-feed "$FEEDS/fwlive"
	$SUDO chown -h 1000:1000 "$FEEDS/fwlive"
	$SUDO ln -s base.index "$FEEDS/packages.index"
	$SUDO ln -s base.targetindex "$FEEDS/packages.targetindex"
	$SUDO chown -h 1000:1000 "$FEEDS/packages.index" "$FEEDS/packages.targetindex"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL"; then
		ok "OpenWrt index symlinks in feeds cache pass"
	else
		bad "legit OpenWrt index symlinks must pass for a non-root runner"
	fi
	# Case 32: tracked symlinks INSIDE the pinned feed checkouts (base-files
	# os-release, netifd ifdown, LuCI Bootstrap links) resolve inside the
	# feeds tree and must pass (luna r14).
	prep_workflow
	$SUDO rm -f "$FEEDS/fwlive" "$FEEDS/packages.index" "$FEEDS/packages.targetindex" "$FEEDS/base.index" "$FEEDS/base.targetindex"
	$SUDO mkdir -p "$FEEDS/base/package/base-files/files/etc" "$FEEDS/base/package/netifd"
	$SUDO touch "$FEEDS/base/package/base-files/files/etc/os-release"
	$SUDO ln -s ../base-files/files/etc/os-release "$FEEDS/base/package/netifd/os-release"
	$SUDO chown -R 1000:1000 "$FEEDS/base"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL"; then
		ok "tracked repo symlinks resolving inside the feeds tree pass"
	else
		bad "inside-resolving repo symlinks must pass for a non-root runner"
	fi
	# Case 33: fail-closed — a CHAINED link (evil.index -> fwlive) resolves
	# through the src-link to the workspace, outside the cache (luna r14).
	prep_workflow
	$SUDO rm -rf "$FEEDS/base"
	$SUDO ln -s /work/fwlive/openwrt-feed "$FEEDS/fwlive"
	$SUDO chown -h 1000:1000 "$FEEDS/fwlive"
	$SUDO ln -s fwlive "$FEEDS/evil.index"
	$SUDO chown -h 1000:1000 "$FEEDS/evil.index"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "chained index symlink must fail closed for a non-root runner"
	else
		ok "chained index symlink fails closed for a non-root runner"
	fi
	# Case 34: fail-closed — a link NAME with a trailing newline must not split
	# the NUL-less enumeration and slip past as the valid fwlive link (luna r15).
	prep_workflow
	$SUDO rm -rf "$FEEDS/base" "$FEEDS/evil.index"
	$SUDO rm -f "$FEEDS/fwlive"
	$SUDO ln -s /work/fwlive/openwrt-feed "$FEEDS/fwlive"
	$SUDO chown -h 1000:1000 "$FEEDS/fwlive"
	$SUDO ln -s /builder "$FEEDS/fwlive"$'\n'
	$SUDO chown -h 1000:1000 "$FEEDS/fwlive"$'\n'
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "newline-suffixed link name must fail closed for a non-root runner"
	else
		ok "newline-suffixed link name fails closed for a non-root runner"
	fi
	# Case 35: fail-closed — the src-link exception is location-blind no more:
	# a link in dl/ targeting /work/fwlive/openwrt-feed must fail (luna r15).
	prep_workflow
	$SUDO rm -f "$FEEDS/fwlive"$'\n'
	$SUDO ln -s /work/fwlive/openwrt-feed "$DL/fwlive"
	$SUDO chown -h 1000:1000 "$DL/fwlive"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "dl/ link claiming the src-link target must fail closed"
	else
		ok "dl/ link claiming the src-link target fails closed"
	fi
	# Case 27: fail-closed — the index allowlist constrains the TARGET: an
	# absolute-target link (evil.index -> /etc/passwd) must not pass (luna r12).
	prep_workflow
	$SUDO rm -f "$FEEDS/fwlive" "$FEEDS/packages.index" "$FEEDS/packages.targetindex"
	$SUDO ln -s /etc/passwd "$FEEDS/evil.index"
	$SUDO chown -h 1000:1000 "$FEEDS/evil.index"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "absolute-target index symlink must fail closed for a non-root runner"
	else
		ok "absolute-target index symlink fails closed for a non-root runner"
	fi
	# ... and an escaping relative target (.. components) must not pass either.
	prep_workflow
	$SUDO rm -f "$FEEDS/evil.index"
	$SUDO ln -s ../../etc/passwd "$FEEDS/evil.targetindex"
	$SUDO chown -h 1000:1000 "$FEEDS/evil.targetindex"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "escaping index symlink must fail closed for a non-root runner"
	else
		ok "escaping index symlink fails closed for a non-root runner"
	fi
	# Case 29: OpenWrt `src-git --root=package base` (25.12/snapshot cells)
	# materializes feeds/base -> base_root/package — legit, must pass (luna r13;
	# base_root/package must exist for resolution-based validation).
	prep_workflow
	$SUDO rm -f "$FEEDS/evil.targetindex"
	$SUDO mkdir -p "$FEEDS/base_root/package"
	$SUDO chown -R 1000:1000 "$FEEDS/base_root"
	$SUDO ln -s base_root/package "$FEEDS/base"
	$SUDO chown -h 1000:1000 "$FEEDS/base"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL"; then
		ok "base_root/package link passes"
	else
		bad "legit base link must pass for a non-root runner"
	fi
	# Case 31: fail-closed — a newline-bearing override must not truncate the
	# component walk (luna r13 Minor).
	prep_workflow
	export OWRT_SDK_DL_CACHE=$'rel\n/evil'
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "newline-bearing override must fail closed for a non-root runner"
	else
		ok "newline-bearing override fails closed for a non-root runner"
	fi
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
	# Case 16 (root): regular file in place of the DL root fails closed.
	prep_workflow
	restore_root "$FEEDS"
	rm -rf "$DL"
	touch "$DL"
	chown 1000:1000 "$DL"
	chmod 644 "$DL"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "regular file as cache root must fail closed for root as well"
	else
		ok "regular file as cache root fails closed for root"
	fi
	# Case 19 (root): world-writable tree is REPAIRED (chmod strips g+w/o+w),
	# not accepted as-is (luna r9).
	prep_workflow
	rm -rf "$DL"
	mkdir -p "$DL"
	chown 1000:1000 "$DL"
	chmod -R 777 "$DL"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL"; then
		if [[ "$(stat -c %a "$DL")" == "755" ]]; then
			ok "root caller repairs world-writable cache (0755 after)"
		else
			bad "root caller must repair world-writable cache (got $(stat -c %a "$DL"))"
		fi
	else
		bad "root caller must succeed by repairing world-writable modes"
	fi
	# Case 22 (root): disallowed nested symlink fails closed for root too —
	# chmod cannot repair link modes, so the rescan still flags it (luna r10).
	prep_workflow
	ln -s /etc/passwd "$DL/evil"
	chown -h 1000:1000 "$DL/evil"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "disallowed nested symlink must fail closed for root as well"
	else
		ok "disallowed nested symlink fails closed for root"
	fi
	# Case 24 (root): world-writable regular file is REPAIRED to 0644.
	prep_workflow
	rm -f "$DL/evil"
	touch "$DL/ww"
	chown 1000:1000 "$DL/ww"
	chmod 666 "$DL/ww"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL"; then
		if [[ "$(stat -c %a "$DL/ww")" == "644" ]]; then
			ok "root caller repairs world-writable file (0644 after)"
		else
			bad "root caller must repair world-writable file (got $(stat -c %a "$DL/ww"))"
		fi
	else
		bad "root caller must succeed by repairing the world-writable file"
	fi
	# Case 26 (root): the legit src-link + OpenWrt index symlinks pass for root
	# too — the clean-tree chmod path must tolerate the links (luna r11 Nit).
	prep_workflow
	rm -f "$DL/ww"
	touch "$FEEDS/base.index"
	ln -s /work/fwlive/openwrt-feed "$FEEDS/fwlive"
	chown -h 1000:1000 "$FEEDS/fwlive"
	ln -s base.index "$FEEDS/packages.index"
	chown -h 1000:1000 "$FEEDS/packages.index"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL"; then
		ok "legit symlinks pass for root too"
	else
		bad "legit src-link + index symlinks must pass for root"
	fi
	# Case 28 (root): absolute-target index symlink fails closed for root too —
	# chmod cannot repair link targets, the rescan still flags it (luna r12).
	prep_workflow
	rm -f "$FEEDS/fwlive" "$FEEDS/packages.index"
	ln -s /etc/passwd "$FEEDS/evil.index"
	chown -h 1000:1000 "$FEEDS/evil.index"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "absolute-target index symlink must fail closed for root as well"
	else
		ok "absolute-target index symlink fails closed for root"
	fi
	# Case 30 (root): feeds/base -> base_root/package passes for root too.
	prep_workflow
	rm -f "$FEEDS/evil.index"
	mkdir -p "$FEEDS/base_root/package"
	ln -s base_root/package "$FEEDS/base"
	chown -h 1000:1000 "$FEEDS/base"
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL"; then
		ok "base_root/package link passes for root"
	else
		bad "legit base link must pass for root"
	fi
	# Case 36 (root): newline-suffixed link name fails closed for root too.
	prep_workflow
	rm -rf "$FEEDS/base" "$FEEDS/base_root"
	rm -f "$FEEDS/fwlive"
	ln -s /work/fwlive/openwrt-feed "$FEEDS/fwlive"
	chown -h 1000:1000 "$FEEDS/fwlive"
	ln -s /builder "$FEEDS/fwlive"$'\n'
	chown -h 1000:1000 "$FEEDS/fwlive"$'\n'
	if sdk_matrix_cache_dirs "$ROOT" "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null; then
		bad "newline-suffixed link name must fail closed for root as well"
	else
		ok "newline-suffixed link name fails closed for root"
	fi
fi

[ "$fail" = "0" ] || exit 1
echo "ALL TESTS PASSED"
