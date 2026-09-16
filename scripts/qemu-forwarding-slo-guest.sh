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

valid_ipv4() {
	local value="$1" octet
	[[ "$value" =~ ^[0-9]+([.][0-9]+){3}$ ]] || return 1
	IFS=. read -r -a octets <<< "$value"
	for octet in "${octets[@]}"; do
		(( octet <= 255 )) || return 1
	done
}

case "$LAN_MAC" in
	[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
	*) die "FWLIVE_SLO_LAN_MAC must be a six-octet MAC address" ;;
esac
case "$WAN_MAC" in
	[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
	*) die "FWLIVE_SLO_WAN_MAC must be a six-octet MAC address" ;;
esac
[[ "$LAN_MAC" != "$WAN_MAC" ]] || die "LAN and WAN MAC addresses must differ"
valid_ipv4 "$LAN_IP" || die "FWLIVE_SLO_LAN_GUEST_IP must be a valid IPv4 address"
valid_ipv4 "$WAN_IP" || die "FWLIVE_SLO_WAN_GUEST_IP must be a valid IPv4 address"

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
state_file=/var/run/fwlive-slo-guest.state
rollback_enabled=0

state_get() {
	key=$1
	sed -n "s/^${key}=//p" "$state_file"
}

link_is_up() {
	flags=$(cat "/sys/class/net/$1/flags") || return 1
	case "$flags" in
		0x*) flags=$((flags)) ;;
		*[!0-9]*) return 1 ;;
	esac
	[ $((flags & 1)) -ne 0 ] && echo 1 || echo 0
}

find_dev() {
	want=$1
	count=0
	match=
	for path in /sys/class/net/*/address; do
		dev=${path%/address}
		dev=${dev##*/}
		mac=$(cat "$path" 2>/dev/null | tr '[:upper:]' '[:lower:]') || continue
		if [ "$mac" = "$want" ]; then
			count=$((count + 1))
			match=$dev
		fi
	done
	[ "$count" -eq 1 ] || {
		echo "MAC must resolve to exactly one interface: $want (matches=$count)" >&2
		return 1
	}
	printf '%s\n' "$match"
}

lan_dev=$(find_dev "$lan_mac") || { echo "LAN TAP MAC not found: $lan_mac" >&2; exit 1; }
wan_dev=$(find_dev "$wan_mac") || { echo "WAN TAP MAC not found: $wan_mac" >&2; exit 1; }
[ "$lan_dev" != "$wan_dev" ] || { echo "LAN/WAN resolved to the same interface" >&2; exit 1; }

