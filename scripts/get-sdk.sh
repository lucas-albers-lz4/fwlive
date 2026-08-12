#!/usr/bin/env bash
# Download and extract the OpenWrt armsr/armv8 SDK next to the repo under .sdk/ (gitignored).
# Copy the exact .tar.zst name from https://downloads.openwrt.org/releases/<REL>/targets/armsr/armv8/
# if the gcc suffix changes between point releases.
#
# Usage:
#   ./scripts/get-sdk.sh
#   RELEASE=24.10.8 ./scripts/get-sdk.sh
set -euo pipefail

RELEASE="${RELEASE:-24.10.8}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAR="openwrt-sdk-${RELEASE}-armsr-armv8_gcc-13.3.0_musl.Linux-x86_64.tar.zst"
URL="https://downloads.openwrt.org/releases/${RELEASE}/targets/armsr/armv8/${TAR}"

mkdir -p "${ROOT}/.sdk"
cd "${ROOT}/.sdk"
echo "Fetching ${URL} ..."
curl -fsSL -o "${TAR}" "${URL}"
echo "Extracting ..."
tar -xf "${TAR}"
echo "Done. SDK root:"
echo "  ${ROOT}/.sdk/openwrt-sdk-${RELEASE}-armsr-armv8_gcc-13.3.0_musl.Linux-x86_64"
