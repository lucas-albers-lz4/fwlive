#!/usr/bin/env bash
# feed_publish_copy_keys requires both public keys; Packages filter has no || true (#803 #821).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# #821: both index paths must fail closed on grep I/O errors.
if grep -nE 'grep -vE.*Maintainer.*\|\| true' "${ROOT}/scripts/lib/feed-publish.sh"; then
	fail "Packages filter still swallows grep status with || true"
fi
grep -cE 'grep -vE .*\^\(Maintainer' "${ROOT}/scripts/lib/feed-publish.sh" | grep -qx 2 \
	|| fail "expected two Packages Maintainer filters"

staging="$(mktemp -d)"
opkg_pub="$(mktemp)"
apk_pub="$(mktemp)"
trap 'rm -rf "$staging" "$opkg_pub" "$apk_pub"' EXIT
printf 'opkg-public\n' >"$opkg_pub"
printf 'apk-public\n' >"$apk_pub"

# #803: missing opkg key fails even when apk is present.
if OPKG_FEED_PUBLIC_KEY="" APK_FEED_PUBLIC_KEY="$apk_pub" \
	feed_publish_copy_keys "$staging" >/dev/null 2>&1; then
	fail "copy_keys must refuse unset OPKG_FEED_PUBLIC_KEY"
fi
if OPKG_FEED_PUBLIC_KEY="/no/such/opkg.key" APK_FEED_PUBLIC_KEY="$apk_pub" \
	feed_publish_copy_keys "$staging" >/dev/null 2>&1; then
	fail "copy_keys must refuse a missing OPKG_FEED_PUBLIC_KEY path"
fi
[[ ! -e "${staging}/public.key" ]] || fail "failed copy must not leave public.key"
[[ ! -e "${staging}/fwlive-feed.rsa.pub" ]] || fail "failed copy must not leave apk pub"

# missing apk key fails even when opkg is present
if OPKG_FEED_PUBLIC_KEY="$opkg_pub" APK_FEED_PUBLIC_KEY="" \
	feed_publish_copy_keys "$staging" >/dev/null 2>&1; then
	fail "copy_keys must refuse unset APK_FEED_PUBLIC_KEY"
fi

OPKG_FEED_PUBLIC_KEY="$opkg_pub" APK_FEED_PUBLIC_KEY="$apk_pub" \
	feed_publish_copy_keys "$staging" || fail "copy_keys with both keys"
[[ -f "${staging}/public.key" ]] || fail "staged public.key"
[[ -f "${staging}/fwlive-feed.rsa.pub" ]] || fail "staged fwlive-feed.rsa.pub"
[[ "$(cat "${staging}/public.key")" == "opkg-public" ]] || fail "public.key contents"
[[ "$(cat "${staging}/fwlive-feed.rsa.pub")" == "apk-public" ]] || fail "apk pub contents"

echo "feed-publish copy-keys / Packages filter (#803 #821) passed"
