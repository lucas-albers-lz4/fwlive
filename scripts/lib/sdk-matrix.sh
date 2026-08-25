#!/usr/bin/env bash
# OpenWrt SDK build matrix helpers (official ghcr.io/openwrt/sdk images).
# Source from other scripts; do not execute directly.
#
# Host/CI only (Linux builder) — Bash required (arrays, [[ ]], local, BASH_SOURCE,
# printf %q). This file never ships to the device.
# OpenWrt runtime shell (rpcd/libexec under openwrt-feed/) runs under BusyBox ash
# and must stay POSIX; do not copy Bash-isms from here into those scripts.
set -euo pipefail

SDK_MATRIX_TARGETS=(armsr-armv8 x86-64)
SDK_MATRIX_VERSIONS=(snapshot 25.12 24.10 23.05 22.03 21.02)

sdk_matrix_root() {
	local here
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	printf '%s' "$here"
}

# Normalize user-facing version keys to a release patch (empty = SNAPSHOT/latest).
sdk_matrix_version_patch() {
	case "$1" in
		snapshot | SNAPSHOT | latest | '') printf '%s' '' ;;
		25.12 | 25.12.*) printf '%s' '25.12.5' ;;
		24.10 | 24.10.*) printf '%s' '24.10.8' ;;
		23.05 | 23.05.*) printf '%s' '23.05.5' ;;
		22.03 | 22.03.*) printf '%s' '22.03.7' ;;
		21.02 | 21.02.*) printf '%s' '21.02.7' ;;
		*) printf '%s' "$1" ;;
	esac
}

sdk_matrix_version_label() {
	local patch
	patch="$(sdk_matrix_version_patch "$1")"
	if [[ -z "$patch" ]]; then
		printf '%s' 'snapshot'
	else
		printf '%s' "$patch"
	fi
}

sdk_matrix_image_tag() {
	local target="$1" version="$2" patch
	patch="$(sdk_matrix_version_patch "$version")"
	if [[ -z "$patch" ]]; then
		printf '%s' "$target"
	else
		printf '%s' "${target}-${patch}"
	fi
}

sdk_matrix_package_arch() {
	case "$1" in
		armsr-armv8) printf '%s' 'aarch64_generic' ;;
		x86-64) printf '%s' 'x86_64' ;;
		*) echo "unknown SDK target: $1 (expected armsr-armv8 or x86-64)" >&2; return 1 ;;
	esac
}

sdk_matrix_volume_name() {
	local target="$1" version="$2" patch tslug
	patch="$(sdk_matrix_version_patch "$version")"
	tslug="${target//-/_}"
	if [[ -z "$patch" ]]; then
		if [[ "$target" == "armsr-armv8" ]]; then
			printf '%s' 'openwrt_sdk_official'
		else
			printf '%s' "openwrt_sdk_${tslug}_snapshot"
		fi
	else
		local vslug="${patch//./_}"
		printf '%s' "openwrt_sdk_${tslug}_${vslug}"
	fi
}

sdk_matrix_resolve() {
	local target="${1:-armsr-armv8}" version="${2:-snapshot}"
	SDK_MATRIX_TARGET="$target"
	SDK_MATRIX_VERSION="$version"
	SDK_MATRIX_VERSION_LABEL="$(sdk_matrix_version_label "$version")"
	# Labels are path/shell data in compose scripts — reject metacharacters / traversal.
	case "$SDK_MATRIX_VERSION_LABEL" in
		'' | *[!a-zA-Z0-9._-]* | *..*)
			echo "sdk-matrix: invalid version label '$SDK_MATRIX_VERSION_LABEL'" >&2
			return 1
			;;
	esac
	SDK_MATRIX_IMAGE="ghcr.io/openwrt/sdk:$(sdk_matrix_image_tag "$target" "$version")"
	SDK_MATRIX_VOLUME="$(sdk_matrix_volume_name "$target" "$version")"
	SDK_MATRIX_PACKAGE_ARCH="$(sdk_matrix_package_arch "$target")"
	SDK_MATRIX_OUT_DIR="$(sdk_matrix_root)/out/${SDK_MATRIX_PACKAGE_ARCH}/${SDK_MATRIX_VERSION_LABEL}"
}

