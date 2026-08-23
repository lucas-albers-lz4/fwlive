#!/usr/bin/env bash
# Reset WAN logging state on a QEMU lab guest (avoids stale disk image state).
#
#   ./scripts/qemu-reset-wan-logging.sh
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-reset-wan-logging.sh
set -euo pipefail

HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")

die() { echo "qemu-reset-wan-logging FAIL: $*" >&2; exit 1; }
ok() { echo "qemu-reset-wan-logging OK: $*"; }

ssh_guest() {
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

ssh_guest 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU first"

if ssh_guest 'test -x /usr/libexec/rpcd/fwlive'; then
	if ! ssh_guest 'ubus call fwlive disable_wan_logging' >/dev/null 2>&1; then
		die "disable_wan_logging failed — baseline preserved at /etc/fwlive/wan-log-baseline"
	fi
	ok "disable_wan_logging (when fwlive installed)"
else
	ok "fwlive not installed — skip ubus disable"
fi

ssh_guest 'rm -f /etc/fwlive/wan-log-baseline'
ok "removed /etc/fwlive/wan-log-baseline (if present)"

ZONE="$(ssh_guest "uci -q show firewall | sed -n \"s/^firewall\\.\\([^.]*\\)\\.name='wan'\$/\\1/p\" | head -1")"
LOG="$(ssh_guest "uci -q get firewall.${ZONE}.log 2>/dev/null || echo '<unset>'")"
if ssh_guest 'test -x /usr/libexec/rpcd/fwlive'; then
	ST="$(ssh_guest 'ubus call fwlive logging_status' 2>/dev/null || true)"
	echo "logging_status: ${ST:-unavailable}"
fi
echo "firewall.${ZONE}.log=${LOG}"
