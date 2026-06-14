#!/usr/bin/env bash
# Shared helpers for staging signed opkg/apk feeds.
# Source from publish-packages.sh — do not execute directly.
set -euo pipefail

# shellcheck source=sdk-matrix.sh
source "$(dirname "${BASH_SOURCE[0]}")/sdk-matrix.sh"

feed_publish_root() {
	local here
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	printf '%s' "$here"
}

feed_publish_abspath() {
	local path="$1"
	if [[ "$path" != /* ]]; then
		path="$(feed_publish_root)/${path#./}"
	fi
	(
		cd "$(dirname "$path")"
		printf '%s/%s' "$(pwd)" "$(basename "$path")"
	)
}

# Map user version key → feed directory name on GitHub Pages.
feed_publish_feed_dir() {
	case "$(sdk_matrix_version_label "$1")" in
		23.05.5) printf '%s' '23.05' ;;
		24.10.5) printf '%s' '24.10' ;;
		25.12.0) printf '%s' '25.12' ;;
		*) sdk_matrix_version_label "$1" ;;
	esac
}

feed_publish_find_artifact() {
	local version_label="$1"
	local root dir base f
	root="$(feed_publish_root)"
	dir="${root}/out/x86_64/${version_label}/fwlive"
	shopt -s nullglob
	local candidates=( "${dir}"/luci-app-fwlive_*_all.ipk "${dir}"/luci-app-fwlive-*.apk "${dir}"/luci-app-fwlive_*.apk )
	shopt -u nullglob
	[[ ${#candidates[@]} -ge 1 ]] || return 1
	ls -1 "${candidates[@]}" 2>/dev/null | head -1
}

feed_publish_ensure_usign() {
	if command -v usign >/dev/null 2>&1; then
		return 0
	fi
	local build_dir="${FEED_PUBLISH_USIGN_BUILD:-/tmp/fwlive-usign-build}"
	if [[ -x "${build_dir}/usign" ]]; then
		export PATH="${build_dir}:${PATH}"
		return 0
	fi
	echo "→ building usign (one-time)..." >&2
	mkdir -p "$build_dir"
	if [[ ! -d "${build_dir}/src/.git" ]]; then
		git clone --depth 1 https://git.openwrt.org/project/usign.git "${build_dir}/src"
	fi
	make -C "${build_dir}/src" -j"$(nproc 2>/dev/null || echo 2)" >/dev/null
	ln -sf "${build_dir}/src/usign" "${build_dir}/usign"
	export PATH="${build_dir}:${PATH}"
	command -v usign >/dev/null
}

feed_publish_ipkg_index_script() {
	local ver_label="$1"
	local cache="${FEED_PUBLISH_IPKG_INDEX_CACHE:-/tmp/fwlive-ipkg-make-index}"
	local tag
	case "$ver_label" in
		23.05.5) tag='openwrt-23.05' ;;
		24.10.5) tag='v24.10.5' ;;
		*) tag='v24.10.5' ;;
	esac
	mkdir -p "$cache"
	local dest="${cache}/ipkg-make-index-${ver_label}.sh"
	if [[ ! -f "$dest" ]]; then
		curl -fsSL "https://raw.githubusercontent.com/openwrt/openwrt/${tag}/scripts/ipkg-make-index.sh" -o "$dest"
		chmod +x "$dest"
	fi
	printf '%s' "$dest"
}

feed_publish_stage_opkg_host() {
	local pkg_dir="$1" ver_label="$2"
	local index_script raw mkhash
	index_script="$(feed_publish_ipkg_index_script "$ver_label")"
	raw="$(mktemp)"
	# ipkg-make-index.sh uses $MKHASH sha256 (OpenWrt mkhash), not sha256sum alone.
	mkhash=""
	for ver in 25.12 24.10 23.05; do
		sdk_matrix_resolve x86-64 "$ver" 2>/dev/null || continue
		if sdk_matrix_feeds_ready 2>/dev/null; then
			mkhash="$(sdk_matrix_compose_run sh -c 'test -x /builder/staging_dir/host/bin/mkhash && echo /builder/staging_dir/host/bin/mkhash' 2>/dev/null | tr -d '\r' || true)"
			[[ -n "$mkhash" ]] && break
		fi
	done
	[[ -n "$mkhash" ]] || mkhash="$(command -v mkhash || true)"
	if ! ( cd "$pkg_dir" && MKHASH="${mkhash:-mkhash}" "$index_script" . >"$raw" ); then
		echo "ipkg-make-index failed for ${ver_label}" >&2
		cat "$raw" >&2
		rm -f "$raw"
		return 1
	fi
	grep -vE '^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)' "$raw" > "${pkg_dir}/Packages" || true
	rm -f "$raw"
	[[ -s "${pkg_dir}/Packages" ]] || {
		echo "empty Packages index for ${ver_label}" >&2
		return 1
	}
	gzip -9cn "${pkg_dir}/Packages" > "${pkg_dir}/Packages.gz"
	feed_publish_ensure_usign || {
		echo "usign not available (install or run after docker-sdk build)" >&2
		return 1
	}
	usign -S -m "${pkg_dir}/Packages" -s "$OPKG_FEED_SECRET_KEY" -x "${pkg_dir}/Packages.sig"
}

feed_publish_stage_opkg_sdk() {
	local version_key="$1" pkg_dir="$2"
	local root pkg_abs key_abs
	root="$(feed_publish_root)"
	pkg_dir="$(feed_publish_abspath "$pkg_dir")"
	key_abs="$(feed_publish_abspath "$OPKG_FEED_SECRET_KEY")"
	sdk_matrix_resolve x86-64 "$version_key"
	sdk_matrix_feeds_ready \
		|| { echo "run docker-sdk.sh build --version ${version_key} before staging opkg feed" >&2; return 1; }
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		docker compose run --rm --user root \
			-v "${pkg_dir}:/feed/pkgdir" \
			-v "${key_abs}:/feed/opkg-secret.key:ro" \
			sdk sh -ec '
				set -e
				USIGN=/builder/staging_dir/host/bin/usign
				INDEX=/builder/scripts/ipkg-make-index.sh
				MKHASH=/builder/staging_dir/host/bin/mkhash
				export MKHASH
				test -x "$USIGN"
				test -x "$INDEX"
				test -x "$MKHASH"
				cd /feed/pkgdir
				RAW="$(mktemp)"
				"$INDEX" . >"$RAW"
				grep -vE "^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)" "$RAW" > Packages || true
				rm -f "$RAW"
				test -s Packages
				gzip -9cn Packages > Packages.gz
				"$USIGN" -S -m Packages -s /feed/opkg-secret.key -x Packages.sig
			'
	)
}

feed_publish_stage_opkg() {
	local version_key="$1" staging="$2"
	local ver_label feed_dir artifact pkg_dir
	ver_label="$(sdk_matrix_version_label "$version_key")"
	feed_dir="${staging}/$(feed_publish_feed_dir "$version_key")"
	artifact="$(feed_publish_find_artifact "$ver_label")" || {
		echo "missing built ipk for ${ver_label} under out/x86_64/${ver_label}/fwlive/" >&2
		return 1
	}
	[[ -n "${OPKG_FEED_SECRET_KEY:-}" ]] || {
		echo "OPKG_FEED_SECRET_KEY must point to usign secret key file" >&2
		return 1
	}
	mkdir -p "$feed_dir"
	cp -a "$artifact" "$feed_dir/"
	pkg_dir="$feed_dir"
	sdk_matrix_resolve x86-64 "$version_key"
	if sdk_matrix_feeds_ready 2>/dev/null; then
		echo "  index+sign via SDK (${SDK_MATRIX_IMAGE})" >&2
		feed_publish_stage_opkg_sdk "$version_key" "$pkg_dir"
	else
		echo "  index+sign on host (no SDK volume)" >&2
		feed_publish_stage_opkg_host "$pkg_dir" "$ver_label"
	fi
	printf '%s' "$artifact"
}

feed_publish_stage_apk() {
	local version_key="$1" staging="$2"
	local ver_label feed_dir artifact pkg_dir
	ver_label="$(sdk_matrix_version_label "$version_key")"
	feed_dir="${staging}/$(feed_publish_feed_dir "$version_key")/all"
	artifact="$(feed_publish_find_artifact "$ver_label")" || {
		echo "missing built apk for ${ver_label} under out/x86_64/${ver_label}/fwlive/" >&2
		return 1
	}
	mkdir -p "$feed_dir"
	cp -a "$artifact" "$feed_dir/"
	pkg_dir="$feed_dir"
	[[ -n "${APK_FEED_SECRET_KEY:-}" ]] || {
		echo "APK_FEED_SECRET_KEY must point to RSA private key for apk mkndx --sign" >&2
		return 1
	}
	sdk_matrix_resolve x86-64 "$version_key"
	sdk_matrix_feeds_ready \
		|| { echo "run docker-sdk.sh build --version ${version_key} before staging apk feed" >&2; return 1; }
	local root pkg_abs key_abs
	root="$(feed_publish_root)"
	pkg_dir="$(feed_publish_abspath "$pkg_dir")"
	key_abs="$(feed_publish_abspath "$APK_FEED_SECRET_KEY")"
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		docker compose run --rm --user root \
			-v "${pkg_dir}:/feed/pkgdir" \
			-v "${key_abs}:/feed/apk-secret.rsa:ro" \
			sdk sh -ec '
				set -e
				APK=/builder/staging_dir/host/bin/apk
				test -x "$APK"
				cd /feed/pkgdir
				"$APK" mkndx --allow-untrusted --sign /feed/apk-secret.rsa --output packages.adb *.apk
			'
	)
	printf '%s' "$artifact"
}

feed_publish_copy_keys() {
	local staging="$1"
	[[ -n "${OPKG_FEED_PUBLIC_KEY:-}" && -f "$OPKG_FEED_PUBLIC_KEY" ]] && cp -a "$OPKG_FEED_PUBLIC_KEY" "${staging}/public.key"
	[[ -n "${APK_FEED_PUBLIC_KEY:-}" && -f "$APK_FEED_PUBLIC_KEY" ]] && cp -a "$APK_FEED_PUBLIC_KEY" "${staging}/fwlive-feed.rsa.pub"
}

feed_publish_write_manifest() {
	local staging="$1" git_tag="${2:-unknown}"
	local manifest ver artifact ver_label sum
	manifest="${staging}/manifest.json"
	: > "$manifest"
	printf '{\n  "git_tag": "%s",\n  "packages": [\n' "${git_tag//\"/\\\"}" >> "$manifest"
	local first=1
	for ver in 23.05 24.10 25.12; do
		ver_label="$(sdk_matrix_version_label "$ver")"
		artifact="$(feed_publish_find_artifact "$ver_label" 2>/dev/null || true)"
		[[ -n "$artifact" ]] || continue
		sum="$(sha256sum "$artifact" | awk '{print $1}')"
		[[ $first -eq 1 ]] || printf ',\n' >> "$manifest"
		first=0
		printf '    {"openwrt": "%s", "file": "%s", "sha256": "%s"}' "$ver" "$(basename "$artifact")" "$sum" >> "$manifest"
	done
	printf '\n  ]\n}\n' >> "$manifest"
}
