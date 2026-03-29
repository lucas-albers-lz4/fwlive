#!/usr/bin/env bash
# Load an OpenWrt SDK .tar.zst into the Docker named volume (case-sensitive; required on macOS).
# Usage: ./scripts/docker-sdk-import-tar.sh /path/to/openwrt-sdk-*_musl.Linux-x86_64.tar.zst
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAR="${1:?Usage: $0 /path/to/openwrt-sdk-....tar.zst}"

if [[ ! -f "$TAR" ]]; then
	echo "Not a file: $TAR" >&2
	exit 1
fi

TAR_ABS="$(cd "$(dirname "$TAR")" && pwd)/$(basename "$TAR")"

cd "$ROOT"
docker compose build sdk

docker compose run --rm -v "${TAR_ABS}:/sdk.tar.zst:ro" sdk bash -ec '
	find /openwrt-sdk -mindepth 1 -maxdepth 1 -exec rm -rf {} +
	if ! tar -C /openwrt-sdk -xf /sdk.tar.zst --strip-components=1 2>/dev/null; then
		tmp=$(mktemp -d)
		tar -C "$tmp" -xf /sdk.tar.zst
		inner=$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)
		test -n "$inner" && test -f "$inner/Makefile"
		cp -a "$inner"/. /openwrt-sdk/
		rm -rf "$tmp"
	fi
	test -f /openwrt-sdk/Makefile
'

echo "SDK is in Docker volume openwrt_sdk. Next: ./scripts/docker-sdk-setup-feeds.sh (first time)" >&2
