#!/usr/bin/env bash
# Wait until the armsr QEMU guest answers SSH (hostfwd) and optionally run a command.
#
# Usage:
#   ./scripts/qemu-wait-guest.sh
#   ./scripts/qemu-wait-guest.sh --cmd 'uname -r'
#   OPENWRT_SSH_PORT=2222 MAX_WAIT=600 ./scripts/qemu-wait-guest.sh
# --cmd is retried until SSH and the remote command both exit 0.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/qemu-lab-net.sh
source "${ROOT}/scripts/lib/qemu-lab-net.sh"

HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
USER="${OPENWRT_USER:-root}"
MAX_WAIT="${MAX_WAIT:-600}"
INTERVAL="${INTERVAL:-15}"
CMD=""
qemu_lab_validate_port OPENWRT_SSH_PORT "$PORT" || exit 1
qemu_lab_validate_int MAX_WAIT "$MAX_WAIT" 1 7200 || exit 1
qemu_lab_validate_int INTERVAL "$INTERVAL" 1 120 || exit 1
SSH_OPTS=(
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o BatchMode=yes
	-o NumberOfPasswordPrompts=0
)

while [[ $# -gt 0 ]]; do
	case "$1" in
		--cmd)
			CMD="${2:?usage: qemu-wait-guest.sh --cmd CMD}"
			shift 2
			;;
		-h | --help)
			sed -n '1,13p' "$0"
			exit 0
			;;
		*)
			echo "unknown arg: $1" >&2
			exit 1
			;;
	esac
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
echo "hint: stop other QEMU, then ./scripts/run-openwrt-x86-qemu.sh or ./scripts/run-openwrt-armsr-armv8-qemu.sh" >&2
exit 1
