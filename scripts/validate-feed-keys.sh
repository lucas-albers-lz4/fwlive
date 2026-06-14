#!/usr/bin/env bash
# Verify opkg/apk signing keys before publish-packages.sh (CI or local).
#
#   OPKG_FEED_SECRET_KEY=./opkg-secret.key OPKG_FEED_PUBLIC_KEY=./public.key \
#   APK_FEED_SECRET_KEY=./apk-secret.rsa APK_FEED_PUBLIC_KEY=./fwlive-feed.rsa.pub \
#     ./scripts/validate-feed-keys.sh
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

	sdk_matrix_resolve x86-64 23.05
	sdk_matrix_feeds_ready 2>/dev/null \
		|| die "SDK volume for 23.05 not ready (run docker-sdk build first)"

	local secret_abs public_abs tmpdir
	secret_abs="$(feed_publish_abspath "$secret")"
	public_abs="$(feed_publish_abspath "$public")"
	tmpdir="$(mktemp -d)"

	(
		cd "$ROOT"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		docker compose run --rm --user root \
			-v "${secret_abs}:/feed/opkg-secret.key:ro" \
			-v "${public_abs}:/feed/public.key:ro" \
			-v "${tmpdir}:/feed/out" \
			sdk sh -ec '
				set -e
				USIGN=/builder/staging_dir/host/bin/usign
				test -x "$USIGN"
				echo "Package: fwlive-key-test" > /feed/out/Packages
				"$USIGN" -S -m /feed/out/Packages -s /feed/opkg-secret.key -x /feed/out/Packages.sig
				"$USIGN" -V -m /feed/out/Packages -P /feed/public.key -x /feed/out/Packages.sig
			'
	) || die "usign test sign failed — check OPKG_FEED_SECRET_KEY matches OPKG_FEED_PUBLIC_KEY (usign -G pair, not openssl RSA)"

	rm -rf "$tmpdir"
	echo "validate-feed-keys: opkg usign keys OK" >&2
}

validate_apk_rsa_key() {
	local secret="$1" public="$2"
	require_file "$secret" "APK_FEED_SECRET_KEY"
	require_file "$public" "APK_FEED_PUBLIC_KEY"

	head -1 "$secret" | grep -q 'BEGIN.*PRIVATE KEY' \
		|| die "APK_FEED_SECRET_KEY must be an RSA private key (openssl genrsa). Do not use the usign opkg secret here."
	head -1 "$public" | grep -q 'BEGIN PUBLIC KEY' \
		|| die "APK_FEED_PUBLIC_KEY must be PEM public key (openssl rsa -pubout)"

	sdk_matrix_resolve x86-64 25.12
	sdk_matrix_feeds_ready 2>/dev/null \
		|| die "SDK volume for 25.12 not ready (run docker-sdk build first)"

	local secret_abs tmpdir artifact pkgdir
	secret_abs="$(feed_publish_abspath "$secret")"
	tmpdir="$(mktemp -d)"
	pkgdir="${tmpdir}/all"
	mkdir -p "$pkgdir"

	artifact="$(feed_publish_find_artifact 25.12.0)" \
		|| die "missing 25.12 apk under out/x86_64/25.12.0/fwlive/ (build first)"
	cp -a "$artifact" "$pkgdir/"
	pkgdir="$(feed_publish_abspath "$pkgdir")"

	(
		cd "$ROOT"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		docker compose run --rm --user root \
			-v "${pkgdir}:/feed/pkgdir" \
			-v "${secret_abs}:/feed/apk-secret.rsa:ro" \
			sdk sh -ec '
				set -e
				APK=/builder/staging_dir/host/bin/apk
				test -x "$APK"
				cd /feed/pkgdir
				"$APK" mkndx --allow-untrusted --sign /feed/apk-secret.rsa --output packages.adb *.apk
				test -f packages.adb
			'
	) || die "apk mkndx test sign failed — check APK_FEED_SECRET_KEY / APK_FEED_PUBLIC_KEY pair"

	rm -rf "$tmpdir"
	echo "validate-feed-keys: apk RSA keys OK" >&2
}

[[ -n "${OPKG_FEED_SECRET_KEY:-}" && -n "${OPKG_FEED_PUBLIC_KEY:-}" ]] \
	|| die "set OPKG_FEED_SECRET_KEY and OPKG_FEED_PUBLIC_KEY"
[[ -n "${APK_FEED_SECRET_KEY:-}" && -n "${APK_FEED_PUBLIC_KEY:-}" ]] \
	|| die "set APK_FEED_SECRET_KEY and APK_FEED_PUBLIC_KEY"

validate_opkg_usign_key "$OPKG_FEED_SECRET_KEY" "$OPKG_FEED_PUBLIC_KEY"
validate_apk_rsa_key "$APK_FEED_SECRET_KEY" "$APK_FEED_PUBLIC_KEY"
echo "validate-feed-keys: all signing keys OK" >&2
