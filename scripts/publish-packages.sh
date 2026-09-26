#!/usr/bin/env bash
# Stage signed opkg/apk feed directories for GitHub Pages deploy.
#
#   OPKG_FEED_SECRET_KEY=./opkg-secret.key \
#   OPKG_FEED_PUBLIC_KEY=./public.key \
#   APK_FEED_SECRET_KEY=./apk-secret.rsa \
#   APK_FEED_PUBLIC_KEY=./fwlive-feed.rsa.pub \
#     ./scripts/publish-packages.sh feed-staging
#     ./scripts/publish-packages.sh --allow-outside /tmp/feed-staging
#
# Prerequisite: ./scripts/docker-sdk.sh build --target x86-64 for 23.05, 24.10, 25.12
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"

STAGING="feed-staging"
ALLOW_OUTSIDE=0
GIT_TAG="${FWLIVE_GIT_TAG:-$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null || git -C "$ROOT" rev-parse --short HEAD)}"

for arg in "$@"; do
	case "$arg" in
		-h | --help)
			sed -n '1,12p' "$0"
			exit 0
			;;
		--allow-outside)
			ALLOW_OUTSIDE=1
			;;
		-*)
			echo "unknown arg: $arg" >&2
			exit 1
			;;
		*)
			STAGING="$arg"
			;;
	esac
done

PKG_VER="${FWLIVE_PKG_VERSION:-$(sed -n 's/^PKG_VERSION:=//p' "${ROOT}/openwrt-feed/luci-app-fwlive/Makefile" | head -1)}"
[[ -n "$PKG_VER" ]] || {
	echo "PKG_VERSION missing in openwrt-feed/luci-app-fwlive/Makefile" >&2
	exit 1
}
export FWLIVE_PKG_VERSION="$PKG_VER"

mkdir -p "$STAGING"
STAGING="$(feed_publish_assert_staging_clearable "$STAGING" "$ALLOW_OUTSIDE")"

rm -rf "$STAGING"
mkdir -p "$STAGING"

echo "== publish-packages → ${STAGING} (tag: ${GIT_TAG}) ==" >&2

for ver in 23.05 24.10; do
	echo "→ staging opkg feed ${ver}..." >&2
	feed_publish_stage_opkg "$ver" "$STAGING" "$PKG_VER"
done

echo "→ staging apk feed 25.12..." >&2
feed_publish_stage_apk 25.12 "$STAGING" "$PKG_VER"

feed_publish_copy_keys "$STAGING"
feed_publish_write_manifest "$STAGING" "$GIT_TAG" "$PKG_VER"

if [[ -f "${ROOT}/packages-repo/README.md" ]]; then
	cp "${ROOT}/packages-repo/README.md" "${STAGING}/README.md"
fi

echo "== staged feed ==" >&2
find "$STAGING" -type f | sort
echo "Ready to deploy ${STAGING}/ to fwlive-packages gh-pages." >&2
