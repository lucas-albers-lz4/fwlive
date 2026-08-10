#!/usr/bin/env bash
# OpenWrt SDK build matrix helpers (official ghcr.io/openwrt/sdk images).
# Source from other scripts; do not execute directly.
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
		25.12 | 25.12.*) printf '%s' '25.12.0' ;;
		24.10 | 24.10.*) printf '%s' '24.10.5' ;;
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
	SDK_MATRIX_IMAGE="ghcr.io/openwrt/sdk:$(sdk_matrix_image_tag "$target" "$version")"
	SDK_MATRIX_VOLUME="$(sdk_matrix_volume_name "$target" "$version")"
	SDK_MATRIX_PACKAGE_ARCH="$(sdk_matrix_package_arch "$target")"
	SDK_MATRIX_OUT_DIR="$(sdk_matrix_root)/out/${SDK_MATRIX_PACKAGE_ARCH}/${SDK_MATRIX_VERSION_LABEL}"
}

# Ensure the resolved cell's SDK image is present locally. Idempotent: docker
# pull is a no-op for an already-present tag, so on a machine that already
# built against the image this never re-fetches (and cannot drift to a tag that
# moved upstream between build and release). Pull must happen before digest
# resolution — the recorded digest is the image actually used for the build.
sdk_matrix_pull() {
	local image="${SDK_MATRIX_IMAGE:?sdk_matrix_resolve first}"
	if ! docker image inspect "$image" >/dev/null 2>&1; then
		echo "→ pulling ${image}..." >&2
		docker image pull "$image"
	fi
}

# Resolve the immutable digest of the SDK image actually used for this cell.
# The tag (SDK_MATRIX_IMAGE) is mutable; the digest makes a release
# attributable to the exact image it was built from.
#
# Source: `docker image inspect --format '{{index .RepoDigests 0}}'` after the
# image is pulled (registry images carry repo@sha256:… RepoDigests).
# Fallback: a locally built / registry-less image has empty RepoDigests — record
# `@sha256:<image ID>` and warn. An empty digest is never recorded silently: if
# neither source yields a digest this returns non-zero (release manifest aborts).
sdk_matrix_image_digest() {
	local image="${SDK_MATRIX_IMAGE:?sdk_matrix_resolve first}" digest id
	sdk_matrix_pull
	digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)"
	if [[ -z "$digest" ]]; then
		id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
		if [[ -z "$id" ]]; then
			echo "ERROR: cannot resolve SDK image digest for ${image} (no RepoDigests, no image ID)" >&2
			return 1
		fi
		digest="@${id}"
		echo "WARNING: SDK image ${image} has no RepoDigests (locally built?); recording image ID fallback ${digest}" >&2
	fi
	printf '%s' "$digest"
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

sdk_matrix_compose_run() {
	local root
	root="$(sdk_matrix_root)"
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		docker compose run --rm sdk "$@"
	)
}

sdk_matrix_feeds_lock_path() {
	local label
	label="$(sdk_matrix_version_label "$1")"
	printf '%s/scripts/feeds.lock/%s/feeds.conf' "$(sdk_matrix_root)" "$label"
}

sdk_matrix_feeds_ready() {
	sdk_matrix_compose_run sh -c \
		'test -f /builder/.config && find -L /builder/feeds -maxdepth 8 -path "*/luci-app-fwlive/Makefile" 2>/dev/null | grep -q .' \
		2>/dev/null
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
	local lock_path base_pkgs
	lock_path="$(sdk_matrix_feeds_lock_path "$SDK_MATRIX_VERSION")"
	base_pkgs="$(sdk_matrix_feeds_base_packages)"
	[[ -f "$lock_path" ]] || {
		echo "missing pinned feeds lock: $lock_path" >&2
		return 1
	}
	# Retry feeds update: git.openwrt.org (and mirrors) drop TLS under CI load.
	# HTTP/1.1 reduces curl-35 / gnutls_handshake failures (openwrt/openwrt#21854).
	sdk_matrix_compose_run sh -ec "
		cd /builder
		export TERM=dumb
		if [ ! -f Makefile ]; then echo 'Running ./setup.sh ...'; ./setup.sh; fi
		test -f Makefile

		cp /work/fwlive/scripts/feeds.lock/${SDK_MATRIX_VERSION_LABEL}/feeds.conf feeds.conf
		grep -q '^src-link fwlive' feeds.conf || echo 'src-link fwlive /work/fwlive/openwrt-feed' >> feeds.conf

		git config --global http.version HTTP/1.1 || true

		ok=0
		for i in 1 2 3; do
			if ./scripts/feeds update base luci packages; then
				ok=1
				break
			fi
			echo \"feeds update attempt \$i failed; retrying in \$((i * 5))s...\" >&2
			sleep \$((i * 5))
		done
		test \"\$ok\" -eq 1

		./scripts/feeds install -p base ${base_pkgs}
		./scripts/feeds install luci-base
		./scripts/feeds update fwlive
		./scripts/feeds install luci-app-fwlive
		rm -rf tmp
		make defconfig
	"
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
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
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
