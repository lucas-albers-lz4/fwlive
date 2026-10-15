#!/usr/bin/env bash
# Verify bit-identical luci-app-fwlive builds (reproducibility gate).
#
#   ./scripts/verify-reproducible-build.sh
#   ./scripts/verify-reproducible-build.sh --version 24.10
#   ./scripts/verify-reproducible-build.sh --target armsr-armv8 --version 24.10
#   SOURCE_DATE_EPOCH=1700000000 ./scripts/verify-reproducible-build.sh
#   OWRT_VERIFY_TARGET and --target select the SDK target (default x86-64).
#
# Requires: Linux x86_64, Docker, prior or implicit feeds setup via docker-sdk.sh build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sdk-matrix.sh
source "${ROOT}/scripts/lib/sdk-matrix.sh"

TARGET="${OWRT_VERIFY_TARGET:-x86-64}"
VERSIONS=(23.05 24.10 25.12)

usage() {
	sed -n '1,10p' "$0"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) VERSIONS=("${2:?}"); shift 2 ;;
		--target) TARGET="${2:?}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "unknown arg: $1" >&2; usage >&2; exit 1 ;;
	esac
done

artifact_sha() {
	local version_label="$1"
	local arch="${SDK_MATRIX_PACKAGE_ARCH:?}"
	local dir="${ROOT}/out/${arch}/${version_label}"
	local path
	local -a cands=()
	sdk_matrix_out_package_candidates "$dir" cands
	[[ ${#cands[@]} -ge 1 ]] || return 1
	path="${cands[0]}"
	[[ -n "$path" && -f "$path" ]] || return 1
	sha256sum "$path" | awk '{print $1 " " $2}'
}

verify_one() {
	local version_key="$1" label h1 h2 f1 f2 out
	sdk_matrix_validate_version "$version_key"
	sdk_matrix_validate_target "$TARGET"
	sdk_matrix_resolve "$TARGET" "$version_key"
	label="$SDK_MATRIX_VERSION_LABEL"

	export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(sdk_matrix_source_date_epoch)}"
	echo "== reproducible build: ${version_key} (${label}) SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} ==" >&2

	# main() uses `verify_one || fail=1`, which disables errexit here.
	# Propagate every required operation so a leftover artifact cannot be
	# hashed twice and reported as reproducible (#1281).
	if ! sdk_matrix_feeds_ready 2>/dev/null; then
		echo "→ initial build (feeds setup)..." >&2
		"${ROOT}/scripts/docker-sdk.sh" build --target "$TARGET" --version "$version_key" || {
			echo "initial docker-sdk build failed for ${version_key}" >&2
			return 1
		}
	else
		echo "→ build pass 1..." >&2
		sdk_matrix_make || {
			echo "make pass 1 failed for ${label}" >&2
			return 1
		}
		sdk_matrix_copy_out || {
			echo "copy-out pass 1 failed for ${label}" >&2
			return 1
		}
	fi

	out="$(artifact_sha "$label")" || {
		echo "no artifact after pass 1 for ${label}" >&2
		return 1
	}
	read -r h1 f1 <<< "$out"
	if [[ -z "$h1" ]]; then
		echo "no artifact after pass 1 for ${label}" >&2
		return 1
	fi
	echo "  pass 1: ${h1}  ${f1##*/}" >&2

	echo "→ clean + build pass 2..." >&2
	sdk_matrix_clean_package || {
		echo "package clean failed for ${label}" >&2
		return 1
	}
	sdk_matrix_make || {
		echo "make pass 2 failed for ${label}" >&2
		return 1
	}
	sdk_matrix_copy_out || {
		echo "copy-out pass 2 failed for ${label}" >&2
		return 1
	}

	out="$(artifact_sha "$label")" || {
		echo "no artifact after pass 2 for ${label}" >&2
		return 1
	}
	read -r h2 f2 <<< "$out"
	if [[ -z "$h2" ]]; then
		echo "no artifact after pass 2 for ${label}" >&2
		return 1
	fi
	echo "  pass 2: ${h2}  ${f2##*/}" >&2

	if [[ "$h1" != "$h2" ]]; then
		echo "REPRODUCIBILITY FAIL: ${version_key} sha256 mismatch" >&2
		echo "  $h1" >&2
		echo "  $h2" >&2
		return 1
	fi
	echo "== OK: ${version_key} reproducible ==" >&2
}

main() {
	local v fail=0
	for v in "${VERSIONS[@]}"; do
		verify_one "$v" || fail=1
	done
	[[ $fail -eq 0 ]] || exit 1
	echo "All requested versions are reproducible." >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main
fi
