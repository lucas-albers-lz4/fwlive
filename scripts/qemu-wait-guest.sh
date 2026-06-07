#!/usr/bin/env bash
# Wait until the armsr QEMU guest answers SSH (hostfwd) and optionally run a command.
#
# Usage:
#   ./scripts/qemu-wait-guest.sh
#   ./scripts/qemu-wait-guest.sh --cmd 'uname -r'
#   OPENWRT_SSH_PORT=2222 MAX_WAIT=600 ./scripts/qemu-wait-guest.sh
set -euo pipefail

HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
USER="${OPENWRT_USER:-root}"
MAX_WAIT="${MAX_WAIT:-600}"
INTERVAL="${INTERVAL:-15}"
CMD=""
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

while [[ $# -gt 0 ]]; do
	case "$1" in
		--cmd) shift; CMD="${1:-}" ;;
		-h|--help)
			sed -n '1,12p' "$0"
			exit 0
			;;
		*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
	shift
done

deadline=$((SECONDS + MAX_WAIT))
attempt=0

while [[ $SECONDS -lt $deadline ]]; do
	attempt=$((attempt + 1))
	if out="$(ssh -p "$PORT" "${SSH_OPTS[@]}" -o ConnectTimeout=20 "${USER}@${HOST}" "${CMD:-echo READY}" 2>&1)"; then
		echo "guest ready after ~${attempt} attempts (${SECONDS}s)"
		[[ -n "$out" ]] && printf '%s\n' "$out"
		exit 0
	fi
	echo "attempt ${attempt}: ${out:-ssh failed}"
	sleep "$INTERVAL"
done

echo "error: guest not reachable on ${HOST}:${PORT} within ${MAX_WAIT}s" >&2
echo "hint: ./scripts/run-openwrt-armsr-armv8-qemu.sh --stop && ./scripts/run-openwrt-armsr-armv8-qemu.sh" >&2
exit 1
