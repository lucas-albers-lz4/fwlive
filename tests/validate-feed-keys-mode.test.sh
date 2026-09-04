#!/usr/bin/env bash
# Host proof: signing secrets stay mode 0600 through the validate-feed-keys
# rewrite path (decode + normalize + chmod), not only feed_keys_write_from_env
# (#165 library test). Does not pull an SDK image — the docker usign/sign step
# remains a prove-next on the next real publish (or opt-in FWLIVE_VALIDATE_KEYS_DOCKER=1).
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

OPKG_ONE_LINE='untrusted comment: fwlive validate-mode test RWabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV'
OPKG_PUB_ONE_LINE='untrusted comment: fwlive validate-mode pub RWabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV'
# Non-PEM placeholders — mode path only (openssl validate needs real RSA; that
# stays on the library test + real publish).
APK_PEM='fwlive-apk-test-secret-placeholder-not-a-key'
APK_PUB_PEM='fwlive-apk-test-public-placeholder-not-a-key'

OPKG_SECRET="$OPKG_ONE_LINE" \
	APK_SECRET="$APK_PEM" \
	OPKG_PUB="$OPKG_PUB_ONE_LINE" \
	APK_PUB="$APK_PUB_PEM" \
	feed_keys_write_from_env "$DEST" \
	|| bad "feed_keys_write_from_env"

assert_600 "${DEST}/opkg-secret.key" "after write opkg-secret.key"
assert_600 "${DEST}/apk-secret.rsa" "after write apk-secret.rsa"

# Mirror validate_opkg_usign_key / validate_apk_rsa_key rewrite prefix (no docker).
secret="${DEST}/opkg-secret.key"
public="${DEST}/public.key"
apk_secret="${DEST}/apk-secret.rsa"

feed_keys_maybe_decode_base64 "$secret"
feed_keys_maybe_decode_base64 "$public"
feed_keys_normalize_usign_secret "$secret" \
	|| bad "normalize usign secret"
feed_keys_normalize_usign_keyfile "$public" \
	|| bad "normalize usign public"
chmod 600 "$secret" || bad "chmod 600 opkg secret after normalize"
assert_600 "$secret" "after validate-prefix normalize opkg-secret.key"

feed_keys_maybe_decode_base64 "$apk_secret"
chmod 600 "$apk_secret" || bad "chmod 600 apk secret after decode"
assert_600 "$apk_secret" "after validate-prefix apk-secret.rsa"

[ -z "$(find "$DEST" -name '*.tmp' -print -quit)" ] \
	&& ok "no leftover .tmp after validate-prefix" \
	|| bad "leftover .tmp after validate-prefix"

if [[ "${FWLIVE_VALIDATE_KEYS_DOCKER:-0}" == "1" ]]; then
	export OPKG_FEED_SECRET_KEY="${DEST}/opkg-secret.key"
	export OPKG_FEED_PUBLIC_KEY="${DEST}/public.key"
	export APK_FEED_SECRET_KEY="${DEST}/apk-secret.rsa"
	export APK_FEED_PUBLIC_KEY="${DEST}/public.key"
	# Real RSA required for apk path — skip docker unless operator supplies keys.
	echo "skip: FWLIVE_VALIDATE_KEYS_DOCKER=1 needs real usign+RSA pair; use CI secrets on publish" >&2
fi

if [[ "$fail" -ne 0 ]]; then
	echo "validate-feed-keys-mode: FAILED" >&2
	exit 1
fi
echo "validate-feed-keys-mode: OK" >&2
