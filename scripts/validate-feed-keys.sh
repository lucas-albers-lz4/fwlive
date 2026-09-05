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

	feed_keys_validate_opkg_rewrite_prefix "$secret" "$public" \
		|| die "OPKG rewrite prefix failed (see feed-keys step above; expect usign -G pair or base64 of those files)."

	# R7: pin the SDK digest at first pull *before* mounting the usign secret.
	# sdk_matrix_resolve alone uses a mutable tag; a moved tag could exfiltrate
	# OPKG_FEED_SECRET_KEY while a later build records a different digest.
	sdk_matrix_pull_and_pin x86-64 23.05 >/dev/null \
		|| die "failed to pull/pin OpenWrt SDK image for usign key check"

	local secret_abs public_abs tmpdir
	secret_abs="$(feed_publish_abspath "$secret")"
	public_abs="$(feed_publish_abspath "$public")"
	tmpdir="$(mktemp -d)"

	docker run --rm --network none --user root \
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

	feed_keys_validate_apk_rewrite_prefix "$secret" "$public" \
		|| die "APK rewrite prefix failed (see feed-keys step above)."

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