sdk_matrix_digest_cache_path() {
	local target="$1" version="$2" patch base
	patch="$(sdk_matrix_version_patch "$version")"
	base="${SDK_MATRIX_DIGEST_CACHE_DIR:-$(sdk_matrix_root)/out/.sdk-digests}"
	printf '%s' "${base}/${target}_${patch}"
}

sdk_matrix_inspect_repo_digest() {
	# Inspect already-local image ref; print matching RepoDigest or fail.
	# RepoDigests[0] is not trusted: match THIS repo prefix literally
	# (index()==1; dots in ghcr.io are not wildcards).
	local image="$1" repo digests digest id
	if [[ "$image" == *@sha256:* ]]; then
		repo="${image%%@*}"
	else
		repo="${image%%:*}"
	fi
	digests="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null || true)"
	digest="$(printf '%s\n' "$digests" | awk -v r="$repo" 'index($0, r "@sha256:") == 1 {print; exit}')"
	if [[ -n "$digest" ]]; then
		printf '%s' "$digest"
		return 0
	fi
	id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
	if [[ -n "$id" ]]; then
		digest="@sha256:${id#sha256:}"
		echo "WARNING: SDK image ${image} has no ${repo} RepoDigest (locally built?); recording image ID fallback ${digest}" >&2
		printf '%s' "$digest"
		return 0
	fi
	echo "ERROR: cannot resolve SDK image digest for ${image} (no ${repo} RepoDigest, no image ID)" >&2
	return 1
}

# Always re-resolve the registry tag. Skipping pull when the tag exists locally
# would record a stale digest if the tag moved upstream (luna fold).
# With target/version: resolve that cell then pull. With no args: pull the
# already-resolved SDK_MATRIX_IMAGE (do not default to another cell).
sdk_matrix_pull() {
	local target="${1:-}" version="${2:-}"
	if [[ -n "$target" ]]; then
		sdk_matrix_resolve "$target" "${version:?sdk_matrix_pull: version required with target}"
	else
		: "${SDK_MATRIX_IMAGE:?sdk_matrix_resolve first}"
	fi
	echo "→ pulling ${SDK_MATRIX_IMAGE}..." >&2
	docker pull "$SDK_MATRIX_IMAGE"
}

sdk_matrix_pull_and_pin() {
	# Pull the mutable tag once, pin SDK_MATRIX_IMAGE to repo@sha256, cache digest.
	local target="${1:-${SDK_MATRIX_TARGET:-}}" version="${2:-${SDK_MATRIX_VERSION:-}}" digest cache
	[[ -n "$target" && -n "$version" ]] || {
		echo "sdk-matrix: pull_and_pin needs target/version (or sdk_matrix_resolve first)" >&2
		return 1
	}
	sdk_matrix_pull "$target" "$version" || {
		echo "sdk-matrix: failed to pull ${SDK_MATRIX_IMAGE}" >&2
		return 1
	}
	digest="$(sdk_matrix_inspect_repo_digest "$SDK_MATRIX_IMAGE")" || return 1
	cache="$(sdk_matrix_digest_cache_path "$target" "$version")"
	mkdir -p "$(dirname "$cache")"
	printf '%s\n' "$digest" > "$cache"
	chmod 0644 "$cache" 2>/dev/null || true
	SDK_MATRIX_IMAGE="$digest"
	printf '%s' "$digest"
}

sdk_matrix_read_digest_cache() {
	# Print non-empty cached digest or return 1 (never print empty).
	local target="$1" version="$2" cache digest
	cache="$(sdk_matrix_digest_cache_path "$target" "$version")"
	[[ -f "$cache" ]] || return 1
	digest="$(tr -d ' \n\r\t' < "$cache")"
	[[ -n "$digest" ]] || return 1
	printf '%s' "$digest"
}

