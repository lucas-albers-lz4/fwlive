#!/usr/bin/env bash
# Host proof that feed signing secrets stay mode 0600 through write+normalize
# (issue #165). Both documented storage formats under umask 022.
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

DEST=$(mktemp -d)
trap 'rm -rf "$DEST"' EXIT

# Synthetic usign-shaped keys (comment + RW payload on one line → normalize path).
OPKG_ONE_LINE='untrusted comment: fwlive test secret RWabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV'
OPKG_PUB_ONE_LINE='untrusted comment: fwlive test public RWabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV'
# Non-PEM placeholders (avoid gitleaks private-key rule); decode is a no-op /
# failed-decode path — mode assertion is what this test proves.
APK_PEM='fwlive-apk-test-secret-placeholder-not-a-key'
APK_PUB_PEM='fwlive-apk-test-public-placeholder-not-a-key'

umask 022

# Case 1: one-line usign paste (normalize path rewrites via mktemp+mv).
OPKG_SECRET="$OPKG_ONE_LINE" \
	APK_SECRET="$APK_PEM" \
	OPKG_PUB="$OPKG_PUB_ONE_LINE" \
	APK_PUB="$APK_PUB_PEM" \
	feed_keys_write_from_env "$DEST" \
	|| bad "write_from_env one-line form"

[ "$(stat_mode "${DEST}/opkg-secret.key")" = "600" ] \
	&& ok "one-line opkg-secret.key mode 600" \
	|| bad "one-line opkg-secret.key mode $(stat_mode "${DEST}/opkg-secret.key")"
[ "$(stat_mode "${DEST}/apk-secret.rsa")" = "600" ] \
	&& ok "one-line apk-secret.rsa mode 600" \
	|| bad "one-line apk-secret.rsa mode $(stat_mode "${DEST}/apk-secret.rsa")"
[ -z "$(find "$DEST" -name '*.tmp' -print -quit)" ] \
	&& ok "one-line leaves no .tmp" \
	|| bad "one-line leftover .tmp"

rm -f "$DEST"/*

# Case 2: base64-encoded key files (decode path).
# Two-line usign already-normalized content, base64'd.
OPKG_B64=$(printf '%s\n%s\n' 'untrusted comment: fwlive test secret' \
	'RWabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV' | base64 -w0 2>/dev/null \
	|| printf '%s\n%s\n' 'untrusted comment: fwlive test secret' \
	'RWabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV' | base64)
OPKG_PUB_B64=$(printf '%s\n%s\n' 'untrusted comment: fwlive test public' \
	'RWabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV' | base64 -w0 2>/dev/null \
	|| printf '%s\n%s\n' 'untrusted comment: fwlive test public' \
	'RWabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV' | base64)
APK_B64=$(printf '%s' "$APK_PEM" | base64 -w0 2>/dev/null || printf '%s' "$APK_PEM" | base64)
APK_PUB_B64=$(printf '%s' "$APK_PUB_PEM" | base64 -w0 2>/dev/null || printf '%s' "$APK_PUB_PEM" | base64)

OPKG_SECRET="$OPKG_B64" \
	APK_SECRET="$APK_B64" \
	OPKG_PUB="$OPKG_PUB_B64" \
	APK_PUB="$APK_PUB_B64" \
	feed_keys_write_from_env "$DEST" \
	|| bad "write_from_env base64 form"

[ "$(stat_mode "${DEST}/opkg-secret.key")" = "600" ] \
	&& ok "base64 opkg-secret.key mode 600" \
	|| bad "base64 opkg-secret.key mode $(stat_mode "${DEST}/opkg-secret.key")"
[ "$(stat_mode "${DEST}/apk-secret.rsa")" = "600" ] \
	&& ok "base64 apk-secret.rsa mode 600" \
	|| bad "base64 apk-secret.rsa mode $(stat_mode "${DEST}/apk-secret.rsa")"
[ -z "$(find "$DEST" -name '*.tmp' -print -quit)" ] \
	&& ok "base64 leaves no .tmp" \
	|| bad "base64 leftover .tmp"

# Partial base64 decode must not leave a fixed .tmp sibling.
printf 'not-valid-base64!!!' > "${DEST}/partial.key"
feed_keys_maybe_decode_base64 "${DEST}/partial.key" || true
[ ! -f "${DEST}/partial.key.tmp" ] \
	&& ok "failed decode leaves no partial.key.tmp" \
	|| bad "partial.key.tmp leaked after failed decode"
[ -z "$(find "$DEST" -name 'partial.key.*' ! -name 'partial.key' -print -quit)" ] \
	&& ok "failed decode leaves no mktemp sibling" \
	|| bad "mktemp sibling leaked after failed decode"

[ "$fail" = "0" ] || exit 1
echo "feed-keys-mode tests: ok"
