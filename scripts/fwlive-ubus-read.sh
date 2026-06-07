#!/usr/bin/env bash
# Read logd via ubus on a running OpenWrt host and print firewall-only JSON rows.
#
# Usage:
#   ./scripts/fwlive-ubus-read.sh
#   ./scripts/fwlive-ubus-read.sh --lines 100
#   OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 ./scripts/fwlive-ubus-read.sh --stats
#
# Requires: ssh access to root@guest, node on the build host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
LINES=50
MODE=filter

while [[ $# -gt 0 ]]; do
	case "$1" in
		--lines) LINES="${2:?}"; shift 2 ;;
		--stats) MODE=stats; shift ;;
		-h|--help)
			echo "usage: $0 [--lines N] [--stats]" >&2
			exit 0
			;;
		*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$PORT")

RAW="$(ssh "${SSH_OPTS[@]}" "root@${HOST}" \
	"ubus call log read '{\"lines\":${LINES},\"stream\":false,\"oneshot\":true}'" 2>/dev/null)" \
	|| { echo "ssh/ubus failed — is the guest up? (OPENWRT_HOST=${HOST} OPENWRT_SSH_PORT=${PORT})" >&2; exit 1; }

NODE="${NODE:-}"
if [[ -z "$NODE" ]]; then
	command -v node >/dev/null 2>&1 && NODE=node || NODE=nodejs
fi
printf '%s' "$RAW" | "$NODE" "${ROOT}/core/fwlive-log.js" "$MODE"
