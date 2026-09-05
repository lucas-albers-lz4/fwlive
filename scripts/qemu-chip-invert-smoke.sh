#!/usr/bin/env bash
# Playwright chip-invert smoke for luci-app-fwlive.
#
# Prereqs: QEMU guest with fwlive installed, host Node + playwright.
#
#   ./scripts/qemu-chip-invert-smoke.sh
#   FWLIVE_URL=http://127.0.0.1:8080 ./scripts/qemu-chip-invert-smoke.sh
#
# Shared-context bundle: ./scripts/qemu-playwright-lab-smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
HTTP_PORT="${OWRT_HOSTFWD_HTTP:-8080}"
FWLIVE_URL="${FWLIVE_URL:-http://${HOST}:${HTTP_PORT}}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")

die() { echo "chip-invert smoke FAIL: $*" >&2; exit 1; }
ok() { echo "chip-invert smoke OK: $*"; }

ssh "${SSH_OPTS[@]}" "root@${HOST}" 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU and install fwlive first"

if ssh "${SSH_OPTS[@]}" "root@${HOST}" 'command -v nft >/dev/null 2>&1'; then
	"${ROOT}/scripts/fwlive-nft-ping-log.sh" add --ssh >/dev/null 2>&1 || true
	ssh "${SSH_OPTS[@]}" "root@${HOST}" 'ping -c 3 -W 1 127.0.0.1 >/dev/null 2>&1' || true
elif ssh "${SSH_OPTS[@]}" "root@${HOST}" 'command -v iptables >/dev/null 2>&1'; then
	"${ROOT}/scripts/fwlive-iptables-ping-log.sh" add --ssh >/dev/null 2>&1 || true
	ssh "${SSH_OPTS[@]}" "root@${HOST}" 'ping -c 3 -W 1 127.0.0.1 >/dev/null 2>&1' || true
fi

NODE="${NODE:-}"
if [[ -z "$NODE" ]]; then
	if command -v node >/dev/null 2>&1; then
		NODE=node
	elif command -v nodejs >/dev/null 2>&1; then
		NODE=nodejs
	else
		die "nodejs required"
	fi
fi

if [[ ! -d "${ROOT}/node_modules/playwright" ]]; then
	die "playwright missing — run: npm install (in repo root)"
fi

echo "== fwlive chip invert smoke (${FWLIVE_URL}) ==" >&2
FWLIVE_URL="$FWLIVE_URL" "$NODE" "${ROOT}/tests/fwlive-chip-invert-smoke.mjs"
ok "live + paused invert"
