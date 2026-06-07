#!/usr/bin/env bash
# Download official OpenWrt armsr/armv8 QEMU disk image + U-Boot (no image build).
# Usage:
#   RELEASE=24.10.5 ./scripts/download-openwrt-armsr-armv8.sh
#   RELEASE=23.05.5 ./scripts/download-openwrt-armsr-armv8.sh
#
# Outputs under lab/images/ (gitignored):
#   openwrt-armsr-armv8-<RELEASE>.img  — uncompressed ext4 combined EFI image
#   u-boot-qemu_armv8-<RELEASE>.bin    — for qemu -bios (per release)
#
# Legacy symlink (default RELEASE only): openwrt-armsr-armv8.img
set -euo pipefail

RELEASE="${RELEASE:-24.10.5}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/lab/images"
mkdir -p "${OUT}"

if [[ "$RELEASE" == "snapshot" ]]; then
	BASE="https://downloads.openwrt.org/snapshots/targets/armsr/armv8"
	IMG_OUT="openwrt-armsr-armv8-snapshot.img"
	UBOOT_OUT="u-boot-qemu_armv8-snapshot.bin"
	IMG_VARIANTS=(
		"openwrt-armsr-armv8-generic-ext4-combined-efi.img.gz"
		"openwrt-armsr-armv8-generic-ext4-combined.img.gz"
	)
else
	BASE="https://downloads.openwrt.org/releases/${RELEASE}/targets/armsr/armv8"
	IMG_OUT="openwrt-armsr-armv8-${RELEASE}.img"
	UBOOT_OUT="u-boot-qemu_armv8-${RELEASE}.bin"
	# 24.10+ ships combined-efi; 23.05 uses combined (no -efi suffix).
	IMG_VARIANTS=(
		"openwrt-${RELEASE}-armsr-armv8-generic-ext4-combined-efi.img.gz"
		"openwrt-${RELEASE}-armsr-armv8-generic-ext4-combined.img.gz"
	)
fi
IMG_GZ=""
for candidate in "${IMG_VARIANTS[@]}"; do
	if curl -fsSIL "${BASE}/${candidate}" >/dev/null 2>&1; then
		IMG_GZ="$candidate"
		break
	fi
done
[[ -n "$IMG_GZ" ]] || { echo "no combined disk image found under ${BASE}/" >&2; exit 1; }

echo "Fetching ${IMG_GZ} ..."
curl -fsSL -o "${OUT}/${IMG_GZ}" "${BASE}/${IMG_GZ}"
echo "Decompressing ..."
# Some release artifacts have trailing bytes (gzip exit 2); verify output size.
set +e
gzip -dc "${OUT}/${IMG_GZ}" > "${OUT}/${IMG_OUT}"
gz_rc=$?
set -e
rm -f "${OUT}/${IMG_GZ}"
if [[ ! -s "${OUT}/${IMG_OUT}" ]]; then
	echo "decompress failed (gzip exit ${gz_rc})" >&2
	exit 1
fi
if [[ $gz_rc -ne 0 && $gz_rc -ne 2 ]]; then
	echo "decompress failed (gzip exit ${gz_rc})" >&2
	exit 1
fi

echo "Fetching u-boot-qemu_armv8/u-boot.bin ..."
curl -fsSL -o "${OUT}/${UBOOT_OUT}" "${BASE}/u-boot-qemu_armv8/u-boot.bin"

if [[ "${RELEASE}" == "24.10.5" ]]; then
	ln -sf "${IMG_OUT}" "${OUT}/openwrt-armsr-armv8.img"
	ln -sf "${UBOOT_OUT}" "${OUT}/u-boot-qemu_armv8.bin"
fi

echo "Done."
echo "  OWRT_IMG=${OUT}/${IMG_OUT}"
echo "  OWRT_UBOOT=${OUT}/${UBOOT_OUT}"
echo "Run: OWRT_IMG=${OUT}/${IMG_OUT} OWRT_UBOOT=${OUT}/${UBOOT_OUT} ${ROOT}/scripts/run-openwrt-armsr-armv8-qemu.sh"
