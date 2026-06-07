#!/usr/bin/env bash
# One-time tweaks to lab/images/openwrt-armsr-armv8.img for QEMU user-net + hostfwd.
#
# - HTTP-only uhttpd (no TLS cert hang in headless QEMU)
# - rfc1918_filter off (slirp host may not match strict LAN checks)
# - syn_flood off (avoid lockout while retrying SSH during slow TCG boot)
# - defaults input ACCEPT (lab only — do not use on production routers)
# - clear root password (armsr images may ship with one; x86 lab expects empty)
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

if [[ -b "${LOOP}p2" ]] && command -v e2fsck >/dev/null 2>&1; then
	e2fsck -fy "${LOOP}p2" >/dev/null 2>&1 || true
fi

mkdir -p "$MNT"
mount -o rw "${LOOP}p2" "$MNT"

# LuCI/uhttpd tweaks (release images; snapshot minimal images may omit uhttpd).
if [[ -f "$MNT/etc/config/uhttpd" ]]; then
	if [[ -f "$MNT/usr/share/ucode/luci/dispatcher.uc" ]] || grep -q "ucode_prefix" "$MNT/etc/config/uhttpd" 2>/dev/null; then
		if grep -q "ucode_prefix" "$MNT/etc/config/uhttpd" 2>/dev/null; then
			sed -i "s|list ucode_prefix.*|list ucode_prefix '/cgi-bin/luci=/usr/share/ucode/luci/dispatcher.uc'|" "$MNT/etc/config/uhttpd"
		else
			sed -i "/config uhttpd 'main'/a\\
	list ucode_prefix '/cgi-bin/luci=/usr/share/ucode/luci/dispatcher.uc'
" "$MNT/etc/config/uhttpd"
		fi
		sed -i "/lua_prefix/d" "$MNT/etc/config/uhttpd"
	fi
	sed -i "s/option rfc1918_filter '1'/option rfc1918_filter '0'/" "$MNT/etc/config/uhttpd"
	sed -i "/listen_https/d; /option cert/d; /option key/d" "$MNT/etc/config/uhttpd"
fi
# defaults section only (24.10+ uses tabs without quotes; older releases use quoted values).
if [[ -f "$MNT/etc/config/firewall" ]]; then
	sed -i "s/option syn_flood '1'/option syn_flood '0'/" "$MNT/etc/config/firewall"
	sed -i '/^config defaults$/,/^$/{
		s/^\(\t*option syn_flood\)[[:space:]]*1$/\1\t0/
		s/^\(\t*option input\)[[:space:]]*REJECT$/\1\tACCEPT/
	}' "$MNT/etc/config/firewall"
fi

# QEMU lab: empty root password for SSH/LuCI (x86 images often already blank).
if [[ -f "$MNT/etc/shadow" ]]; then
	sed -i 's/^root:[^:]*:/root::/' "$MNT/etc/shadow"
fi
if [[ -f "$MNT/etc/config/dropbear" ]]; then
	grep -q "option PasswordAuth" "$MNT/etc/config/dropbear" \
		|| echo "	option PasswordAuth 'on'" >>"$MNT/etc/config/dropbear"
	grep -q "option RootPasswordAuth" "$MNT/etc/config/dropbear" \
		|| echo "	option RootPasswordAuth 'on'" >>"$MNT/etc/config/dropbear"
	sed -i "s/option PasswordAuth 'off'/option PasswordAuth 'on'/" "$MNT/etc/config/dropbear"
	sed -i "s/option RootPasswordAuth 'off'/option RootPasswordAuth 'on'/" "$MNT/etc/config/dropbear"
fi

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
	if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]] \
		&& ! sed -n "/config interface 'lan'/,/^$/p" "$MNT/etc/config/network" | grep -q "option proto 'dhcp'"; then
		echo "error: failed to set network.lan proto=dhcp on $IMG" >&2
		exit 1
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
