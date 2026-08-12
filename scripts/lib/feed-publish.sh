#!/usr/bin/env bash
# Shared helpers for staging signed opkg/apk feeds.
# Source from publish-packages.sh — do not execute directly.
set -euo pipefail

# shellcheck source=sdk-matrix.sh
source "$(dirname "${BASH_SOURCE[0]}")/sdk-matrix.sh"

feed_publish_root() {
	if [[ -n "${FEED_PUBLISH_ROOT:-}" ]]; then
		printf '%s' "$FEED_PUBLISH_ROOT"
		return 0
	fi
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
		21.02.7) printf '%s' '21.02' ;;
		22.03.7) printf '%s' '22.03' ;;
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

# Map SDK output dir (e.g. 21.02.7) → feed/release key (e.g. 21.02).
feed_publish_release_key() {
	case "$1" in
		21.02.7) printf '%s' '21.02' ;;
		22.03.7) printf '%s' '22.03' ;;
		23.05.5) printf '%s' '23.05' ;;
		24.10.5) printf '%s' '24.10' ;;
		25.12.0) printf '%s' '25.12' ;;
		*) printf '%s' "$1" ;;
	esac
}

# GitHub Releases require unique asset basenames; each OpenWrt line builds the same _all.ipk name.
feed_publish_release_asset_basename() {
	local path="$1"
	local ver_label base key
	ver_label="$(basename "$(dirname "$(dirname "$path")")")"
	base="$(basename "$path")"
	key="$(feed_publish_release_key "$ver_label")"
	if [[ "$base" == *.ipk ]]; then
		printf '%s' "${base/_all.ipk/_${key}_all.ipk}"
	else
		printf '%s' "$base"
	fi
}

# Copy built artifacts into a flat dir with unique release asset names.
feed_publish_stage_release_assets() {
	local dest="$1"
	local ver ver_label path name
	mkdir -p "$dest"
	find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
	for ver in 21.02 22.03 23.05 24.10 25.12; do
		ver_label="$(sdk_matrix_version_label "$ver")"
		path="$(feed_publish_find_artifact "$ver_label" 2>/dev/null || true)"
		[[ -n "$path" ]] || continue
		name="$(feed_publish_release_asset_basename "$path")"
		if [[ -e "${dest}/${name}" ]]; then
			echo "duplicate release asset name: ${name} (${path})" >&2
			return 1
		fi
		cp -a "$path" "${dest}/${name}"
	done
}

# Pinned usign revision for host-side opkg feed signing (no fixed /tmp path;
# fresh build per call). Same pin as the sibling usrmanage feed-publish helper.
# Resolved via: git ls-remote https://github.com/openwrt/usign master
USIGN_PIN_SHA='c4c72b1b07945ee192361dc751291a7c98d6adcd'

