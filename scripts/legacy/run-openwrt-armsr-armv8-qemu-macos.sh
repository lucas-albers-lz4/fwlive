#!/usr/bin/env bash
# UNMAINTAINED — macOS vmnet + hvf. Use Linux x86_64: scripts/run-openwrt-armsr-armv8-qemu.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMG_DIR="${ROOT}/lab/images"
OWRT_IMG="${OWRT_IMG:-${IMG_DIR}/openwrt-armsr-armv8.img}"
OWRT_UBOOT="${OWRT_UBOOT:-${IMG_DIR}/u-boot-qemu_armv8.bin}"
exec sudo qemu-system-aarch64 -nographic \
	-cpu cortex-a53 -machine virt -accel hvf \
	-bios "${OWRT_UBOOT}" -smp 1 -m 1024 \
	-drive "file=${OWRT_IMG},format=raw,index=0,media=disk" \
	-device virtio-rng-pci \
	-netdev vmnet-shared,id=wan0 \
	-device virtio-net-device,netdev=wan0,mac=52:54:00:11:22:33 \
	-netdev vmnet-host,id=lan0 \
	-device virtio-net-device,netdev=lan0,mac=52:54:00:44:55:66
