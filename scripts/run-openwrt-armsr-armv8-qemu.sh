#!/usr/bin/env bash
# Run OpenWrt armsr/armv8 disk image in QEMU on Linux x86_64.
#
# Networking matches the verified x86 lab layout (single slirp NIC + hostfwd):
#   -nic user,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22
#   guest network.lan.proto=dhcp (qemu-lab-prepare-image.sh)
#
#   ./scripts/run-openwrt-armsr-armv8-qemu.sh
#   ./scripts/run-openwrt-armsr-armv8-qemu.sh --stop
#   OWRT_QEMU_DUAL_NIC=1 ...   # optional legacy dual-NIC (not recommended)
#
# LuCI http://localhost:8080/cgi-bin/luci/
# SSH   ssh -p 2222 root@localhost
#
# Legacy macOS (unmaintained): archive/scripts/legacy/run-openwrt-armsr-armv8-qemu-macos.sh
#
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
	echo "Supported platform: Linux x86_64 only." >&2
	echo "Legacy macOS: archive/scripts/legacy/run-openwrt-armsr-armv8-qemu-macos.sh" >&2
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
OWRT_QEMU_MEM="${OWRT_QEMU_MEM:-1024}"

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
			die "host port ${port} (${spec#*:}) already in use — stop other QEMU (./scripts/run-openwrt-armsr-armv8-qemu.sh --stop)"
		fi
	done
}

if [[ "${1:-}" == "--stop" ]]; then
	stop_qemu
	exit 0
fi

resolve_disk() {
	if [[ -n "${OWRT_IMG:-}" ]]; then echo "${OWRT_IMG}"; return; fi
	if [[ -n "${OWRT_RELEASE:-}" ]]; then
		local rel_img="${IMG_DIR}/openwrt-armsr-armv8-${OWRT_RELEASE}.img"
		[[ -f "${rel_img}" ]] && echo "${rel_img}" && return
	fi
	if [[ -f "${IMG_DIR}/openwrt-armsr-armv8.img" ]]; then echo "${IMG_DIR}/openwrt-armsr-armv8.img"; return; fi
	shopt -s nullglob
	local candidates=(
		"${IMG_DIR}"/openwrt-armsr-armv8-*.img
		"${IMG_DIR}"/openwrt-*-armsr-armv8-generic-ext4-combined-efi.img
	)
	shopt -u nullglob
	[[ ${#candidates[@]} -ge 1 ]] && echo "${candidates[0]}" && return
	echo ""
}

resolve_uboot() {
	if [[ -n "${OWRT_UBOOT:-}" ]]; then echo "${OWRT_UBOOT}"; return; fi
	if [[ -n "${OWRT_RELEASE:-}" ]]; then
		local rel_uboot="${IMG_DIR}/u-boot-qemu_armv8-${OWRT_RELEASE}.bin"
		[[ -f "${rel_uboot}" ]] && echo "${rel_uboot}" && return
	fi
	[[ -f "${IMG_DIR}/u-boot-qemu_armv8.bin" ]] && echo "${IMG_DIR}/u-boot-qemu_armv8.bin" && return
	[[ -f "${IMG_DIR}/u-boot-qemu_armv8/u-boot.bin" ]] && echo "${IMG_DIR}/u-boot-qemu_armv8/u-boot.bin" && return
	shopt -s nullglob
	local candidates=( "${IMG_DIR}"/u-boot-qemu_armv8-*.bin )
	shopt -u nullglob
	[[ ${#candidates[@]} -ge 1 ]] && echo "${candidates[0]}" && return
	echo ""
}

OWRT_IMG="$(resolve_disk)"
OWRT_UBOOT="$(resolve_uboot)"

[[ -n "${OWRT_IMG}" && -f "${OWRT_IMG}" ]] || die "No disk image under ${IMG_DIR}/ — run scripts/download-openwrt-armsr-armv8.sh"
[[ -n "${OWRT_UBOOT}" && -f "${OWRT_UBOOT}" ]] || die "Missing U-Boot — run scripts/download-openwrt-armsr-armv8.sh"

check_host_ports
mkdir -p "$(dirname "${OWRT_CONSOLE_LOG}")"
: > "${OWRT_CONSOLE_LOG}"

NIC_USER="$(qemu_lab_nic_user "${OWRT_HOSTFWD_HTTP}" "${OWRT_HOSTFWD_SSH}")"

echo "Using disk:  ${OWRT_IMG}"
echo "Using U-Boot: ${OWRT_UBOOT}"
echo "Console log: ${OWRT_CONSOLE_LOG}"
echo "Accel:       tcg"
echo "NIC:         -nic ${NIC_USER}"
echo "LuCI  http://localhost:${OWRT_HOSTFWD_HTTP}/cgi-bin/luci/"
echo "SSH   ssh -p ${OWRT_HOSTFWD_SSH} root@localhost"
echo "Serial:      nc ${OWRT_SERIAL_TCP}"
if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]]; then
	echo "Guest LAN:   dhcp on slirp (prepare image: sudo OWRT_IMG=${OWRT_IMG} ./scripts/qemu-lab-prepare-image.sh)"
fi
if [[ "${OWRT_QEMU_DUAL_NIC:-0}" == "1" ]]; then
	echo "NIC layout:  dual user netdevs (legacy — OWRT_QEMU_DUAL_NIC=1)"
else
	echo "NIC layout:  single user netdev (same as x86 lab)"
fi

QEMU_ARGS=(
	-nographic
	-cpu cortex-a53 -machine virt -accel tcg
	-bios "${OWRT_UBOOT}"
	-smp "${OWRT_QEMU_SMP}" -m "${OWRT_QEMU_MEM}"
	-drive "file=${OWRT_IMG},format=raw,index=0,media=disk"
	-device virtio-rng-pci
)

if [[ "${OWRT_QEMU_DUAL_NIC:-0}" == "1" ]]; then
	NETDEV_LAN="$(qemu_lab_netdev_lan "${OWRT_HOSTFWD_HTTP}" "${OWRT_HOSTFWD_SSH}")"
	QEMU_ARGS+=(
		-netdev "${NETDEV_LAN}"
		-device virtio-net-pci,netdev="${OWRT_LAB_NETDEV_ID}",mac=52:54:00:44:55:66
		-netdev "user,id=wan0,net=${OWRT_LAB_WAN_SUBNET}"
		-device virtio-net-pci,netdev=wan0,mac=52:54:00:11:22:33
	)
else
	QEMU_ARGS+=(-nic "${NIC_USER}")
fi

QEMU_ARGS+=(-monitor none)

# Default: mon:stdio (headless boot + tee console log). Socket serial: OWRT_QEMU_SERIAL_SOCKET=1
if [[ "${OWRT_QEMU_SERIAL_SOCKET:-0}" == "1" ]]; then
	QEMU_ARGS+=(
		-chardev "socket,id=ser0,host=${OWRT_SERIAL_TCP%:*},port=${OWRT_SERIAL_TCP#*:},server=on,wait=off"
		-serial chardev:ser0
	)
else
	QEMU_ARGS+=(-serial mon:stdio)
fi

exec qemu-system-aarch64 "${QEMU_ARGS[@]}" 2>&1 | tee -a "${OWRT_CONSOLE_LOG}"
