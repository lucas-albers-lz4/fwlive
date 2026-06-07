#!/usr/bin/env bash
# One-time tweaks to lab/images/openwrt-armsr-armv8.img for QEMU user-net + hostfwd.
#
# - HTTP-only uhttpd (no TLS cert hang in headless QEMU)
# - rfc1918_filter off (slirp host may not match strict LAN checks)
# - syn_flood off (avoid lockout while retrying SSH during slow TCG boot)
# - defaults input ACCEPT (lab only — do not use on production routers)
#
# Usage: sudo ./scripts/qemu-lab-prepare-image.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OWRT_LAB_NET_MODE="${OWRT_LAB_NET_MODE:-dhcp}"
# shellcheck source=lib/qemu-lab-net.sh
source "${ROOT}/scripts/lib/qemu-lab-net.sh"
IMG="${OWRT_IMG:-${ROOT}/lab/images/openwrt-armsr-armv8.img}"
MNT="/mnt/owrt-lab"
LAB_MASK="${OWRT_LAB_SUBNET#*/}"

[[ -f "$IMG" ]] || { echo "missing image: $IMG" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || { echo "run as root (needs loop mount)" >&2; exit 1; }

LOOP="$(losetup -fP --show "$IMG")"
cleanup() {
	umount "$MNT" 2>/dev/null || true
	losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$MNT"
mount -o rw "${LOOP}p2" "$MNT"

if grep -q "ucode_prefix" "$MNT/etc/config/uhttpd" 2>/dev/null; then
	sed -i "s|list ucode_prefix.*|list ucode_prefix '/cgi-bin/luci=/usr/share/ucode/luci/dispatcher.uc'|" "$MNT/etc/config/uhttpd"
	sed -i "/listen_https/d; /option cert /d; /option key /d" "$MNT/etc/config/uhttpd"
	sed -i "s/option rfc1918_filter '1'/option rfc1918_filter '0'/" "$MNT/etc/config/uhttpd"
else
	# Legacy lua LuCI images
	sed -i "s/option rfc1918_filter '1'/option rfc1918_filter '0'/" "$MNT/etc/config/uhttpd"
	sed -i "/listen_https/d; /option cert /d; /option key /d" "$MNT/etc/config/uhttpd"
fi
sed -i "s/option syn_flood '1'/option syn_flood '0'/" "$MNT/etc/config/firewall"
sed -i "s/option input 'REJECT'/option input 'ACCEPT'/" "$MNT/etc/config/firewall"

# LAN: DHCP for default slirp (recommended); static only when OWRT_LAB_NET_MODE=static.
if [[ -f "$MNT/etc/config/network" ]]; then
	if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]]; then
		sed -i "/config interface 'lan'/,/^$/{
			s/option proto '[^']*'/option proto 'dhcp'/
			/option ipaddr/d
			/option netmask/d
		}" "$MNT/etc/config/network"
	else
		sed -i "/config interface 'lan'/,/^$/{
			s/option proto '[^']*'/option proto 'static'/
			s/option ipaddr '[^']*'/option ipaddr '${OWRT_LAB_IP}'/
			s/option netmask '[^']*'/option netmask '255.255.255.0'/
		}" "$MNT/etc/config/network"
	fi
fi

# Late-boot SSH helper (QEMU user-net / hostfwd can be slow to accept connections)
if [[ ! -f "$MNT/etc/init.d/qemu-lab-ssh" ]]; then
	cat >"$MNT/etc/init.d/qemu-lab-ssh" <<'EOS'
#!/bin/sh /etc/rc.common
START=99
start() {
	/etc/init.d/dropbear start
}
EOS
	chmod +x "$MNT/etc/init.d/qemu-lab-ssh"
	ln -sf ../init.d/qemu-lab-ssh "$MNT/etc/rc.d/S99qemu-lab-ssh"
fi

if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]]; then
	echo "Prepared $IMG for QEMU lab (LAN dhcp + slirp hostfwd, uhttpd, relaxed firewall)."
else
	echo "Prepared $IMG for QEMU lab (LAN ${OWRT_LAB_IP}/${LAB_MASK}, uhttpd, relaxed firewall)."
fi