# Prefer a pin file from sdk_matrix_pull_and_pin so write_manifest does not
# re-pull a possibly moved tag. No-arg form uses the already-resolved cell.
sdk_matrix_image_digest() {
	local target="${1:-${SDK_MATRIX_TARGET:-}}" version="${2:-${SDK_MATRIX_VERSION:-}}" digest
	[[ -n "$target" && -n "$version" ]] || {
		echo "ERROR: cannot resolve SDK image digest (sdk_matrix_resolve first)" >&2
		return 1
	}
	if digest="$(sdk_matrix_read_digest_cache "$target" "$version")"; then
		printf '%s' "$digest"
		return 0
	fi
	sdk_matrix_pull_and_pin "$target" "$version"
}

sdk_matrix_validate_target() {
	local t
	for t in "${SDK_MATRIX_TARGETS[@]}"; do
		[[ "$1" == "$t" ]] && return 0
	done
	echo "invalid --target $1 (choose: ${SDK_MATRIX_TARGETS[*]})" >&2
	return 1
}

sdk_matrix_validate_version() {
	local v
	for v in "${SDK_MATRIX_VERSIONS[@]}"; do
		[[ "$1" == "$v" || "$1" == "$(sdk_matrix_version_patch "$1")" ]] && return 0
	done
	case "$1" in
		25.12.* | 24.10.* | 23.05.* | 22.03.* | 21.02.*) return 0 ;;
	esac
	echo "invalid --version $1 (choose: ${SDK_MATRIX_VERSIONS[*]})" >&2
	return 1
}

sdk_matrix_cache_dirs() {
	local root="$1" version_label="$2" dl_uid dl_gid feeds_uid feeds_gid scan_out scan_rc
	SDK_MATRIX_DL_CACHE="${OWRT_SDK_DL_CACHE:-${root}/.ci-sdk-cache/dl}"
	SDK_MATRIX_FEEDS_CACHE="${OWRT_SDK_FEEDS_CACHE:-${root}/.ci-sdk-cache/feeds/${version_label}}"
	mkdir -p "$SDK_MATRIX_DL_CACHE" "$SDK_MATRIX_FEEDS_CACHE"
	# buildbot (uid 1000) must write bind mounts; Actions runner is often 1001.
	# Least privilege: own as buildbot; owner rwx only for write; group/other read+traverse.
	# Fail closed (no world-writable, no ACL mask footguns). CI pre-chowns via
	# sudo in the workflow "Prepare SDK cache dirs" step, so by the time we run
	# the dirs are usually already buildbot-owned — and a non-root runner CANNOT
	# chown uid-1000-owned files (EPERM, v0.1.36 publish regression). Skip the
	# mutation only when BOTH cache trees are fully buildbot-owned; enforce when
	# we can (root); otherwise fail closed.
	dl_uid="$(stat -c %u "$SDK_MATRIX_DL_CACHE" 2>/dev/null)" || return 1
	dl_gid="$(stat -c %g "$SDK_MATRIX_DL_CACHE" 2>/dev/null)" || return 1
	feeds_uid="$(stat -c %u "$SDK_MATRIX_FEEDS_CACHE" 2>/dev/null)" || return 1
	feeds_gid="$(stat -c %g "$SDK_MATRIX_FEEDS_CACHE" 2>/dev/null)" || return 1
	if [[ "$dl_uid" != "1000" || "$dl_gid" != "1000" || "$feeds_uid" != "1000" || "$feeds_gid" != "1000" ]]; then
		if ! chown -R 1000:1000 "$SDK_MATRIX_DL_CACHE" "$SDK_MATRIX_FEEDS_CACHE" 2>/dev/null; then
			echo "sdk-matrix: cannot chown .ci-sdk-cache to buildbot (uid 1000)" >&2
			echo "sdk-matrix: run once: sudo chown -R 1000:1000 .ci-sdk-cache && sudo chmod -R u=rwX,g=rX,o=rX .ci-sdk-cache" >&2
			return 1
		fi
	fi
	# Nested entries must match too, for root AND non-root callers (a root
	# caller would otherwise chmod a stray wrong-owned file into a state uid
	# 1000 cannot write). Scan errors (unreadable subtree) fail closed — a
	# hidden error must never read as a clean tree.
	scan_rc=0
	scan_out="$(find "$SDK_MATRIX_DL_CACHE" "$SDK_MATRIX_FEEDS_CACHE" \
		\( ! -user 1000 -o ! -group 1000 \) -print -quit 2>&1)" || scan_rc=$?
	if [[ "$scan_rc" -ne 0 ]]; then
		echo "sdk-matrix: cannot verify .ci-sdk-cache ownership (scan failed)" >&2
		echo "sdk-matrix: run once: sudo chown -R 1000:1000 .ci-sdk-cache && sudo chmod -R u=rwX,g=rX,o=rX .ci-sdk-cache" >&2
		return 1
	fi
	if [[ -n "$scan_out" ]]; then
		# Wrong-owned entries found: root repairs recursively (tree becomes
		# uniform); a non-root caller cannot fix them — fail closed.
		if [[ "$(id -u)" -eq 0 ]]; then
			if ! chown -R 1000:1000 "$SDK_MATRIX_DL_CACHE" "$SDK_MATRIX_FEEDS_CACHE" 2>/dev/null; then
				echo "sdk-matrix: cannot chown .ci-sdk-cache to buildbot (uid 1000)" >&2
				echo "sdk-matrix: run once: sudo chown -R 1000:1000 .ci-sdk-cache && sudo chmod -R u=rwX,g=rX,o=rX .ci-sdk-cache" >&2
				return 1
			fi
		else
			echo "sdk-matrix: cannot chown .ci-sdk-cache to buildbot (uid 1000)" >&2
			echo "sdk-matrix: run once: sudo chown -R 1000:1000 .ci-sdk-cache && sudo chmod -R u=rwX,g=rX,o=rX .ci-sdk-cache" >&2
			return 1
		fi
	fi
	# chmod only as root or the owner — the workflow's sudo chown already set
	# modes in CI, and a non-owner runner cannot chmod either.
	if [[ "$(id -u)" -eq 0 || "$(stat -c %u "$SDK_MATRIX_DL_CACHE" 2>/dev/null)" == "$(id -u)" ]]; then
		if ! chmod -R u=rwX,g=rX,o=rX "$SDK_MATRIX_DL_CACHE" "$SDK_MATRIX_FEEDS_CACHE"; then
			echo "sdk-matrix: chmod failed on .ci-sdk-cache" >&2
			return 1
		fi
	fi
}