feed_publish_ensure_usign() {
	if command -v usign >/dev/null 2>&1; then
		return 0
	fi
	# Prefer the SDK's host usign when a prior docker-sdk build left it on disk.
	local sdk_usign root
	root="$(feed_publish_root)"
	for sdk_usign in \
		"${root}/.sdk"/openwrt-sdk-*/staging_dir/host/bin/usign \
		/builder/staging_dir/host/bin/usign; do
		if [[ -x "$sdk_usign" ]]; then
			export PATH="$(dirname "$sdk_usign"):${PATH}"
			command -v usign >/dev/null && return 0
		fi
	done
	local build_dir rc
	command -v cmake >/dev/null 2>&1 || {
		echo "usign build needs cmake (pinned ${USIGN_PIN_SHA}); install cmake or put usign on PATH" >&2
		return 1
	}
	# Fresh unpredictable mktemp -d each invocation (issue #131 / #166): no
	# fixed /tmp path to pre-create, and the source is commit-pinned.
	build_dir="$(mktemp -d "${TMPDIR:-/tmp}/fwlive-usign.XXXXXX")" || return 1
	echo "→ building pinned usign (${USIGN_PIN_SHA}) in ${build_dir}..." >&2
	rc=0
	(
		set -e
		git init -q "${build_dir}/src"
		git -C "${build_dir}/src" remote add origin "https://github.com/openwrt/usign.git"
		git -C "${build_dir}/src" fetch -q --depth 1 origin "${USIGN_PIN_SHA}"
		git -C "${build_dir}/src" checkout -q "${USIGN_PIN_SHA}"
		test "$(git -C "${build_dir}/src" rev-parse HEAD)" = "${USIGN_PIN_SHA}"
		cmake -S "${build_dir}/src" -B "${build_dir}/build" >/dev/null
		make -C "${build_dir}/build" -j"$(nproc 2>/dev/null || echo 2)" >/dev/null
		ln -sf "${build_dir}/build/usign" "${build_dir}/usign"
	) || rc=1
	if [[ "$rc" -ne 0 ]]; then
		rm -rf "$build_dir"
		echo "usign build failed (pinned ${USIGN_PIN_SHA})" >&2
		return 1
	fi
	# Build dir lives for the process lifetime: PATH points into it and usign
	# is invoked later. Random per-process name; /tmp reaped on reboot.
	export PATH="${build_dir}:${PATH}"
	command -v usign >/dev/null
}

feed_publish_ipkg_index_script() {
	local ver_label="$1"
	local cache sha expected_hash dest got tmp
	cache="${FEED_PUBLISH_IPKG_INDEX_CACHE:-/tmp/fwlive-ipkg-make-index}"
	# Pin to immutable commit SHAs (not mutable branches) and declare the
	# expected sha256 of ipkg-make-index.sh per OpenWrt version. The fetch URL
	# + hash pin defeats TOFU (issue #131): a branch ref can move, but a commit
	# SHA + verified hash cannot.
	case "$ver_label" in
		21.02.7) sha='57a6d97ddf8f6541a52e0f8fad8c6f47685a1bc3'; expected_hash='35e587385a601580d79a1b5cdbb2f591d7b34be9c07e7be36cbb8765a8ef58e6' ;;
		22.03.7) sha='4e1d1b7df0ce6fa96d7462dc883917682f428046'; expected_hash='f19c5013c38d2dc54a95457dd372cb4b6a077ca6ddf7ef3da982b7b6e49b6d06' ;;
		23.05.5) sha='33063b4ccf00d39393796499b23df55187b192dc'; expected_hash='f19c5013c38d2dc54a95457dd372cb4b6a077ca6ddf7ef3da982b7b6e49b6d06' ;;
		24.10.5) sha='4f7e6e554be2aef6a55be36f9f954d56705eb2ee'; expected_hash='f19c5013c38d2dc54a95457dd372cb4b6a077ca6ddf7ef3da982b7b6e49b6d06' ;;
		*)       sha='4f7e6e554be2aef6a55be36f9f954d56705eb2ee'; expected_hash='f19c5013c38d2dc54a95457dd372cb4b6a077ca6ddf7ef3da982b7b6e49b6d06' ;;
	esac

	# The returned path is ALWAYS a fresh private mktemp file that has been
	# verified in this invocation. The cache is only ever a READ-ONLY SOURCE:
	# its copy is re-verified before use, and the executed file is never the
	# cache path itself — closing the TOCTOU window (a cache file swapped
	# after verification, or a symlinked cache entry, cannot redirect what we
	# execute, because we execute the private verified copy).
	local verified
	verified="$(mktemp "${TMPDIR:-/tmp}/fwlive-ipkg-index.XXXXXX")"

	# Seed from cache if present and valid (fast path); else fetch pinned.
	dest="${cache}/ipkg-make-index-${ver_label}.sh"
	if [[ -f "$dest" ]]; then
		got="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}')"
		if [[ "$got" == "$expected_hash" ]]; then
			cp "$dest" "$verified"
		else
			rm -f "$dest"
		fi
	fi
	# Verify the seeded private file (empty if cache was absent/invalid).
	got="$(sha256sum "$verified" | awk '{print $1}')"
	if [[ "$got" != "$expected_hash" ]]; then
		# Cache was absent/invalid: fetch pinned, into the private file.
		echo "→ fetching ipkg-make-index.sh (${ver_label}) pinned to ${sha:0:12}..." >&2
		if ! curl -fsSL "https://raw.githubusercontent.com/openwrt/openwrt/${sha}/scripts/ipkg-make-index.sh" -o "$verified"; then
			echo "failed to fetch ipkg-make-index.sh for ${ver_label}" >&2
			rm -f "$verified"
			return 1
		fi
		got="$(sha256sum "$verified" | awk '{print $1}')"
		if [[ "$got" != "$expected_hash" ]]; then
			echo "ipkg-make-index.sh sha256 mismatch for ${ver_label}: expected ${expected_hash}, got ${got}" >&2
			rm -f "$verified"
			return 1
		fi
		# Refresh the cache (best-effort; the verified file is what we return).
		mkdir -p "$cache"
		rm -f "$dest"
		cp "$verified" "$dest"
	fi
	chmod +x "$verified"
	printf '%s' "$verified"
}

