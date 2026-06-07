#!/usr/bin/env bash
# Download official OpenWrt x86/64 QEMU disk image (EFI ext4 combined).
#
# Usage:
#   RELEASE=24.10.5 ./scripts/download-openwrt-x86-64.sh
#   RELEASE=23.05.5 ./scripts/download-openwrt-x86-64.sh
#
# Output: lab/images/openwrt-x86-64-<RELEASE>.img
set -euo pipefail

RELEASE="${RELEASE:-24.10.5}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/lab/images"
mkdir -p "${OUT}"

if [[ "$RELEASE" == "snapshot" ]]; then
	BASE="https://downloads.openwrt.org/snapshots/targets/x86/64"
	IMG_OUT="openwrt-x86-64-snapshot.img"
	IMG_VARIANTS=(
		"openwrt-x86-64-generic-ext4-combined-efi.img.gz"
		"openwrt-x86-64-generic-ext4-combined.img.gz"
	)
else
	BASE="https://downloads.openwrt.org/releases/${RELEASE}/targets/x86/64"
	IMG_OUT="openwrt-x86-64-${RELEASE}.img"
	IMG_VARIANTS=(
		"openwrt-${RELEASE}-x86-64-generic-ext4-combined-efi.img.gz"
		"openwrt-${RELEASE}-x86-64-generic-ext4-combined.img.gz"
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
set +e
gzip -dc "${OUT}/${IMG_GZ}" > "${OUT}/${IMG_OUT}"
gz_rc=$?
set -e
rm -f "${OUT}/${IMG_GZ}"
[[ -s "${OUT}/${IMG_OUT}" ]] || { echo "decompress failed (gzip exit ${gz_rc})" >&2; exit 1; }
if [[ $gz_rc -ne 0 && $gz_rc -ne 2 ]]; then
	echo "decompress failed (gzip exit ${gz_rc})" >&2
	exit 1
fi

if [[ "${RELEASE}" == "24.10.5" ]]; then
	ln -sf "${IMG_OUT}" "${OUT}/openwrt-x86-64.img"
fi

echo "Done."
echo "  OWRT_X86_IMG=${OUT}/${IMG_OUT}"
echo "Run: OWRT_X86_IMG=${OUT}/${IMG_OUT} ./scripts/run-openwrt-x86-qemu.sh"
