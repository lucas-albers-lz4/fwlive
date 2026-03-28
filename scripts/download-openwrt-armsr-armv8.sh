#!/usr/bin/env bash
# Download official OpenWrt armsr/armv8 QEMU disk image + U-Boot (no image build).
# Usage:
#   RELEASE=24.10.0 ./scripts/download-openwrt-armsr-armv8.sh
#
# Outputs under lab/images/ (gitignored):
#   openwrt-armsr-armv8.img       — uncompressed ext4 combined EFI image
#   u-boot-qemu_armv8.bin         — for qemu -bios
#
#set -euo pipefail

RELEASE="${RELEASE:-24.10.5}"
BASE="https://downloads.openwrt.org/releases/${RELEASE}/targets/armsr/armv8"
IMG_GZ="openwrt-${RELEASE}-armsr-armv8-generic-ext4-combined-efi.img.gz"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/lab/images"
mkdir -p "${OUT}"

echo "Fetching ${IMG_GZ} ..."
curl -fsSL -o "${OUT}/${IMG_GZ}" "${BASE}/${IMG_GZ}"
echo "Decompressing ..."
gunzip -f "${OUT}/${IMG_GZ}"
mv -f "${OUT}/openwrt-${RELEASE}-armsr-armv8-generic-ext4-combined-efi.img" "${OUT}/openwrt-armsr-armv8.img"

echo "Fetching u-boot-qemu_armv8/u-boot.bin ..."
echo curl -fsSL -o "${OUT}/u-boot-qemu_armv8.bin" "${BASE}/u-boot-qemu_armv8/u-boot.bin"
curl -fsSL -o "${OUT}/u-boot-qemu_armv8.bin" "${BASE}/u-boot-qemu_armv8/u-boot.bin"

echo "Done."
echo "  OWRT_IMG=${OUT}/openwrt-armsr-armv8.img"
echo "  OWRT_UBOOT=${OUT}/u-boot-qemu_armv8.bin"
echo "Run: OWRT_IMG=${OUT}/openwrt-armsr-armv8.img OWRT_UBOOT=${OUT}/u-boot-qemu_armv8.bin ${ROOT}/scripts/run-openwrt-armsr-armv8-qemu.sh"
