#!/usr/bin/env bash
# Write and normalize feed signing keys from env (CI secrets or local).
# Source from validate-feed-keys.sh / publish workflow — do not execute directly.
set -euo pipefail

feed_keys_root() {
	local here
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	printf '%s' "$here"
}

# usign expects two lines; GitHub secret paste often collapses to one line → "Premature end of file".
feed_keys_normalize_usign_secret() {
	local f="$1"
	[[ -f "$f" && -s "$f" ]] || return 1

	# GitHub paste / tr "\n" " " often leaves trailing whitespace.
	sed -i 's/[[:space:]]*$//' "$f"

	if grep -qE '^RW[A-Za-z0-9+/=]+=?$' "$f"; then
		return 0
	fi

	if grep -q 'untrusted comment:' "$f" && grep -qE ' RW[A-Za-z0-9+/=]+=?$' "$f"; then
		sed -E 's/^(untrusted comment: .+) (RW[A-Za-z0-9+/=]+=?)[[:space:]]*$/\1\
\2/' "$f" > "${f}.tmp"
		mv "${f}.tmp" "$f"
	fi

	grep -qE '^RW[A-Za-z0-9+/=]+=?$' "$f" || return 1
	return 0
}

# Optional: store whole key file as base64 in GitHub secret (avoids newline issues).
feed_keys_maybe_decode_base64() {
	local f="$1"
	local first
	first="$(head -1 "$f" | tr -d '\r\n')"
	if [[ "$first" == untrusted\ comment:* || "$first" == -----BEGIN* ]]; then
		return 0
	fi
	if base64 -d <"$f" >"${f}.tmp" 2>/dev/null && [[ -s "${f}.tmp" ]]; then
		mv "${f}.tmp" "$f"
	fi
}

feed_keys_write_from_env() {
	local opkg_secret="${OPKG_SECRET:?OPKG_SECRET required}"
	local apk_secret="${APK_SECRET:?APK_SECRET required}"
	local opkg_pub="${OPKG_PUB:?OPKG_PUB required}"
	local apk_pub="${APK_PUB:?APK_PUB required}"
	local dest="${1:-$(feed_keys_root)}"

	printf '%s' "$opkg_secret" > "${dest}/opkg-secret.key"
	printf '%s' "$apk_secret" > "${dest}/apk-secret.rsa"
	printf '%s' "$opkg_pub" > "${dest}/public.key"
	printf '%s' "$apk_pub" > "${dest}/fwlive-feed.rsa.pub"
	chmod 600 "${dest}/opkg-secret.key" "${dest}/apk-secret.rsa"

	feed_keys_maybe_decode_base64 "${dest}/opkg-secret.key"
	feed_keys_maybe_decode_base64 "${dest}/public.key"
	feed_keys_maybe_decode_base64 "${dest}/apk-secret.rsa"
	feed_keys_maybe_decode_base64 "${dest}/fwlive-feed.rsa.pub"

	feed_keys_normalize_usign_secret "${dest}/opkg-secret.key" \
		|| {
			echo "feed-keys: OPKG_FEED_SECRET_KEY must be usign secret (usign -G) or its base64" >&2
			return 1
		}
}
