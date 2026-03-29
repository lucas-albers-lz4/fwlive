#!/usr/bin/env bash
# Run OpenWrt armsr/armv8 disk image in QEMU on macOS.
#
# Default in this script: vmnet (bridged) NICs — use the guest’s real IP for SSH :22
# and LuCI :80 / :443. Discover IP via /var/db/dhcpd_leases and your QEMU mac= addresses.
#
# Legacy (optional): QEMU user networking with hostfwd (LuCI :8080, SSH :2222 on the host)
# is left commented below; use only if you explicitly configure hostfwd=tcp::8080-:80 etc.
#
# Prefer downloaded images: run scripts/download-openwrt-armsr-armv8.sh first.
#
#   export OWRT_IMG=~/openwrt-arm-64.img
#   export OWRT_UBOOT=~/openwrt/bin/targets/armsr/armv8/u-boot-qemu_armv8/u-boot.bin
#   ./scripts/run-openwrt-armsr-armv8-qemu.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG_DIR="${ROOT}/lab/images"

resolve_disk() {
	if [[ -n "${OWRT_IMG:-}" ]]; then
		echo "${OWRT_IMG}"
		return
	fi
	if [[ -f "${IMG_DIR}/openwrt-armsr-armv8.img" ]]; then
		echo "${IMG_DIR}/openwrt-armsr-armv8.img"
		return
	fi
	shopt -s nullglob
	local candidates=( "${IMG_DIR}"/openwrt-*-armsr-armv8-generic-ext4-combined-efi.img )
	shopt -u nullglob
	if [[ ${#candidates[@]} -ge 1 ]]; then
		echo "${candidates[0]}"
		return
	fi
	echo ""
}

resolve_uboot() {
	if [[ -n "${OWRT_UBOOT:-}" ]]; then
		echo "${OWRT_UBOOT}"
		return
	fi
	if [[ -f "${IMG_DIR}/u-boot-qemu_armv8.bin" ]]; then
		echo "${IMG_DIR}/u-boot-qemu_armv8.bin"
		return
	fi
	if [[ -f "${IMG_DIR}/u-boot-qemu_armv8/u-boot.bin" ]]; then
		echo "${IMG_DIR}/u-boot-qemu_armv8/u-boot.bin"
		return
	fi
	echo ""
}

OWRT_IMG="$(resolve_disk)"
OWRT_UBOOT="$(resolve_uboot)"

if [[ -z "${OWRT_IMG}" || ! -f "${OWRT_IMG}" ]]; then
	echo "No disk image found under ${IMG_DIR}/" >&2
	echo "Expected openwrt-armsr-armv8.img or openwrt-*-armsr-armv8-generic-ext4-combined-efi.img" >&2
	exit 1
fi
if [[ -z "${OWRT_UBOOT}" || ! -f "${OWRT_UBOOT}" ]]; then
	echo "Missing U-Boot for QEMU (-bios). Fetch it next to your .img:" >&2
	echo "  curl -fsSL -o ${IMG_DIR}/u-boot-qemu_armv8.bin \\" >&2
	echo "    https://downloads.openwrt.org/releases/24.10.0/targets/armsr/armv8/u-boot-qemu_armv8/u-boot.bin" >&2
	echo "Or: RELEASE=24.10.0 ${ROOT}/scripts/download-openwrt-armsr-armv8.sh" >&2
	exit 1
fi

echo "Using disk:  ${OWRT_IMG}"
echo "Using U-Boot: ${OWRT_UBOOT}"

# Remove the second -netdev and second -device. 
# We consolidate everything into one powerful pipe (net0).
#exec qemu-system-aarch64 -nographic \
#    -cpu cortex-a53 -machine virt \
#    -bios "${OWRT_UBOOT}" \
#    -smp 1 -m 1024 \
#    -device virtio-rng-pci \
#    -drive "file=${OWRT_IMG},format=raw,index=0,media=disk" \
#    -netdev "user,id=net0,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22" \
#    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56

sudo qemu-system-aarch64 -nographic \
    -cpu cortex-a53 -machine virt -accel hvf \
    -bios "${OWRT_UBOOT}" \
    -smp 1 -m 1024 \
    -drive "file=${OWRT_IMG},format=raw,index=0,media=disk" \
    -device virtio-rng-pci \
    -netdev vmnet-shared,id=wan0 \
    -device virtio-net-device,netdev=wan0,mac=52:54:00:11:22:33 \
    -netdev vmnet-host,id=lan0 \
    -device virtio-net-device,netdev=lan0,mac=52:54:00:44:55:66