sdk_matrix_compose_run() {
	local root
	root="$(sdk_matrix_root)"
	sdk_matrix_cache_dirs "$root" "$SDK_MATRIX_VERSION_LABEL"
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		OWRT_SDK_DL_CACHE="$SDK_MATRIX_DL_CACHE" \
		OWRT_SDK_FEEDS_CACHE="$SDK_MATRIX_FEEDS_CACHE" \
		docker compose run --rm sdk "$@"
	)
}

sdk_matrix_feeds_lock_path() {
	local label
	label="$(sdk_matrix_version_label "$1")"
	printf '%s/scripts/feeds.lock/%s/feeds.conf' "$(sdk_matrix_root)" "$label"
}

sdk_matrix_feeds_ready() {
	# Require .config, upstream feed .git dirs, package present, and lock stamp
	# matching the pinned feeds.conf so a restored cache cannot skip refresh
	# after pin changes or partial-cache failure.
	# Pass version label as \$1 (data), never interpolate into shell source.
	sdk_matrix_compose_run sh -c '
		test -f /builder/.config || exit 1
		lock=/work/fwlive/scripts/feeds.lock/$1/feeds.conf
		stamp=/builder/feeds/.fwlive-feeds.lock.sha
		test -f "$lock" && test -f "$stamp" || exit 1
		cur=$(sha256sum "$lock" | awk "{print \$1}")
		old=$(cat "$stamp")
		[ -n "$cur" ] && [ "$cur" = "$old" ] || exit 1
		{ [ -d /builder/feeds/base/.git ] || [ -d /builder/feeds/base_root/.git ]; } || exit 1
		[ -d /builder/feeds/packages/.git ] || exit 1
		[ -d /builder/feeds/luci/.git ] || exit 1
		find -L /builder/feeds -maxdepth 8 -path "*/luci-app-fwlive/Makefile" 2>/dev/null | grep -q .
	' sh "$SDK_MATRIX_VERSION_LABEL" 2>/dev/null
}

