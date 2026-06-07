#!/usr/bin/env bash
# Run OpenWrt x86/64 disk image in QEMU on Linux x86_64 with KVM (fast lab guest).
#
# Networking matches the verified lab layout:
#   -nic user,hostfwd=tcp::8080-:80,hostfwd=tcp::2222-:22
#   guest network.lan.proto=dhcp (set by qemu-lab-prepare-image.sh)
#   LuCI http://localhost:8080/cgi-bin/luci/
#
#   ./scripts/run-openwrt-x86-qemu.sh
#   ./scripts/run-openwrt-x86-qemu.sh --stop
#
set -euo pipefail

if [[ "$(uname -m)" != "x86_64" ]]; then
	echo "x86_64 QEMU runner requires an x86_64 Linux host." >&2
	exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OWRT_LAB_NET_MODE="${OWRT_LAB_NET_MODE:-dhcp}"
# shellcheck source=lib/qemu-lab-net.sh
source "${ROOT}/scripts/lib/qemu-lab-net.sh"
IMG_DIR="${ROOT}/lab/images"
OWRT_IMG="${OWRT_X86_IMG:-${IMG_DIR}/openwrt-x86-64.img}"
OWRT_HOSTFWD_HTTP="${OWRT_HOSTFWD_HTTP:-8080}"
OWRT_HOSTFWD_SSH="${OWRT_HOSTFWD_SSH:-2222}"
OWRT_CONSOLE_LOG="${OWRT_CONSOLE_LOG:-${ROOT}/lab/qemu-x86-console.log}"
OWRT_SERIAL_TCP="${OWRT_SERIAL_TCP:-127.0.0.1:4444}"
OWRT_QEMU_MEM="${OWRT_QEMU_MEM:-1024}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-${IMG_DIR}/OVMF_VARS_4M.fd}"

die() { echo "error: $*" >&2; exit 1; }

stop_qemu() {
	if pkill -f 'qemu-system-x86_64.*openwrt-x86-64' 2>/dev/null; then
		echo "Stopped running x86 QEMU instance."
	else
		echo "No x86 QEMU instance was running."
	fi
}

check_host_ports() {
	local port spec
	for spec in "${OWRT_HOSTFWD_HTTP}:HTTP" "${OWRT_HOSTFWD_SSH}:SSH"; do
		port="${spec%%:*}"
		if ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .; then
			die "host port ${port} (${spec#*:}) already in use — stop Docker owrt-x64-exp or another QEMU"
		fi
	done
}

if [[ "${1:-}" == "--stop" ]]; then
	stop_qemu
	exit 0
fi

[[ -f "${OWRT_IMG}" ]] || die "No disk image at ${OWRT_IMG} — run: RELEASE=24.10.5 ./scripts/download-openwrt-x86-64.sh"
[[ -f "${OVMF_CODE}" ]] || die "Missing OVMF firmware (${OVMF_CODE}) — install qemu-system-x86 ovmf"
if [[ ! -f "${OVMF_VARS}" ]]; then
	cp /usr/share/OVMF/OVMF_VARS_4M.fd "${OVMF_VARS}"
fi

check_host_ports
mkdir -p "$(dirname "${OWRT_CONSOLE_LOG}")"
: > "${OWRT_CONSOLE_LOG}"

ACCEL="tcg"
[[ -e /dev/kvm ]] && ACCEL="kvm"

NIC_USER="$(qemu_lab_nic_user "${OWRT_HOSTFWD_HTTP}" "${OWRT_HOSTFWD_SSH}")"

echo "Using disk:  ${OWRT_IMG}"
echo "Console log: ${OWRT_CONSOLE_LOG}"
echo "Accel:       ${ACCEL}"
echo "NIC:         -nic ${NIC_USER}"
echo "LuCI  http://localhost:${OWRT_HOSTFWD_HTTP}/cgi-bin/luci/"
echo "SSH   ssh -p ${OWRT_HOSTFWD_SSH} root@localhost"
echo "Serial:      nc ${OWRT_SERIAL_TCP}"
if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]]; then
	echo "Guest LAN:   dhcp on slirp (prepare image: sudo OWRT_IMG=${OWRT_IMG} ./scripts/qemu-lab-prepare-image.sh)"
fi

exec qemu-system-x86_64 \
	-machine q35 -accel "${ACCEL}" -cpu host \
	-smp 2 -m "${OWRT_QEMU_MEM}" \
	-chardev "socket,id=ser0,host=${OWRT_SERIAL_TCP%:*},port=${OWRT_SERIAL_TCP#*:},server=on,wait=off" \
	-serial chardev:ser0 \
	-monitor none \
	-drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
	-drive if=pflash,format=raw,file="${OVMF_VARS}" \
	-drive "file=${OWRT_IMG},format=raw,if=virtio" \
	-nic "${NIC_USER}" \
	2>&1 | tee -a "${OWRT_CONSOLE_LOG}"
