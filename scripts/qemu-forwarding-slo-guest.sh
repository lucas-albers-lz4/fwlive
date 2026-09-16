#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Configure or clean up the two TAP-backed interfaces used by the forwarding
# SLO lab. The management interface remains untouched.
#
# Usage:
#   ./scripts/qemu-forwarding-slo-guest.sh configure
#   ./scripts/qemu-forwarding-slo-guest.sh check
#   ./scripts/qemu-forwarding-slo-guest.sh cleanup
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
USER="${OPENWRT_USER:-root}"
KNOWN_HOSTS="${FWLIVE_KNOWN_HOSTS:-${ROOT}/lab/qemu-known_hosts}"
LAN_MAC="${FWLIVE_SLO_LAN_MAC:-52:54:00:30:77:01}"
WAN_MAC="${FWLIVE_SLO_WAN_MAC:-52:54:00:30:77:02}"
LAN_IP="${FWLIVE_SLO_LAN_GUEST_IP:-192.0.2.1}"
WAN_IP="${FWLIVE_SLO_WAN_GUEST_IP:-198.51.100.1}"

die() { echo "forwarding-slo-guest: $*" >&2; exit 1; }

case "$LAN_MAC" in
	[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
	*) die "FWLIVE_SLO_LAN_MAC must be a six-octet MAC address" ;;
esac
case "$WAN_MAC" in
	[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
	*) die "FWLIVE_SLO_WAN_MAC must be a six-octet MAC address" ;;
esac
[[ "$LAN_MAC" != "$WAN_MAC" ]] || die "LAN and WAN MAC addresses must differ"

mkdir -p "$(dirname "$KNOWN_HOSTS")"
touch "$KNOWN_HOSTS"
SSH_OPTS=(-o StrictHostKeyChecking="${FWLIVE_STRICT_HOST_KEY_CHECKING:-accept-new}" \
	-o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -p "$PORT")

ACTION="${1:-}"
case "$ACTION" in
	configure|check|cleanup) ;;
	-h|--help|"") sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) die "unknown action: $ACTION" ;;
esac

ssh "${SSH_OPTS[@]}" "${USER}@${HOST}" sh -s -- \
	"$ACTION" "$LAN_MAC" "$WAN_MAC" "$LAN_IP" "$WAN_IP" <<'REMOTE'
set -eu
action=$1
lan_mac=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
wan_mac=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
lan_ip=$4
wan_ip=$5

find_dev() {
	want=$1
	for path in /sys/class/net/*/address; do
		dev=${path%/address}
		dev=${dev##*/}
		mac=$(cat "$path" 2>/dev/null | tr '[:upper:]' '[:lower:]') || continue
		[ "$mac" = "$want" ] && { printf '%s\n' "$dev"; return 0; }
	done
	return 1
}

lan_dev=$(find_dev "$lan_mac") || { echo "LAN TAP MAC not found: $lan_mac" >&2; exit 1; }
wan_dev=$(find_dev "$wan_mac") || { echo "WAN TAP MAC not found: $wan_mac" >&2; exit 1; }
[ "$lan_dev" != "$wan_dev" ] || { echo "LAN/WAN resolved to the same interface" >&2; exit 1; }

remove_rules() {
	chain_rules=$(nft -a list chain inet fw4 forward 2>/dev/null || true)
	printf '%s\n' "$chain_rules" | awk '
		/comment "fwlive-slo-(lan-to-wan|wan-to-lan|log-lan-to-wan|log-wan-to-lan)"/ {
			for (i = 1; i <= NF; i++) if ($i == "handle" && $(i + 1) ~ /^[0-9]+$/) print $(i + 1)
		}' | while read -r handle; do
		nft delete rule inet fw4 forward handle "$handle"
	done
}

case "$action" in
	configure)
		command -v nft >/dev/null 2>&1 || { echo "nft is required on the guest" >&2; exit 1; }
		ip link set "$lan_dev" up
		ip link set "$wan_dev" up
		ip addr add "$lan_ip/24" dev "$lan_dev" 2>/dev/null || true
		ip addr add "$wan_ip/24" dev "$wan_dev" 2>/dev/null || true
		sysctl -w net.ipv4.ip_forward=1 >/dev/null
		remove_rules
		nft insert rule inet fw4 forward iifname "$lan_dev" oifname "$wan_dev" counter accept comment "fwlive-slo-lan-to-wan"
		nft insert rule inet fw4 forward iifname "$wan_dev" oifname "$lan_dev" counter accept comment "fwlive-slo-wan-to-lan"
		nft insert rule inet fw4 forward iifname "$lan_dev" oifname "$wan_dev" limit rate 25/second log prefix "fwlive-slo " counter accept comment "fwlive-slo-log-lan-to-wan"
		nft insert rule inet fw4 forward iifname "$wan_dev" oifname "$lan_dev" limit rate 25/second log prefix "fwlive-slo " counter accept comment "fwlive-slo-log-wan-to-lan"
		echo "guest_configured lan=$lan_dev:$lan_ip wan=$wan_dev:$wan_ip forwarding=1"
		;;
	check)
		ip -4 addr show dev "$lan_dev"
		ip -4 addr show dev "$wan_dev"
		sysctl net.ipv4.ip_forward
		ip -4 addr show dev "$lan_dev" | grep -Fq "inet $lan_ip/24" || {
			echo "LAN address is not configured: $lan_dev:$lan_ip" >&2
			exit 1
		}
		ip -4 addr show dev "$wan_dev" | grep -Fq "inet $wan_ip/24" || {
			echo "WAN address is not configured: $wan_dev:$wan_ip" >&2
			exit 1
		}
		[ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || {
			echo "IPv4 forwarding is disabled" >&2
			exit 1
		}
		nft -a list chain inet fw4 forward | grep -E 'fwlive-slo-(lan-to-wan|wan-to-lan|log-lan-to-wan|log-wan-to-lan)' || {
			echo "fwlive-slo forwarding or logging rules are missing" >&2
			exit 1
		}
		;;
	cleanup)
		command -v nft >/dev/null 2>&1 || { echo "nft is required on the guest" >&2; exit 1; }
		remove_rules
		ip addr del "$lan_ip/24" dev "$lan_dev" 2>/dev/null || true
		ip addr del "$wan_ip/24" dev "$wan_dev" 2>/dev/null || true
		ip link set "$lan_dev" down
		ip link set "$wan_dev" down
		sysctl -w net.ipv4.ip_forward=0 >/dev/null
		echo "guest_cleaned lan=$lan_dev wan=$wan_dev forwarding=0"
		;;
esac
REMOTE
