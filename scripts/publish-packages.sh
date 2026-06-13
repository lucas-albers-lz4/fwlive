#!/usr/bin/env bash
# Stage signed opkg/apk feed directories for GitHub Pages deploy.
#
#   OPKG_FEED_SECRET_KEY=./opkg-secret.key \
#   OPKG_FEED_PUBLIC_KEY=./public.key \
#   APK_FEED_SECRET_KEY=./apk-secret.rsa \
#   APK_FEED_PUBLIC_KEY=./fwlive-feed.rsa.pub \
#     ./scripts/publish-packages.sh feed-staging
#
# Prerequisite: ./scripts/docker-sdk.sh build --target x86-64 for 23.05, 24.10, 25.12
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"

STAGING="${1:-feed-staging}"
GIT_TAG="${FWLIVE_GIT_TAG:-$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null || git -C "$ROOT" rev-parse --short HEAD)}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	sed -n '1,14p' "$0"
	exit 0
fi
if [[ -n "${1:-}" ]]; then
	STAGING="$1"
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"

echo "== publish-packages → ${STAGING} (tag: ${GIT_TAG}) ==" >&2

for ver in 23.05 24.10; do
	echo "→ staging opkg feed ${ver}..." >&2
	feed_publish_stage_opkg "$ver" "$STAGING"
done

echo "→ staging apk feed 25.12..." >&2
feed_publish_stage_apk 25.12 "$STAGING"

feed_publish_copy_keys "$STAGING"
feed_publish_write_manifest "$STAGING" "$GIT_TAG"

echo "== staged feed ==" >&2
find "$STAGING" -type f | sort
echo "Ready to deploy ${STAGING}/ to fwlive-packages gh-pages." >&2
