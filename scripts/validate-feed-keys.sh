#!/usr/bin/env bash
# Verify opkg/apk signing keys before publish-packages.sh (CI or local).
# Does not require package builds — only pulls SDK image for usign smoke test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"
# shellcheck source=lib/feed-keys.sh
source "${ROOT}/scripts/lib/feed-keys.sh"

die() { echo "validate-feed-keys: $*" >&2; exit 1; }

require_file() {
	[[ -n "${1:-}" && -f "$1" ]] || die "missing file: ${2:-$1}"
}

validate_opkg_usign_key() {
	local secret="$1" public="$2"
	require_file "$secret" "OPKG_FEED_SECRET_KEY"
	require_file "$public" "OPKG_FEED_PUBLIC_KEY"

	feed_keys_maybe_decode_base64 "$secret"
	feed_keys_maybe_decode_base64 "$public"
	feed_keys_normalize_usign_secret "$secret" \
		|| die "OPKG_FEED_SECRET_KEY must be a usign secret (from: usign -G -s opkg-secret.key -p public.key). Paste both lines or base64-encode the file."
	feed_keys_normalize_usign_keyfile "$public" \
		|| die "OPKG_FEED_PUBLIC_KEY must be the matching usign public key (public.key from usign -G). Paste both lines or base64-encode the file."
	# Decode/normalize rewrite via mv; re-assert secret mode (issue #165).
	chmod 600 "$secret" || die "cannot chmod 600 OPKG_FEED_SECRET_KEY"

	sdk_matrix_resolve x86-64 23.05

	local secret_abs public_abs tmpdir
	secret_abs="$(feed_publish_abspath "$secret")"
	public_abs="$(feed_publish_abspath "$public")"
	tmpdir="$(mktemp -d)"

	docker run --rm --user root \
		-v "${secret_abs}:/feed/opkg-secret.key:ro" \
		-v "${public_abs}:/feed/public.key:ro" \
		-v "${tmpdir}:/feed/out" \
		"$SDK_MATRIX_IMAGE" \
		sh -ec '
			set -e
			USIGN=/builder/staging_dir/host/bin/usign
			test -x "$USIGN"
			echo "Package: fwlive-key-test" > /feed/out/Packages
			"$USIGN" -S -m /feed/out/Packages -s /feed/opkg-secret.key -x /feed/out/Packages.sig
			"$USIGN" -V -m /feed/out/Packages -p /feed/public.key -x /feed/out/Packages.sig
		' || die "usign test sign failed — check OPKG_FEED_SECRET_KEY matches OPKG_FEED_PUBLIC_KEY (usign -G pair, not openssl RSA)"

	rm -rf "$tmpdir"
	echo "validate-feed-keys: opkg usign keys OK" >&2
}

validate_apk_rsa_key() {
	local secret="$1" public="$2"
	local mod_secret mod_public msg sig
	require_file "$secret" "APK_FEED_SECRET_KEY"
	require_file "$public" "APK_FEED_PUBLIC_KEY"

	feed_keys_maybe_decode_base64 "$secret"
	feed_keys_maybe_decode_base64 "$public"
	chmod 600 "$secret" || die "cannot chmod 600 APK_FEED_SECRET_KEY"

	head -1 "$secret" | grep -q 'BEGIN.*PRIVATE KEY' \
		|| die "APK_FEED_SECRET_KEY must be an RSA private key (openssl genrsa). Do not use the usign opkg secret here."
	head -1 "$public" | grep -q 'BEGIN PUBLIC KEY' \
		|| die "APK_FEED_PUBLIC_KEY must be PEM public key (openssl rsa -pubout)"

	mod_secret="$(openssl rsa -in "$secret" -noout -modulus 2>/dev/null)" \
		|| die "APK_FEED_SECRET_KEY is not a valid RSA private key"
	mod_public="$(openssl rsa -pubin -in "$public" -noout -modulus 2>/dev/null)" \
		|| die "APK_FEED_PUBLIC_KEY is not a valid RSA public key"
	[[ -n "$mod_secret" && "$mod_secret" == "$mod_public" ]] \
		|| die "APK_FEED_SECRET_KEY does not match APK_FEED_PUBLIC_KEY (regenerate with openssl rsa -pubout)"

	msg="$(mktemp)"
	sig="$(mktemp)"
	trap 'rm -f "$msg" "$sig"' RETURN

	printf '%s\n' 'fwlive-apk-key-test' >"$msg"
	openssl dgst -sha256 -sign "$secret" -out "$sig" "$msg" \
		|| die "APK_FEED_SECRET_KEY cannot sign"
	openssl dgst -sha256 -verify "$public" -signature "$sig" "$msg" >/dev/null \
		|| die "APK_FEED_PUBLIC_KEY cannot verify signatures from APK_FEED_SECRET_KEY"

	echo "validate-feed-keys: apk RSA keys OK" >&2
}

[[ -n "${OPKG_FEED_SECRET_KEY:-}" && -n "${OPKG_FEED_PUBLIC_KEY:-}" ]] \
	|| die "set OPKG_FEED_SECRET_KEY and OPKG_FEED_PUBLIC_KEY"
[[ -n "${APK_FEED_SECRET_KEY:-}" && -n "${APK_FEED_PUBLIC_KEY:-}" ]] \
	|| die "set APK_FEED_SECRET_KEY and APK_FEED_PUBLIC_KEY"

validate_opkg_usign_key "$OPKG_FEED_SECRET_KEY" "$OPKG_FEED_PUBLIC_KEY"
validate_apk_rsa_key "$APK_FEED_SECRET_KEY" "$APK_FEED_PUBLIC_KEY"
echo "validate-feed-keys: all signing keys OK" >&2
