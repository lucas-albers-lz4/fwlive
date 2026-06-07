#!/usr/bin/env bash
# Add or remove a temporary nft rule that logs inbound ICMP echo-request (ping).
#
# Usage (on the OpenWrt guest as root, or via SSH):
#   ./scripts/fwlive-nft-ping-log.sh add
#   ./scripts/fwlive-nft-ping-log.sh remove
#   ./scripts/fwlive-nft-ping-log.sh status
#
# From build host into Docker experiment:
#   ./scripts/fwlive-nft-ping-log.sh add --ssh
#   ping -c 3 $(./scripts/fwlive-nft-ping-log.sh guest-ip)
#   ./scripts/fwlive-ubus-read.sh --lines 20
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="${1:-add}"
SSH_MODE=0
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
CONTAINER="${OWRT_CONTAINER:-owrt-x64-exp}"

shift || true
while [[ $# -gt 0 ]]; do
	case "$1" in
		--ssh) SSH_MODE=1; shift ;;
		*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done

run_guest() {
	local script="$1"
	if [[ "$SSH_MODE" -eq 1 ]]; then
		ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$PORT" "root@${HOST}" "$script"
	elif docker inspect "$CONTAINER" >/dev/null 2>&1; then
		docker exec "$CONTAINER" sh -c "$script"
	else
		echo "Run on guest as root, or use --ssh or a running ${CONTAINER} container." >&2
		exit 1
	fi
}

guest_ip_script() {
	cat <<'EOS'
ip -4 addr show br-lan 2>/dev/null | awk '/inet / { print $2; exit }' | cut -d/ -f1
EOS
}

add_rules() {
	run_guest "$(cat <<'EOS'
set -e
# Insert at top of input — appended rules never see br-lan traffic (input_lan jump).
if nft list chain inet fw4 input | grep -q 'fwlive-ping'; then
	echo "fwlive-ping rule already present in inet fw4 input"
else
	nft insert rule inet fw4 input ip protocol icmp icmp type echo-request log prefix "fwlive-ping " accept
	echo "added: inet fw4 input (IPv4 ping log)"
fi
if nft list chain inet fw4 input | grep -q 'fwlive-ping6'; then
	echo "fwlive-ping6 rule already present"
else
	nft insert rule inet fw4 input ip6 nexthdr ipv6-icmpv6 icmpv6 type echo-request log prefix "fwlive-ping6 " accept 2>/dev/null && \
		echo "added: inet fw4 input (IPv6 ping log)" || \
		echo "skip: IPv6 ping rule (no icmpv6 match on this image)"
fi
EOS
)"
}

remove_rules() {
	run_guest "$(cat <<'EOS'
set -e
for pat in 'fwlive-ping ' 'fwlive-ping6 '; do
	while nft -a list chain inet fw4 input 2>/dev/null | grep "prefix \"${pat%\ }\"" | grep -o 'handle [0-9]*' | awk '{print $2}' | head -1 | grep -q .; do
		h=$(nft -a list chain inet fw4 input | grep "prefix \"${pat%\ }\"" | grep -o 'handle [0-9]*' | awk '{print $2}' | head -1)
		nft delete rule inet fw4 input handle "$h"
		echo "deleted handle $h (${pat})"
	done
done
EOS
)"
}

status_rules() {
	run_guest "nft -a list chain inet fw4 input | grep -E 'fwlive-ping|chain input' || true"
}

case "$CMD" in
	add) add_rules ;;
	remove|rm|del) remove_rules ;;
	status) status_rules ;;
	guest-ip)
		run_guest "$(guest_ip_script)"
		;;
	*)
		echo "usage: $0 {add|remove|status|guest-ip} [--ssh]" >&2
		exit 1
		;;
esac
