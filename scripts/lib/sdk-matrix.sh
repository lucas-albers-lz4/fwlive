#!/usr/bin/env bash
# OpenWrt SDK build matrix helpers (official ghcr.io/openwrt/sdk images).
# Source from other scripts; do not execute directly.
set -euo pipefail

SDK_MATRIX_TARGETS=(armsr-armv8 x86-64)
SDK_MATRIX_VERSIONS=(snapshot 24.10 23.05)

sdk_matrix_root() {
	local here
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	printf '%s' "$here"
}

# Normalize user-facing version keys to a release patch (empty = SNAPSHOT/latest).
sdk_matrix_version_patch() {
	case "$1" in
		snapshot | SNAPSHOT | latest | '') printf '%s' '' ;;
		24.10 | 24.10.*) printf '%s' '24.10.5' ;;
		23.05 | 23.05.*) printf '%s' '23.05.5' ;;
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
		24.10.* | 23.05.*) return 0 ;;
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

sdk_matrix_feeds_ready() {
	sdk_matrix_compose_run sh -c \
		'test -f /builder/.config && find -L /builder/feeds -maxdepth 8 -path "*/luci-app-fwlive/Makefile" 2>/dev/null | grep -q .' \
		2>/dev/null
}

sdk_matrix_feeds_setup() {
	sdk_matrix_compose_run sh -ec '
		cd /builder
		export TERM=dumb
		if [ ! -f Makefile ]; then echo "Running ./setup.sh ..."; ./setup.sh; fi
		test -f Makefile

		if [ -f feeds.conf.default ] && ! grep -q "^src-git.*base" feeds.conf 2>/dev/null; then
			cp feeds.conf.default feeds.conf
		fi
		grep -q "^src-link fwview" feeds.conf 2>/dev/null || echo "src-link fwview /work/fwview/openwrt-feed" >> feeds.conf

		./scripts/feeds update base luci packages
		./scripts/feeds install -p base liblua libucode libubox libubus libuci rpcd
		./scripts/feeds install luci-base
		./scripts/feeds update fwview
		./scripts/feeds install luci-app-fwlive
		rm -rf tmp
		make defconfig
	'
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
	echo "→ make package/luci-app-fwlive/compile V=s${quoted}" >&2
	sdk_matrix_compose_run sh -ec "cd /builder && export TERM=dumb && make package/luci-app-fwlive/compile V=s${quoted}"
}

sdk_matrix_copy_out() {
	local root out_mount
	root="$(sdk_matrix_root)"
	out_mount="${root}/out"
	mkdir -p "$out_mount"
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		docker compose run --rm -v "${out_mount}:/out" sdk sh -ec "
			dest=/out/${SDK_MATRIX_PACKAGE_ARCH}/${SDK_MATRIX_VERSION_LABEL}
			mkdir -p \"\$dest\"
			if [ -d /builder/bin/packages/${SDK_MATRIX_PACKAGE_ARCH}/fwview ]; then
				cp -a /builder/bin/packages/${SDK_MATRIX_PACKAGE_ARCH}/fwview \"\$dest/\"
			else
				cp -a /builder/bin/packages/${SDK_MATRIX_PACKAGE_ARCH}/. \"\$dest/\" 2>/dev/null || true
			fi
			ls -la \"\$dest\"/fwview/luci-app-fwlive* 2>/dev/null || ls -la \"\$dest\"/luci-app-fwlive* 2>/dev/null || true
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
