#!/usr/bin/env bash
# Run "make package/luci-app-fwlive/compile" inside the linux/amd64 SDK container.
#
# Default: SDK lives in the Docker named volume (required on macOS — case-sensitive).
#   ./scripts/docker-sdk-import-tar.sh … && ./scripts/docker-sdk-setup-feeds.sh
#
# Optional (Linux, case-sensitive host FS): bind-mount instead:
#   export USE_SDK_BIND=1 OPENWRT_SDK_MOUNT=/path/to/sdk
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

COMPOSE_BIND=( -f docker-compose.yml -f docker-compose.bind.yml )

run_make() {
	if [[ "${USE_SDK_BIND:-0}" == "1" ]]; then
		: "${OPENWRT_SDK_MOUNT:?Set OPENWRT_SDK_MOUNT to extracted SDK root for bind mount}"
		docker compose "${COMPOSE_BIND[@]}" run --rm sdk-bind make package/luci-app-fwlive/compile V=s "$@"
	else
		docker compose run --rm sdk-legacy make package/luci-app-fwlive/compile V=s "$@"
	fi
}

if [[ "${USE_SDK_BIND:-0}" == "1" ]]; then
	: "${OPENWRT_SDK_MOUNT:?}"
	if [[ ! -f "${OPENWRT_SDK_MOUNT}/Makefile" ]]; then
		echo "Not an SDK root: ${OPENWRT_SDK_MOUNT}" >&2
		exit 1
	fi
	if [[ ! -f "${OPENWRT_SDK_MOUNT}/feeds/fwlive/luci-app-fwlive/Makefile" && ! -f "${OPENWRT_SDK_MOUNT}/package/feeds/luci-app-fwlive/Makefile" ]]; then
		echo "luci-app-fwlive missing in SDK tree. Complete docs/minimal-build-sdk.md §2–4 on the host." >&2
		exit 1
	fi
else
	if ! docker compose run --rm sdk-legacy test -f /openwrt-sdk/Makefile; then
		echo "No SDK in Docker volume. Run:" >&2
		echo "  ./scripts/docker-sdk-import-tar.sh path/to/openwrt-sdk-*_musl.Linux-x86_64.tar.zst" >&2
		exit 1
	fi
	# feeds/<name>/ is often a symlink to src-link; find -P (default) does not descend into symlinked dirs
	if ! docker compose run --rm sdk-legacy sh -c 'find -L /openwrt-sdk -maxdepth 15 -path "*/luci-app-fwlive/Makefile" 2>/dev/null | grep -q .'; then
		echo "Feeds not configured in volume. Run: ./scripts/docker-sdk-setup-feeds.sh" >&2
		exit 1
	fi
fi

run_make "$@"
