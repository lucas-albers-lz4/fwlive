#!/usr/bin/env bash
# Run the pinned OpenWrt SDK apk-tools v3 binary (never host `apk`).
# Source from tests and later feed-index dumps (#421); do not execute directly.
#
# Host/CI only (Linux builder) — Bash required. This file never ships to the
# device.
set -euo pipefail

# shellcheck source=sdk-matrix.sh
source "$(dirname "${BASH_SOURCE[0]}")/sdk-matrix.sh"

sdk_apk_root() {
	sdk_matrix_root
}

# Prefer an explicit image, then the digest pin cache, then the resolved tag.
sdk_apk_image() {
	local target="${1:-x86-64}" version="${2:-25.12}" digest
	if [[ -n "${FWLIVE_SDK_APK_IMAGE:-}" ]]; then
		printf '%s' "$FWLIVE_SDK_APK_IMAGE"
		return 0
	fi
	sdk_matrix_resolve "$target" "$version"
	if digest="$(sdk_matrix_read_digest_cache "$target" "$version")"; then
		printf '%s' "$digest"
		return 0
	fi
	printf '%s' "$SDK_MATRIX_IMAGE"
}

# docker run wrapper. Extra --volume HOST:CONTAINER[:opts] flags are for
# #421 packages.adb dumps as well as package adbdump.
#
# Usage:
#   sdk_apk_run [--version 25.12] [--target x86-64] [--volume host:dest[:opts] ...] -- <apk-args>
sdk_apk_run() {
	local version=25.12 target=x86-64
	local volumes=() image
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--version)
				version="$2"
				shift 2
				;;
			--target)
				target="$2"
				shift 2
				;;
			--volume | -v)
				volumes+=(-v "$2")
				shift 2
				;;
			--)
				shift
				break
				;;
			-*)
				echo "sdk-apk: unknown option: $1" >&2
				return 1
				;;
			*)
				break
				;;
		esac
	done
	image="$(sdk_apk_image "$target" "$version")"
	command -v docker >/dev/null 2>&1 || {
		echo "sdk-apk: docker is required to run pinned SDK apk (host apk is not used)" >&2
		return 1
	}
	docker run --rm --network none --user "$(id -u):$(id -g)" \
		"${volumes[@]}" \
		"$image" \
		/builder/staging_dir/host/bin/apk --allow-untrusted "$@"
}

# Dump ADB metadata for a package or index (packages.adb). Default format json.
# Usage: sdk_apk_adbdump [--format json|yaml] [--version 25.12] [--target x86-64] FILE
sdk_apk_adbdump() {
	local format=json version=25.12 target=x86-64 src="" dir base
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--format)
				format="$2"
				shift 2
				;;
			--version)
				version="$2"
				shift 2
				;;
			--target)
				target="$2"
				shift 2
				;;
			--)
				shift
				break
				;;
			-*)
				echo "sdk-apk: unknown option: $1" >&2
				return 1
				;;
			*)
				src="$1"
				shift
				break
				;;
		esac
	done
	[[ -n "$src" ]] || {
		echo "sdk-apk: adbdump requires a file" >&2
		return 1
	}
	[[ -f "$src" ]] || {
		echo "sdk-apk: file not found: $src" >&2
		return 1
	}
	dir="$(cd "$(dirname "$src")" && pwd)"
	base="$(basename "$src")"
	sdk_apk_run --version "$version" --target "$target" \
		--volume "${dir}:/work:ro" -- \
		adbdump --format "$format" "/work/${base}" "$@"
}