feed_publish_stage_opkg_host() {
	local pkg_dir="$1" ver_label="$2"
	local index_script raw mkhash
	index_script="$(feed_publish_ipkg_index_script "$ver_label")"
	# Caller-owned cleanup (luna Minor fold 2026-08-10): the returned
	# private file is executed once below, then removed on every exit
	# path — success, index failure, and empty-Packages abort alike.
	trap 'rm -f "$index_script"' RETURN
	raw="$(mktemp)"
	# ipkg-make-index.sh uses $MKHASH sha256 (OpenWrt mkhash), not sha256sum alone.
	mkhash=""
	for ver in 25.12 24.10 23.05 22.03 21.02; do
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
				export PATH="/builder/staging_dir/host/bin:$PATH"
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
				if ! "$USIGN" -S -m Packages -s /feed/opkg-secret.key -x Packages.sig; then
					echo "usign failed: OPKG_FEED_SECRET_KEY must be the full usign secret from:" >&2
					echo "  usign -G -s opkg-secret.key -p public.key -c \"fwlive opkg feed\"" >&2
					echo "(not the apk RSA key; include both comment and base64 lines)" >&2
					exit 1
				fi
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
	local manifest ver artifact ver_label sum sdk_digest
	manifest="${staging}/manifest.json"
	: > "$manifest"
	printf '{\n  "git_tag": "%s",\n  "packages": [\n' "${git_tag//\"/\\\"}" >> "$manifest"
	local first=1
	for ver in 21.02 22.03 23.05 24.10 25.12; do
		ver_label="$(sdk_matrix_version_label "$ver")"
		artifact="$(feed_publish_find_artifact "$ver_label" 2>/dev/null || true)"
		[[ -n "$artifact" ]] || continue
		sum="$(sha256sum "$artifact" | awk '{print $1}')"
		# Record the immutable digest of the SDK image this cell was built from
		# (mutable tag → digest makes the release attributable). Per-cell:
		# resolve target×version, then inspect the pulled image.
		sdk_matrix_resolve x86-64 "$ver"
		# Explicit failure propagation (luna fold 2026-08-10): a command
		# substitution's non-zero status is swallowed unless checked —
		# without `|| return 1` an unresolvable digest would silently
		# record an empty sdk_digest and the release would proceed.
		sdk_digest="$(sdk_matrix_image_digest)" || return 1
		[[ $first -eq 1 ]] || printf ',\n' >> "$manifest"
		first=0
		printf '    {"openwrt": "%s", "file": "%s", "sha256": "%s", "sdk_image": "%s", "sdk_digest": "%s"}' \
			"$ver" "$(basename "$artifact")" "$sum" "$SDK_MATRIX_IMAGE" "$sdk_digest" >> "$manifest"
	done
	printf '\n  ]\n}\n' >> "$manifest"
}