remove_rules() {
	chain_rules=$(nft -a list chain inet fw4 forward 2>/dev/null) || return 1
	handles=$(printf '%s\n' "$chain_rules" | awk '
		/comment "fwlive-slo-(lan-to-wan|wan-to-lan|log-lan-to-wan|log-wan-to-lan)"/ {
			for (i = 1; i <= NF; i++) if ($i == "handle" && $(i + 1) ~ /^[0-9]+$/) print $(i + 1)
		}')
	failed=0
	for handle in $handles; do
		nft delete rule inet fw4 forward handle "$handle" || failed=1
	done
	chain_rules=$(nft -a list chain inet fw4 forward 2>/dev/null) || return 1
	if printf '%s\n' "$chain_rules" | grep -Eq 'comment "fwlive-slo-(lan-to-wan|wan-to-lan|log-lan-to-wan|log-wan-to-lan)"'; then
		echo "fwlive-slo rules remain after cleanup" >&2
		return 1
	fi
	[ "$failed" -eq 0 ]
}

restore_saved_state() {
	saved_lan_dev=$(state_get lan_dev)
	saved_wan_dev=$(state_get wan_dev)
	[ "$saved_lan_dev" = "$lan_dev" ] || { echo "LAN interface changed since configure" >&2; return 1; }
	[ "$saved_wan_dev" = "$wan_dev" ] || { echo "WAN interface changed since configure" >&2; return 1; }
	if [ "$(state_get lan_added)" = 1 ]; then
		ip addr del "$(state_get lan_ip)/24" dev "$lan_dev" 2>/dev/null || true
	fi
	if [ "$(state_get wan_added)" = 1 ]; then
		ip addr del "$(state_get wan_ip)/24" dev "$wan_dev" 2>/dev/null || true
	fi
	sysctl -w "net.ipv4.ip_forward=$(state_get ip_forward)" >/dev/null
	if [ "$(state_get lan_up)" = 1 ]; then ip link set "$lan_dev" up; else ip link set "$lan_dev" down; fi
	if [ "$(state_get wan_up)" = 1 ]; then ip link set "$wan_dev" up; else ip link set "$wan_dev" down; fi
}

rollback() {
	[ "$rollback_enabled" = 1 ] || return 0
	remove_rules || true
	restore_saved_state || true
	rm -f "$state_file"
}
trap rollback EXIT

case "$action" in
	configure)
		command -v nft >/dev/null 2>&1 || { echo "nft is required on the guest" >&2; exit 1; }
		[ ! -e "$state_file" ] || { echo "existing forwarding-SLO state; run cleanup first" >&2; exit 1; }
		lan_up=$(link_is_up "$lan_dev") || { echo "cannot read LAN link state" >&2; exit 1; }
		wan_up=$(link_is_up "$wan_dev") || { echo "cannot read WAN link state" >&2; exit 1; }
		ip_forward=$(cat /proc/sys/net/ipv4/ip_forward)
		case "$ip_forward" in 0|1) ;; *) echo "invalid IPv4 forwarding state" >&2; exit 1 ;; esac
		lan_added=0
		wan_added=0
		ip -4 addr show dev "$lan_dev" | grep -Fq "inet $lan_ip/24" || lan_added=1
		ip -4 addr show dev "$wan_dev" | grep -Fq "inet $wan_ip/24" || wan_added=1
		umask 077
		{
			printf 'lan_dev=%s\n' "$lan_dev"
			printf 'wan_dev=%s\n' "$wan_dev"
			printf 'lan_ip=%s\n' "$lan_ip"
			printf 'wan_ip=%s\n' "$wan_ip"
			printf 'lan_added=%s\n' "$lan_added"
			printf 'wan_added=%s\n' "$wan_added"
			printf 'lan_up=%s\n' "$lan_up"
			printf 'wan_up=%s\n' "$wan_up"
			printf 'ip_forward=%s\n' "$ip_forward"
		} > "$state_file"
		chmod 600 "$state_file"
		rollback_enabled=1
		ip link set "$lan_dev" up
		ip link set "$wan_dev" up
		[ "$lan_added" = 0 ] || ip addr add "$lan_ip/24" dev "$lan_dev"
		[ "$wan_added" = 0 ] || ip addr add "$wan_ip/24" dev "$wan_dev"
		sysctl -w net.ipv4.ip_forward=1 >/dev/null
		remove_rules
		nft insert rule inet fw4 forward iifname "$lan_dev" oifname "$wan_dev" counter accept comment "fwlive-slo-lan-to-wan"
		nft insert rule inet fw4 forward iifname "$wan_dev" oifname "$lan_dev" counter accept comment "fwlive-slo-wan-to-lan"
		nft insert rule inet fw4 forward iifname "$lan_dev" oifname "$wan_dev" limit rate 25/second log prefix "fwlive-slo " counter accept comment "fwlive-slo-log-lan-to-wan"
		nft insert rule inet fw4 forward iifname "$wan_dev" oifname "$lan_dev" limit rate 25/second log prefix "fwlive-slo " counter accept comment "fwlive-slo-log-wan-to-lan"
		rollback_enabled=0
		echo "guest_configured lan=$lan_dev:$lan_ip wan=$wan_dev:$wan_ip forwarding=1"
		;;
	check)
		[ -s "$state_file" ] || { echo "forwarding-SLO state is missing; configure first" >&2; exit 1; }
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
		chain_rules=$(nft -a list chain inet fw4 forward)
		for rule in \
			"fwlive-slo-lan-to-wan|$lan_dev|$wan_dev|0" \
			"fwlive-slo-wan-to-lan|$wan_dev|$lan_dev|0" \
			"fwlive-slo-log-lan-to-wan|$lan_dev|$wan_dev|1" \
			"fwlive-slo-log-wan-to-lan|$wan_dev|$lan_dev|1"; do
			IFS='|' read -r comment iif oif logging <<EOF
$rule
EOF
			printf '%s\n' "$chain_rules" | awk -v comment="$comment" -v iif="$iif" -v oif="$oif" -v logging="$logging" '
				index($0, "comment \"" comment "\"") &&
				index($0, "iifname \"" iif "\"") &&
				index($0, "oifname \"" oif "\"") &&
				index($0, "counter") && index($0, "accept") &&
				(!logging || (index($0, "limit rate 25/second") && index($0, "log prefix \"fwlive-slo\""))) { found=1 }
				END { exit !found }' || { echo "required rule is missing or incorrect: $comment" >&2; exit 1; }
		done
		;;
	cleanup)
		command -v nft >/dev/null 2>&1 || { echo "nft is required on the guest" >&2; exit 1; }
		[ -s "$state_file" ] || { echo "forwarding-SLO state is missing; refusing cleanup" >&2; exit 1; }
		rollback_enabled=0
		remove_rules
		restore_saved_state
		rm -f "$state_file"
		echo "guest_cleaned lan=$lan_dev wan=$wan_dev forwarding=$(cat /proc/sys/net/ipv4/ip_forward)"
		;;
esac
REMOTE