sdk_matrix_feeds_base_packages() {
	local label
	label="$(sdk_matrix_version_label "$SDK_MATRIX_VERSION")"
	case "$label" in
		21.02.*)
			printf '%s' 'liblua libubox libubus libuci rpcd'
			;;
		*)
			printf '%s' 'liblua libucode libubox libubus libuci rpcd'
			;;
	esac
}

sdk_matrix_feeds_setup() {
	local lock_path base_pkgs base_pkgs_q
	lock_path="$(sdk_matrix_feeds_lock_path "$SDK_MATRIX_VERSION")"
	base_pkgs="$(sdk_matrix_feeds_base_packages)"
	# Escape each package so they remain separate argv tokens inside sh -ec "…".
	# shellcheck disable=SC2086 # intentional word-split of space-separated package list
	base_pkgs_q="$(printf '%q ' ${base_pkgs})"
	[[ -f "$lock_path" ]] || {
		echo "missing pinned feeds lock: $lock_path" >&2
		return 1
	}
	# Retry feeds update: git.openwrt.org (and mirrors) drop TLS under CI load.
	# HTTP/1.1 reduces curl-35 / gnutls_handshake failures (openwrt/openwrt#21854).
	# Wipe partial clones on failure; require .git dirs so soft exit-0 without clone fails.
	# \$1 = version label (data); base package list is host-escaped into the script body.
	sdk_matrix_compose_run sh -ec "
		label=\$1
		cd /builder
		export TERM=dumb
		if [ ! -f Makefile ]; then echo 'Running ./setup.sh ...'; ./setup.sh; fi
		test -f Makefile

		cp /work/fwlive/scripts/feeds.lock/\$label/feeds.conf feeds.conf
		grep -q '^src-link fwlive' feeds.conf || echo 'src-link fwlive /work/fwlive/openwrt-feed' >> feeds.conf

		git config --global http.version HTTP/1.1 || true

		ok=0
		i=1
		while [ \"\$i\" -le 3 ]; do
			if ./scripts/feeds update base luci packages \\
				&& { [ -d feeds/base/.git ] || [ -d feeds/base_root/.git ]; } \\
				&& [ -d feeds/packages/.git ] \\
				&& [ -d feeds/luci/.git ]; then
				ok=1
				break
			fi
			echo \"feeds update failed (attempt \$i/3); wiping partial clones\" >&2
			rm -rf feeds/base feeds/base_root feeds/packages feeds/luci
			if [ \"\$i\" -eq 3 ]; then
				break
			fi
			sleep \$((i * 5))
			i=\$((i + 1))
		done
		[ \"\$ok\" -eq 1 ] || { echo 'feeds update failed after 3 attempts' >&2; exit 1; }

		./scripts/feeds install -p base ${base_pkgs_q}
		./scripts/feeds install luci-base
		./scripts/feeds update fwlive
		./scripts/feeds install luci-app-fwlive
		rm -rf tmp
		make defconfig
		sha256sum /work/fwlive/scripts/feeds.lock/\$label/feeds.conf \
			| awk '{print \$1}' > feeds/.fwlive-feeds.lock.sha
	" sh "$SDK_MATRIX_VERSION_LABEL"
}

# Epoch for reproducible package timestamps (override via SOURCE_DATE_EPOCH env).
sdk_matrix_source_date_epoch() {
	if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
		printf '%s' "$SOURCE_DATE_EPOCH"
		return
	fi
	local root epoch
	root="$(sdk_matrix_root)"
	if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		epoch="$(git -C "$root" log -1 --format=%ct 2>/dev/null || true)"
		if [[ -n "$epoch" ]]; then
			printf '%s' "$epoch"
			return
		fi
	fi
	printf '%s' '0'
}

# Parallel make jobs on the build host (override: OWRT_MAKE_JOBS=16).
sdk_matrix_default_jobs() {
	if [[ -n "${OWRT_MAKE_JOBS:-}" ]]; then
		printf '%s' "$OWRT_MAKE_JOBS"
		return
	fi
	local n=4
	if command -v nproc >/dev/null 2>&1; then
		n="$(nproc)"
	fi
	# Balanced default on multi-core hosts; cap to avoid runaway load in CI/small VMs.
	if (( n > 16 )); then
		n=16
	elif (( n >= 8 )); then
		n=8
	fi
	printf '%s' "$n"
}

sdk_matrix_make() {
	local -a args=() quoted
	local jobs has_j=0

	sdk_matrix_feeds_ready \
		|| { echo "Run: ./scripts/docker-sdk.sh setup --target $SDK_MATRIX_TARGET --version $SDK_MATRIX_VERSION" >&2; return 1; }

	jobs="$(sdk_matrix_default_jobs)"
	for arg in "$@"; do
		case "$arg" in
			-j | -j*) has_j=1 ;;
		esac
		args+=("$arg")
	done
	[[ $has_j -eq 0 ]] && args=(-j"$jobs" "${args[@]}")
	quoted="$(printf ' %q' "${args[@]}")"
	local sde
	sde="$(sdk_matrix_source_date_epoch)"
	echo "→ SOURCE_DATE_EPOCH=${sde} make package/luci-app-fwlive/compile V=s${quoted}" >&2
	sdk_matrix_compose_run sh -ec "cd /builder && export TERM=dumb SOURCE_DATE_EPOCH=${sde} && make package/luci-app-fwlive/compile V=s${quoted}"
}

sdk_matrix_clean_package() {
	sdk_matrix_feeds_ready \
		|| { echo "Run: ./scripts/docker-sdk.sh setup --target $SDK_MATRIX_TARGET --version $SDK_MATRIX_VERSION" >&2; return 1; }
	sdk_matrix_compose_run sh -ec 'cd /builder && export TERM=dumb && make package/luci-app-fwlive/clean V=s'
}

sdk_matrix_copy_out() {
	local root out_mount dest_host
	root="$(sdk_matrix_root)"
	out_mount="${root}/out"
	dest_host="${out_mount}/${SDK_MATRIX_PACKAGE_ARCH}/${SDK_MATRIX_VERSION_LABEL}"
	mkdir -p "$dest_host"
	# SDK image runs as buildbot (uid 1000); GHA workspace is often uid 1001 — copy as root.
	# Pass the same dl/feeds bind mounts as compose_run so defaults do not clobber /builder.
	sdk_matrix_cache_dirs "$root" "$SDK_MATRIX_VERSION_LABEL"
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		OWRT_SDK_DL_CACHE="$SDK_MATRIX_DL_CACHE" \
		OWRT_SDK_FEEDS_CACHE="$SDK_MATRIX_FEEDS_CACHE" \
		docker compose run --rm --user root -v "${out_mount}:/out" sdk sh -ec "
			dest=/out/${SDK_MATRIX_PACKAGE_ARCH}/${SDK_MATRIX_VERSION_LABEL}
			mkdir -p \"\$dest\"
			if [ -d /builder/bin/packages/${SDK_MATRIX_PACKAGE_ARCH}/fwlive ]; then
				cp -a /builder/bin/packages/${SDK_MATRIX_PACKAGE_ARCH}/fwlive \"\$dest/\"
			else
				cp -a /builder/bin/packages/${SDK_MATRIX_PACKAGE_ARCH}/. \"\$dest/\" 2>/dev/null || true
			fi
			chmod -R a+rX /out
			ls -la \"\$dest\"/fwlive/luci-app-fwlive* 2>/dev/null || ls -la \"\$dest\"/luci-app-fwlive* 2>/dev/null || true
		"
	)
	echo "Packages under: ${SDK_MATRIX_OUT_DIR}/" >&2
}

sdk_matrix_print_row() {
	printf '  %-14s %-10s  %s\n' "$1" "$2" "$(sdk_matrix_image_tag "$1" "$2")"
}

sdk_matrix_list() {
	echo "SDK build matrix (Linux x86_64 host → ghcr.io/openwrt/sdk):" >&2
	echo "  target         version    image tag" >&2
	local target version
	for target in "${SDK_MATRIX_TARGETS[@]}"; do
		for version in "${SDK_MATRIX_VERSIONS[@]}"; do
			sdk_matrix_print_row "$target" "$version"
		done
	done
}
