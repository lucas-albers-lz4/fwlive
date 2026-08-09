#!/usr/bin/env bash
# Persist OpenWrt SDK feed clones + dl/ across GitHub Actions runs (#122).
#
# Named docker volumes are empty on every fresh runner; this caches only the
# heavy network-fetched trees (feeds + dl), not the full toolchain, keyed from
# the workflow via hashFiles('scripts/feeds.lock/**').
#
# Usage:
#   ./scripts/ci-cache-sdk-feeds.sh restore <cache-dir>
#   ./scripts/ci-cache-sdk-feeds.sh save <cache-dir>
#
# Volumes covered: x86-64 publish matrix (21.02 … 25.12).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/sdk-matrix.sh
source "$ROOT/scripts/lib/sdk-matrix.sh"

ci_cache_publish_volumes() {
	local ver vol
	for ver in 21.02 22.03 23.05 24.10 25.12; do
		sdk_matrix_resolve x86-64 "$ver"
		printf '%s\n' "$SDK_MATRIX_VOLUME"
	done
}

ci_cache_ensure_volume() {
	docker volume inspect "$1" >/dev/null 2>&1 || docker volume create "$1" >/dev/null
}

ci_cache_restore() {
	local cache_dir="$1" vol src
	[[ -d "$cache_dir" ]] || {
		echo "ci-cache-sdk-feeds: no cache dir at $cache_dir (cold start)" >&2
		return 0
	}
	while IFS= read -r vol; do
		src="${cache_dir}/${vol}"
		[[ -d "$src" ]] || continue
		ci_cache_ensure_volume "$vol"
		echo "ci-cache-sdk-feeds: restore $vol" >&2
		docker run --rm \
			-v "${vol}:/builder" \
			-v "${src}:/cache:ro" \
			alpine:3.20 \
			sh -ec '
				mkdir -p /builder/dl /builder/feeds
				if [ -d /cache/dl ]; then cp -a /cache/dl/. /builder/dl/; fi
				if [ -d /cache/feeds ]; then cp -a /cache/feeds/. /builder/feeds/; fi
			'
	done < <(ci_cache_publish_volumes)
}

ci_cache_save() {
	local cache_dir="$1" vol dest
	mkdir -p "$cache_dir"
	while IFS= read -r vol; do
		docker volume inspect "$vol" >/dev/null 2>&1 || continue
		dest="${cache_dir}/${vol}"
		rm -rf "$dest"
		mkdir -p "$dest"
		echo "ci-cache-sdk-feeds: save $vol" >&2
		docker run --rm \
			-v "${vol}:/builder:ro" \
			-v "${dest}:/cache" \
			alpine:3.20 \
			sh -ec '
				if [ -d /builder/dl ]; then cp -a /builder/dl /cache/; fi
				if [ -d /builder/feeds ]; then cp -a /builder/feeds /cache/; fi
			'
	done < <(ci_cache_publish_volumes)
}

main() {
	local cmd="${1:-}" cache_dir="${2:-}"
	[[ -n "$cmd" && -n "$cache_dir" ]] || {
		echo "usage: $0 restore|save <cache-dir>" >&2
		return 2
	}
	case "$cmd" in
		restore) ci_cache_restore "$cache_dir" ;;
		save) ci_cache_save "$cache_dir" ;;
		*)
			echo "unknown command: $cmd (expected restore|save)" >&2
			return 2
			;;
	esac
}

main "$@"
