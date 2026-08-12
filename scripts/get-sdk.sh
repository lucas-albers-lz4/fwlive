#!/usr/bin/env bash
# Download and extract the OpenWrt armsr/armv8 SDK next to the repo under .sdk/ (gitignored).
# Copy the exact .tar.zst name from https://downloads.openwrt.org/releases/<REL>/targets/armsr/armv8/
# if the gcc suffix changes between point releases.
#
# Usage:
#   ./scripts/get-sdk.sh
#   RELEASE=24.10.5 ./scripts/get-sdk.sh
set -euo pipefail

RELEASE="${RELEASE:-24.10.5}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAR="openwrt-sdk-${RELEASE}-armsr-armv8_gcc-13.3.0_musl.Linux-x86_64.tar.zst"
BASE="https://downloads.openwrt.org/releases/${RELEASE}/targets/armsr/armv8"
URL="${BASE}/${TAR}"

# Same shape as download-openwrt-*.sh — verify against upstream sha256sums
# before extraction (issue #166 class sibling).
verify_downloaded_sha256() {
	local file="$1" name="$2" manifest="$3" expected actual
	expected="$(awk -v n="$name" '$2 == "*" n {print $1; exit}' "$manifest")"
	if [[ -z "$expected" ]]; then
		rm -f "$file"
		echo "verify: sha256sums has no entry for '${name}' — cannot verify, aborting" >&2
		exit 1
	fi
	if ! command -v sha256sum >/dev/null 2>&1; then
		echo "verify: 'sha256sum' not available — cannot verify '${name}'" >&2
		rm -f "$file"
		exit 1
	fi
	actual="$(sha256sum "$file" | awk '{print $1}')"
	if [[ "$actual" != "$expected" ]]; then
		rm -f "$file"
		echo "verify: sha256 MISMATCH for '${name}'" >&2
		echo "  expected: ${expected}" >&2
		echo "  actual:   ${actual}" >&2
		exit 1
	fi
	echo "verify: ${name} OK (${expected})" >&2
}

mkdir -p "${ROOT}/.sdk"
cd "${ROOT}/.sdk"

SUM_MANIFEST="$(mktemp -t fwlive-sdk-sha256sums.XXXXXX)"
trap 'rm -f "${SUM_MANIFEST}"' EXIT
echo "Fetching sha256sums from ${BASE}/ ..."
curl -fsSL -o "${SUM_MANIFEST}" "${BASE}/sha256sums"

echo "Fetching ${URL} ..."
curl -fsSL -o "${TAR}" "${URL}"
verify_downloaded_sha256 "${TAR}" "${TAR}" "${SUM_MANIFEST}"
echo "Extracting ..."
tar -xf "${TAR}"
echo "Done. SDK root:"
echo "  ${ROOT}/.sdk/openwrt-sdk-${RELEASE}-armsr-armv8_gcc-13.3.0_musl.Linux-x86_64"
