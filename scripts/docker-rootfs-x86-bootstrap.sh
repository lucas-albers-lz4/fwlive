#!/usr/bin/env bash
# One-time (or idempotent) setup for ghcr.io/openwrt/rootfs:x86-64 in Docker.
# Fixes Docker bridge networking, installs LuCI, starts uhttpd (HTTP only).
set -euo pipefail

CONTAINER="${OWRT_CONTAINER:-owrt-x64-exp}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "error: $*" >&2; exit 1; }

docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container '$CONTAINER' not running — start: ./scripts/run-openwrt-x86-experiment.sh"

IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER")"
GW="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.Gateway}}{{end}}' "$CONTAINER")"
[[ -n "$IP" && -n "$GW" ]] || die "could not read container IP/gateway"

echo "Container $CONTAINER on Docker bridge ${IP} via ${GW}" >&2

docker exec "$CONTAINER" sh -ec "
	i=0
	while [ ! -f /etc/config/network ] && [ \"\$i\" -lt 60 ]; do sleep 2; i=\$((i + 1)); done
	test -f /etc/config/network
	i=0
	while ! uci -q get network.lan >/dev/null 2>&1 && [ \"\$i\" -lt 30 ]; do sleep 2; i=\$((i + 1)); done
	test -n \"\$(uci -q get network.lan 2>/dev/null)\"

	# Match OpenWrt LAN to Docker's bridge address (default 192.168.1.1 breaks port-publish + routing).
	while uci -q delete network.lan.ipaddr; do :; done
	uci set network.lan.proto='static'
	uci add_list network.lan.ipaddr='${IP}/16'
	uci commit network

	# Apply live (avoid network reload timeouts during early firstboot).
	i=0
	while [ ! -d /sys/class/net/br-lan ] && [ \"\$i\" -lt 30 ]; do sleep 1; i=\$((i + 1)); done
	ip addr flush dev br-lan 2>/dev/null || true
	ip addr add '${IP}/16' dev br-lan
	ip link set br-lan up
	ip route replace default via '${GW}' dev br-lan 2>/dev/null || ip route add default via '${GW}' dev br-lan
	ping -c1 -W5 '${GW}' >/dev/null

	# LuCI + web server (SNAPSHOT rootfs is minimal).
	if ! apk info -e luci-mod-admin-full >/dev/null 2>&1; then
		apk update
		apk add luci-base luci-theme-bootstrap luci-mod-admin-full uhttpd
	fi

	[ -x /etc/init.d/uhttpd-docker ] && /etc/init.d/uhttpd-docker disable 2>/dev/null || true
	[ -x /etc/init.d/uhttpd-docker ] && /etc/init.d/uhttpd-docker stop 2>/dev/null || true

	# HTTP only — stock uhttpd init hangs generating TLS certs in containers.
	while uci -q delete uhttpd.main.listen_https; do :; done
	uci set uhttpd.main.rfc1918_filter='0'
	uci set uhttpd.main.ubus_prefix='/ubus'
	uci -q delete uhttpd.main.lua_prefix 2>/dev/null || true
	uci -q delete uhttpd.main.ucode_prefix 2>/dev/null || true
	uci add_list uhttpd.main.ucode_prefix='/cgi-bin/luci=/usr/share/ucode/luci/uhttpd.uc'
	uci commit uhttpd

	killall uhttpd 2>/dev/null || true
	/etc/init.d/uhttpd enable
	/etc/init.d/uhttpd restart
	/etc/init.d/rpcd restart
	sleep 2
"

echo "" >&2
echo "LuCI:  http://127.0.0.1:8080/cgi-bin/luci/" >&2
echo "SSH:   ssh -p 2222 root@127.0.0.1   (empty password unless you set one)" >&2
echo "Docs:  ${ROOT}/docs/openwrt-rootfs-x86-docker.md" >&2
