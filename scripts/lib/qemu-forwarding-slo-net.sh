#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Host-side network namespace topology for the forwarding-SLO lab.
#
# The topology is deliberately separate from QEMU's management slirp network:
#
#   LAN endpoint namespace ─ LAN bridge ─ TAP ─┐
#                                               │ OpenWrt guest
#   WAN endpoint namespace ─ WAN bridge ─ TAP ─┘
#
# Callers must configure the guest's two TAP-backed interfaces and enable IPv4
# forwarding before traffic is measured. Every resource has the fwlive-slo
# prefix so teardown never targets an unrelated lab interface.

: "${FWLIVE_SLO_LAN_NETNS:=fwlive-slo-lan}"
: "${FWLIVE_SLO_WAN_NETNS:=fwlive-slo-wan}"
: "${FWLIVE_SLO_LAN_BRIDGE:=fwlive-slo-lbr}"
: "${FWLIVE_SLO_WAN_BRIDGE:=fwlive-slo-wbr}"
: "${FWLIVE_SLO_LAN_TAP:=fwlive-slo-ltap}"
: "${FWLIVE_SLO_WAN_TAP:=fwlive-slo-wtap}"
: "${FWLIVE_SLO_LAN_VETH:=fwlive-slo-lv}"
: "${FWLIVE_SLO_WAN_VETH:=fwlive-slo-wv}"
: "${FWLIVE_SLO_LAN_PEER:=fwlive-slo-lpr}"
: "${FWLIVE_SLO_WAN_PEER:=fwlive-slo-wpr}"
: "${FWLIVE_SLO_LAN_GUEST_IP:=192.0.2.1}"
: "${FWLIVE_SLO_LAN_ENDPOINT_IP:=192.0.2.2}"
: "${FWLIVE_SLO_WAN_GUEST_IP:=198.51.100.1}"
: "${FWLIVE_SLO_WAN_ENDPOINT_IP:=198.51.100.2}"
: "${FWLIVE_SLO_LAN_MAC:=52:54:00:30:77:01}"
: "${FWLIVE_SLO_WAN_MAC:=52:54:00:30:77:02}"
: "${FWLIVE_SLO_PREFIX:=fwlive-slo-}"
: "${FWLIVE_SLO_QEMU_NET_MODEL:=virtio-net-pci}"

fwlive_slo_net_die() {
	echo "forwarding-slo-net: $*" >&2
	exit 1
}

fwlive_slo_net_require_root() {
	[[ "$(id -u)" -eq 0 ]] || fwlive_slo_net_die "run as root (network namespaces and TAPs require CAP_NET_ADMIN)"
}

fwlive_slo_net_require_tools() {
	command -v ip >/dev/null 2>&1 || fwlive_slo_net_die "missing required tool: ip"
}

