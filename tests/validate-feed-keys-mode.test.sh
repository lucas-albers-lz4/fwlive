#!/usr/bin/env bash
# Host proof: signing secrets stay mode 0600 through the shared validate
# rewrite prefix (decode + normalize + chmod) in feed-keys.sh — the same
# helpers validate-feed-keys.sh runs before docker usign / openssl.
# Does not pull an SDK image — full usign sign stays prove-next on publish.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/feed-keys.sh
source "${ROOT}/scripts/lib/feed-keys.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

stat_mode() {
	local m
	m=$(stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1")
	printf '%s' "$m" | sed 's/^0*//'
}

assert_600() {
	local f="$1" label="$2"
	[ "$(stat_mode "$f")" = "600" ] && ok "$label mode 600" || bad "$label mode $(stat_mode "$f")"
}

DEST=$(mktemp -d)
trap 'rm -rf "$DEST"' EXIT
umask 022

# Two-line usign-shaped content, then base64 — exercises maybe_decode rewrite.
OPKG_PLAIN=$(printf '%s\n%s\n' 'untrusted comment: fwlive validate-mode test' \
	'RWabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV')
OPKG_PUB_PLAIN=$(printf '%s\n%s\n' 'untrusted comment: fwlive validate-mode pub' \
	'RWabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV')
# Non-PEM placeholder (avoid gitleaks); decode still rewrites via mktemp+mv.
APK_PLAIN='fwlive-apk-test-secret-placeholder-not-a-key'
APK_PUB_PLAIN='fwlive-apk-test-public-placeholder-not-a-key'

b64() {
	printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64
}

OPKG_SECRET="$(b64 "$OPKG_PLAIN")" \
	APK_SECRET="$(b64 "$APK_PLAIN")" \
	OPKG_PUB="$(b64 "$OPKG_PUB_PLAIN")" \
	APK_PUB="$(b64 "$APK_PUB_PLAIN")" \
	feed_keys_write_from_env "$DEST" \
	|| bad "feed_keys_write_from_env"

assert_600 "${DEST}/opkg-secret.key" "after write opkg-secret.key"
assert_600 "${DEST}/apk-secret.rsa" "after write apk-secret.rsa"

# Re-encode plain files so rewrite_prefix must take the base64 branch again.
printf '%s' "$(b64 "$OPKG_PLAIN")" >"${DEST}/opkg-secret.key"
printf '%s' "$(b64 "$OPKG_PUB_PLAIN")" >"${DEST}/public.key"
printf '%s' "$(b64 "$APK_PLAIN")" >"${DEST}/apk-secret.rsa"
printf '%s' "$(b64 "$APK_PUB_PLAIN")" >"${DEST}/fwlive-feed.rsa.pub"
chmod 600 "${DEST}/opkg-secret.key" "${DEST}/apk-secret.rsa"
# World-readable umask would have made 644; prove rewrite restores 600.
chmod 644 "${DEST}/opkg-secret.key" "${DEST}/apk-secret.rsa" 2>/dev/null || true
umask 022

feed_keys_validate_opkg_rewrite_prefix \
	"${DEST}/opkg-secret.key" "${DEST}/public.key" \
	|| bad "feed_keys_validate_opkg_rewrite_prefix"
assert_600 "${DEST}/opkg-secret.key" "after opkg rewrite_prefix"

feed_keys_validate_apk_rewrite_prefix \
	"${DEST}/apk-secret.rsa" "${DEST}/fwlive-feed.rsa.pub" \
	|| bad "feed_keys_validate_apk_rewrite_prefix"
assert_600 "${DEST}/apk-secret.rsa" "after apk rewrite_prefix"

head -1 "${DEST}/opkg-secret.key" | grep -q 'untrusted comment:' \
	&& ok "opkg decode restored usign comment line" \
	|| bad "opkg decode did not restore usign comment"

[ -z "$(find "$DEST" -name '*.tmp' -print -quit)" ] \
	&& ok "no leftover .tmp after rewrite_prefix" \
	|| bad "leftover .tmp after rewrite_prefix"
[ -z "$(find "$DEST" \( -name 'opkg-secret.key.*' -o -name 'apk-secret.rsa.*' \) -print -quit)" ] \
	&& ok "no leftover mktemp sibling after rewrite_prefix" \
	|| bad "leftover mktemp sibling after rewrite_prefix"

if [[ "${FWLIVE_VALIDATE_KEYS_DOCKER:-0}" == "1" ]]; then
	echo "skip: FWLIVE_VALIDATE_KEYS_DOCKER=1 needs real usign+RSA pair; use CI secrets on publish" >&2
fi

if [[ "$fail" -ne 0 ]]; then
	echo "validate-feed-keys-mode: FAILED" >&2
	exit 1
fi
echo "validate-feed-keys-mode: OK" >&2
