#!/usr/bin/env bash
# Run OpenWrt armsr/armv8 disk image in QEMU on Linux x86_64.
#
# Two -netdev user backends. Hostfwd (8080→80, 2222→22) on the *first* NIC (eth0).
# Default OpenWrt armsr images attach br-lan to eth0; hostfwd on eth1 never reaches LuCI.
# LuCI http://127.0.0.1:8080  SSH ssh -p 2222 root@127.0.0.1
# Deploy: scripts/agent-build-and-deploy.sh --legacy-hostfwd
#
# Legacy macOS (vmnet): scripts/legacy/run-openwrt-armsr-armv8-qemu-macos.sh
#
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
	echo "Supported platform: Linux x86_64 only." >&2
	echo "Legacy macOS: scripts/legacy/run-openwrt-armsr-armv8-qemu-macos.sh" >&2
	exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMG_DIR="${ROOT}/lab/images"

resolve_disk() {
	if [[ -n "${OWRT_IMG:-}" ]]; then echo "${OWRT_IMG}"; return; fi
	if [[ -f "${IMG_DIR}/openwrt-armsr-armv8.img" ]]; then echo "${IMG_DIR}/openwrt-armsr-armv8.img"; return; fi
	shopt -s nullglob
	local candidates=( "${IMG_DIR}"/openwrt-*-armsr-armv8-generic-ext4-combined-efi.img )
	shopt -u nullglob
	[[ ${#candidates[@]} -ge 1 ]] && echo "${candidates[0]}" && return
	echo ""
}

resolve_uboot() {
	if [[ -n "${OWRT_UBOOT:-}" ]]; then echo "${OWRT_UBOOT}"; return; fi
	[[ -f "${IMG_DIR}/u-boot-qemu_armv8.bin" ]] && echo "${IMG_DIR}/u-boot-qemu_armv8.bin" && return
	[[ -f "${IMG_DIR}/u-boot-qemu_armv8/u-boot.bin" ]] && echo "${IMG_DIR}/u-boot-qemu_armv8/u-boot.bin" && return
	echo ""
}

OWRT_IMG="$(resolve_disk)"
OWRT_UBOOT="$(resolve_uboot)"

[[ -n "${OWRT_IMG}" && -f "${OWRT_IMG}" ]] || { echo "No disk image under ${IMG_DIR}/ — run scripts/download-openwrt-armsr-armv8.sh" >&2; exit 1; }
[[ -n "${OWRT_UBOOT}" && -f "${OWRT_UBOOT}" ]] || { echo "Missing U-Boot — run scripts/download-openwrt-armsr-armv8.sh" >&2; exit 1; }

echo "Using disk:  ${OWRT_IMG}"
echo "Using U-Boot: ${OWRT_UBOOT}"
echo "LuCI http://127.0.0.1:8080  SSH: ssh -p 2222 root@127.0.0.1"

exec qemu-system-aarch64 -nographic \
	-cpu cortex-a53 -machine virt -accel tcg \
	-bios "${OWRT_UBOOT}" \
	-smp 1 -m 1024 \
	-drive "file=${OWRT_IMG},format=raw,index=0,media=disk" \
	-device virtio-rng-pci \
	-netdev user,id=lan0,net=192.168.2.0/24,dhcpstart=192.168.2.100,host=192.168.2.15,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22 \
	-device virtio-net-pci,netdev=lan0,mac=52:54:00:44:55:66 \
	-netdev user,id=wan0,net=10.0.3.0/24 \
	-device virtio-net-pci,netdev=wan0,mac=52:54:00:11:22:33
