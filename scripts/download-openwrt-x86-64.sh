#!/usr/bin/env bash
# Download official OpenWrt x86/64 QEMU disk image (EFI ext4 combined).
#
# Usage:
#   RELEASE=24.10.5 ./scripts/download-openwrt-x86-64.sh
#
# Output: lab/images/openwrt-x86-64.img
set -euo pipefail

RELEASE="${RELEASE:-24.10.5}"
BASE="https://downloads.openwrt.org/releases/${RELEASE}/targets/x86/64"
IMG_GZ="openwrt-${RELEASE}-x86-64-generic-ext4-combined-efi.img.gz"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/lab/images"
mkdir -p "${OUT}"

echo "Fetching ${IMG_GZ} ..."
curl -fsSL -o "${OUT}/${IMG_GZ}" "${BASE}/${IMG_GZ}"
echo "Decompressing ..."
gunzip -fk "${OUT}/${IMG_GZ}" 2>/dev/null || gzip -dc "${OUT}/${IMG_GZ}" > "${OUT}/openwrt-x86-64.img"
if [[ -f "${OUT}/openwrt-${RELEASE}-x86-64-generic-ext4-combined-efi.img" ]]; then
	mv -f "${OUT}/openwrt-${RELEASE}-x86-64-generic-ext4-combined-efi.img" "${OUT}/openwrt-x86-64.img"
fi

echo "Done."
echo "  OWRT_X86_IMG=${OUT}/openwrt-x86-64.img"
echo "Run: ./scripts/run-openwrt-x86-qemu.sh"
