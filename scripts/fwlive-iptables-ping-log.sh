#!/usr/bin/env bash
# Add or remove temporary iptables rules that log inbound ICMP echo-request (ping).
# Best-effort lab helper for iptables/fw3 backends (issue #7).
#
# Usage (on the OpenWrt guest as root, or via SSH):
#   ./scripts/fwlive-iptables-ping-log.sh add
#   ./scripts/fwlive-iptables-ping-log.sh remove
#   ./scripts/fwlive-iptables-ping-log.sh status
#
# From build host into QEMU lab:
#   ./scripts/fwlive-iptables-ping-log.sh add --ssh
#   ping -c 3 $(./scripts/fwlive-iptables-ping-log.sh guest-ip)
#   ./scripts/fwlive-ubus-read.sh --lines 20
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMD="${1:-add}"
SSH_MODE=0
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
CONTAINER="${OWRT_CONTAINER:-owrt-x64-exp}"
LOG_PREFIX='fwlive-ping: '

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
	run_guest "$(cat <<EOS
set -e
command -v iptables >/dev/null 2>&1 || { echo "iptables not found" >&2; exit 1; }
if iptables -C INPUT -p icmp --icmp-type echo-request -j LOG --log-prefix "${LOG_PREFIX}" 2>/dev/null; then
	echo "fwlive-ping LOG rule already present in INPUT"
else
	iptables -I INPUT -p icmp --icmp-type echo-request -m comment --comment fwlive-ping \\
		-j LOG --log-prefix "${LOG_PREFIX}"
	echo "added: INPUT icmp LOG (${LOG_PREFIX})"
fi
if iptables -C INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null; then
	echo "fwlive-ping ACCEPT rule already present"
else
	iptables -I INPUT -p icmp --icmp-type echo-request -j ACCEPT
	echo "added: INPUT icmp ACCEPT"
fi
EOS
)"
}

remove_rules() {
	run_guest "$(cat <<EOS
set -e
command -v iptables >/dev/null 2>&1 || exit 0
while iptables -C INPUT -p icmp --icmp-type echo-request -j LOG --log-prefix "${LOG_PREFIX}" 2>/dev/null; do
	iptables -D INPUT -p icmp --icmp-type echo-request -j LOG --log-prefix "${LOG_PREFIX}"
	echo "removed LOG rule"
done
while iptables -C INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null; do
	iptables -D INPUT -p icmp --icmp-type echo-request -j ACCEPT
	echo "removed ACCEPT rule"
done
EOS
)"
}

status_rules() {
	run_guest "iptables -L INPUT -n -v 2>/dev/null | grep -E 'fwlive-ping|Chain INPUT' || true"
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