fwlive_slo_net_validate_name() {
	local name="$1" suffix
	case "$name" in
		"${FWLIVE_SLO_PREFIX}"*) ;;
		*) fwlive_slo_net_die "resource name is outside the owned prefix: $name" ;;
	esac
	suffix="${name#"$FWLIVE_SLO_PREFIX"}"
	[[ -n "$suffix" ]] || fwlive_slo_net_die "resource name must include a suffix: $name"
	case "$suffix" in
		*[!A-Za-z0-9.-]*) fwlive_slo_net_die "resource name contains unsupported characters: $name" ;;
	esac
	[[ ${#name} -le 15 ]] || fwlive_slo_net_die "interface name is too long for Linux: $name"
}

fwlive_slo_net_validate_names() {
	local name seen=' '
	for name in \
		"$FWLIVE_SLO_LAN_NETNS" "$FWLIVE_SLO_WAN_NETNS" \
		"$FWLIVE_SLO_LAN_BRIDGE" "$FWLIVE_SLO_WAN_BRIDGE" \
		"$FWLIVE_SLO_LAN_TAP" "$FWLIVE_SLO_WAN_TAP" \
		"$FWLIVE_SLO_LAN_VETH" "$FWLIVE_SLO_WAN_VETH" \
		"$FWLIVE_SLO_LAN_PEER" "$FWLIVE_SLO_WAN_PEER"; do
		fwlive_slo_net_validate_name "$name"
		case "$seen" in
			*" $name "*) fwlive_slo_net_die "duplicate resource name: $name" ;;
		esac
		seen="${seen}${name} "
	done
}

fwlive_slo_net_link_exists() {
	ip link show dev "$1" >/dev/null 2>&1
}

fwlive_slo_net_ns_exists() {
	ip netns list | awk '{print $1}' | grep -Fxq "$1"
}

fwlive_slo_net_expect_absent() {
	local name="$1"
	if fwlive_slo_net_link_exists "$name" || fwlive_slo_net_ns_exists "$name"; then
		fwlive_slo_net_die "owned resource already exists: $name (run teardown or choose a new prefix)"
	fi
}

fwlive_slo_net_rollback() {
	trap - ERR EXIT
	local ns link
	for ns in "$FWLIVE_SLO_LAN_NETNS" "$FWLIVE_SLO_WAN_NETNS"; do
		if fwlive_slo_net_ns_exists "$ns"; then
			ip netns del "$ns" 2>/dev/null || true
		fi
	done
	for link in \
		"$FWLIVE_SLO_LAN_TAP" "$FWLIVE_SLO_WAN_TAP" \
		"$FWLIVE_SLO_LAN_VETH" "$FWLIVE_SLO_WAN_VETH" \
		"$FWLIVE_SLO_LAN_BRIDGE" "$FWLIVE_SLO_WAN_BRIDGE"; do
		if fwlive_slo_net_link_exists "$link"; then
			ip link del "$link" 2>/dev/null || true
		fi
	done
}

fwlive_slo_net_setup() {
	local qemu_user="${1:-${SUDO_USER:-${USER:-}}}"
	fwlive_slo_net_require_root
	fwlive_slo_net_require_tools
	fwlive_slo_net_validate_names
	[[ -n "$qemu_user" ]] || fwlive_slo_net_die "cannot determine the QEMU TAP owner; set SUDO_USER or pass one"
	for name in \
		"$FWLIVE_SLO_LAN_NETNS" "$FWLIVE_SLO_WAN_NETNS" \
		"$FWLIVE_SLO_LAN_BRIDGE" "$FWLIVE_SLO_WAN_BRIDGE" \
		"$FWLIVE_SLO_LAN_TAP" "$FWLIVE_SLO_WAN_TAP" \
		"$FWLIVE_SLO_LAN_VETH" "$FWLIVE_SLO_WAN_VETH" \
		"$FWLIVE_SLO_LAN_PEER" "$FWLIVE_SLO_WAN_PEER"; do
		fwlive_slo_net_expect_absent "$name"
	done
	trap fwlive_slo_net_rollback ERR EXIT

	ip netns add "$FWLIVE_SLO_LAN_NETNS"
	ip netns add "$FWLIVE_SLO_WAN_NETNS"
	ip link add name "$FWLIVE_SLO_LAN_BRIDGE" type bridge
	ip link add name "$FWLIVE_SLO_WAN_BRIDGE" type bridge
	ip link set dev "$FWLIVE_SLO_LAN_BRIDGE" up
	ip link set dev "$FWLIVE_SLO_WAN_BRIDGE" up
	ip tuntap add dev "$FWLIVE_SLO_LAN_TAP" mode tap user "$qemu_user"
	ip tuntap add dev "$FWLIVE_SLO_WAN_TAP" mode tap user "$qemu_user"
	ip link set dev "$FWLIVE_SLO_LAN_TAP" master "$FWLIVE_SLO_LAN_BRIDGE"
	ip link set dev "$FWLIVE_SLO_WAN_TAP" master "$FWLIVE_SLO_WAN_BRIDGE"
	ip link set dev "$FWLIVE_SLO_LAN_TAP" up
	ip link set dev "$FWLIVE_SLO_WAN_TAP" up

	ip link add "$FWLIVE_SLO_LAN_VETH" type veth peer name "$FWLIVE_SLO_LAN_PEER"
	ip link add "$FWLIVE_SLO_WAN_VETH" type veth peer name "$FWLIVE_SLO_WAN_PEER"
	ip link set dev "$FWLIVE_SLO_LAN_VETH" master "$FWLIVE_SLO_LAN_BRIDGE"
	ip link set dev "$FWLIVE_SLO_LAN_VETH" up
	ip link set dev "$FWLIVE_SLO_LAN_PEER" netns "$FWLIVE_SLO_LAN_NETNS"
	ip link set dev "$FWLIVE_SLO_WAN_VETH" master "$FWLIVE_SLO_WAN_BRIDGE"
	ip link set dev "$FWLIVE_SLO_WAN_VETH" up
	ip link set dev "$FWLIVE_SLO_WAN_PEER" netns "$FWLIVE_SLO_WAN_NETNS"

	ip netns exec "$FWLIVE_SLO_LAN_NETNS" ip link set lo up
	ip netns exec "$FWLIVE_SLO_LAN_NETNS" ip link set "$FWLIVE_SLO_LAN_PEER" name endpoint0
	ip netns exec "$FWLIVE_SLO_LAN_NETNS" ip link set endpoint0 up
	ip netns exec "$FWLIVE_SLO_LAN_NETNS" ip addr add "${FWLIVE_SLO_LAN_ENDPOINT_IP}/24" dev endpoint0
	ip netns exec "$FWLIVE_SLO_LAN_NETNS" ip route add "$FWLIVE_SLO_WAN_ENDPOINT_IP/32" via "$FWLIVE_SLO_LAN_GUEST_IP"

	ip netns exec "$FWLIVE_SLO_WAN_NETNS" ip link set lo up
	ip netns exec "$FWLIVE_SLO_WAN_NETNS" ip link set "$FWLIVE_SLO_WAN_PEER" name endpoint0
	ip netns exec "$FWLIVE_SLO_WAN_NETNS" ip link set endpoint0 up
	ip netns exec "$FWLIVE_SLO_WAN_NETNS" ip addr add "${FWLIVE_SLO_WAN_ENDPOINT_IP}/24" dev endpoint0
	ip netns exec "$FWLIVE_SLO_WAN_NETNS" ip route add "$FWLIVE_SLO_LAN_ENDPOINT_IP/32" via "$FWLIVE_SLO_WAN_GUEST_IP"
	# Moving a veth peer can reset the host-side carrier; restore both links
	# after namespace configuration so the TAP bridges are immediately usable.
	ip link set dev "$FWLIVE_SLO_LAN_VETH" up
	ip link set dev "$FWLIVE_SLO_WAN_VETH" up
	trap - ERR EXIT

	echo "forwarding-slo-net: topology ready"
	fwlive_slo_net_status
}

fwlive_slo_net_teardown() {
	fwlive_slo_net_require_root
	fwlive_slo_net_require_tools
	fwlive_slo_net_validate_names
	local ns link
	for ns in "$FWLIVE_SLO_LAN_NETNS" "$FWLIVE_SLO_WAN_NETNS"; do
		if fwlive_slo_net_ns_exists "$ns"; then
			ip netns del "$ns"
		fi
	done
	for link in \
		"$FWLIVE_SLO_LAN_TAP" "$FWLIVE_SLO_WAN_TAP" \
		"$FWLIVE_SLO_LAN_VETH" "$FWLIVE_SLO_WAN_VETH" \
		"$FWLIVE_SLO_LAN_BRIDGE" "$FWLIVE_SLO_WAN_BRIDGE"; do
		if fwlive_slo_net_link_exists "$link"; then
			ip link del "$link"
		fi
	done
	echo "forwarding-slo-net: owned resources removed"
}

fwlive_slo_net_status() {
	local ns link
	for ns in "$FWLIVE_SLO_LAN_NETNS" "$FWLIVE_SLO_WAN_NETNS"; do
		if fwlive_slo_net_ns_exists "$ns"; then
			echo "netns=$ns present"
		else
			echo "netns=$ns absent"
		fi
	done
	for link in \
		"$FWLIVE_SLO_LAN_TAP" "$FWLIVE_SLO_WAN_TAP" \
		"$FWLIVE_SLO_LAN_BRIDGE" "$FWLIVE_SLO_WAN_BRIDGE"; do
		if fwlive_slo_net_link_exists "$link"; then
			echo "link=$link present"
		else
			echo "link=$link absent"
		fi
	done
}

fwlive_slo_net_qemu_args() {
	case "$FWLIVE_SLO_QEMU_NET_MODEL" in
		virtio-net-pci|e1000) ;;
		*) echo "forwarding-slo-net: unsupported QEMU test NIC model: $FWLIVE_SLO_QEMU_NET_MODEL" >&2; return 1 ;;
	esac
	cat <<EOF
	-netdev tap,id=fwlive-slo-lan,ifname=${FWLIVE_SLO_LAN_TAP},script=no,downscript=no
-device ${FWLIVE_SLO_QEMU_NET_MODEL},netdev=fwlive-slo-lan,mac=${FWLIVE_SLO_LAN_MAC}
	-netdev tap,id=fwlive-slo-wan,ifname=${FWLIVE_SLO_WAN_TAP},script=no,downscript=no
-device ${FWLIVE_SLO_QEMU_NET_MODEL},netdev=fwlive-slo-wan,mac=${FWLIVE_SLO_WAN_MAC}
EOF
}
