#!/usr/bin/env bash
# Fetch fwlive rule hint → label map from ubus (OpenWrt guest).
#
# Usage:
#   ./scripts/fwlive-rules-ubus.sh
#   OPENWRT_HOST=127.0.0.1 OPENWRT_SSH_PORT=2222 ./scripts/fwlive-rules-ubus.sh
set -euo pipefail

HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$PORT")

ssh "${SSH_OPTS[@]}" "root@${HOST}" \
	"ubus call fwlive rules" 2>/dev/null \
	|| { echo "ubus fwlive rules failed — install rpcd plugin and ACL (./scripts/qemu-install-fwlive.sh)" >&2; exit 1; }
