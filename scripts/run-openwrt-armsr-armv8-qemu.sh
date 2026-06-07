#!/usr/bin/env bash
# Run OpenWrt armsr/armv8 disk image in QEMU on Linux x86_64.
#
# Default: slirp + LAN dhcp + hostfwd (see lib/qemu-lab-net.sh). Optional dual-NIC (WAN + LAN).
#
#   ./scripts/run-openwrt-armsr-armv8-qemu.sh          # start (foreground)
#   ./scripts/run-openwrt-armsr-armv8-qemu.sh --stop   # kill running instance
#   OWRT_QEMU_SINGLE_NIC=1 ...                         # one NIC only (simpler debug)
#
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
export OWRT_LAB_NET_MODE="${OWRT_LAB_NET_MODE:-dhcp}"
# shellcheck source=lib/qemu-lab-net.sh
source "${ROOT}/scripts/lib/qemu-lab-net.sh"
IMG_DIR="${ROOT}/lab/images"
OWRT_HOSTFWD_HTTP="${OWRT_HOSTFWD_HTTP:-8080}"
OWRT_HOSTFWD_SSH="${OWRT_HOSTFWD_SSH:-2222}"
OWRT_CONSOLE_LOG="${OWRT_CONSOLE_LOG:-${ROOT}/lab/qemu-console.log}"
OWRT_SERIAL_TCP="${OWRT_SERIAL_TCP:-127.0.0.1:4445}"
OWRT_QEMU_SMP="${OWRT_QEMU_SMP:-2}"
OWRT_QEMU_MEM="${OWRT_QEMU_MEM:-2048}"

die() { echo "error: $*" >&2; exit 1; }

stop_qemu() {
	if pkill -f 'qemu-system-aarch64.*openwrt-armsr-armv8' 2>/dev/null; then
		echo "Stopped running armsr QEMU instance."
	else
		echo "No armsr QEMU instance was running."
	fi
}

check_host_ports() {
	local port spec
	for spec in "${OWRT_HOSTFWD_HTTP}:HTTP" "${OWRT_HOSTFWD_SSH}:SSH"; do
		port="${spec%%:*}"
		if ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .; then
			die "host port ${port} (${spec#*:}) already in use — stop Docker owrt-x64-exp or another QEMU (./scripts/run-openwrt-armsr-armv8-qemu.sh --stop)"
		fi
	done
}

if [[ "${1:-}" == "--stop" ]]; then
	stop_qemu
	exit 0
fi

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

check_host_ports

mkdir -p "$(dirname "${OWRT_CONSOLE_LOG}")"
: > "${OWRT_CONSOLE_LOG}"

echo "Using disk:  ${OWRT_IMG}"
echo "Using U-Boot: ${OWRT_UBOOT}"
echo "Console log: ${OWRT_CONSOLE_LOG}"
NETDEV_LAN="$(qemu_lab_netdev_lan "${OWRT_HOSTFWD_HTTP}" "${OWRT_HOSTFWD_SSH}")"
echo "netdev:      ${NETDEV_LAN}"
echo "LuCI  http://localhost:${OWRT_HOSTFWD_HTTP}/cgi-bin/luci/"
echo "SSH   ssh -p ${OWRT_HOSTFWD_SSH} root@localhost"
echo "Serial:      nc ${OWRT_SERIAL_TCP}"
if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]]; then
	echo "Guest LAN:   dhcp on slirp (sudo ./scripts/qemu-lab-prepare-image.sh)"
else
	echo "Guest LAN:   ${OWRT_LAB_IP} (${OWRT_LAB_SUBNET})"
fi
if [[ "${OWRT_QEMU_SINGLE_NIC:-0}" == "1" ]]; then
	echo "NIC layout: single user netdev (eth0 / br-lan)"
else
	echo "NIC layout: dual user netdevs (eth0=LAN hostfwd, eth1=WAN)"
fi

QEMU_ARGS=(
	-nographic
	-cpu cortex-a53 -machine virt -accel tcg
	-bios "${OWRT_UBOOT}"
	-smp "${OWRT_QEMU_SMP}" -m "${OWRT_QEMU_MEM}"
	-drive "file=${OWRT_IMG},format=raw,index=0,media=disk"
	-device virtio-rng-pci
	-netdev "${NETDEV_LAN}"
	-device virtio-net-pci,netdev="${OWRT_LAB_NETDEV_ID}",mac=52:54:00:44:55:66
)
if [[ "${OWRT_QEMU_SINGLE_NIC:-0}" != "1" ]]; then
	QEMU_ARGS+=(
		-netdev "user,id=wan0,net=${OWRT_LAB_WAN_SUBNET}"
		-device virtio-net-pci,netdev=wan0,mac=52:54:00:11:22:33
	)
fi

QEMU_ARGS+=(
	-chardev "socket,id=ser0,host=${OWRT_SERIAL_TCP%:*},port=${OWRT_SERIAL_TCP#*:},server=on,wait=off"
	-serial chardev:ser0
	-monitor none
)
exec qemu-system-aarch64 "${QEMU_ARGS[@]}" 2>&1 | tee -a "${OWRT_CONSOLE_LOG}"
