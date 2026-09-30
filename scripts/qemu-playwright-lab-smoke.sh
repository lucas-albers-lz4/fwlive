#!/usr/bin/env bash
# Consolidated lab Playwright smokes (Wave C2 / #240): one Chromium context.
#
# Prereqs: QEMU guest with fwlive installed, host Node + playwright.
# Not on the PR CI path.
#
#   ./scripts/qemu-playwright-lab-smoke.sh
#   FWLIVE_URL=http://127.0.0.1:8080 ./scripts/qemu-playwright-lab-smoke.sh
#
# Individuals remain callable:
#   ./scripts/qemu-chip-invert-smoke.sh
#   ./scripts/qemu-proto-ui-smoke.sh
#   ./scripts/qemu-ui-reliability-smoke.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
HTTP_PORT="${OWRT_HOSTFWD_HTTP:-8080}"
FWLIVE_URL="${FWLIVE_URL:-http://${HOST}:${HTTP_PORT}}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")

die() { echo "playwright-lab smoke FAIL: $*" >&2; exit 1; }
ok() { echo "playwright-lab smoke OK: $*"; }

ssh "${SSH_OPTS[@]}" "root@${HOST}" 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU and install fwlive first"

# Seed a few log rows when possible (chip-invert + reliability need a table).
if ssh "${SSH_OPTS[@]}" "root@${HOST}" 'command -v nft >/dev/null 2>&1'; then
	"${ROOT}/scripts/fwlive-nft-ping-log.sh" add --ssh >/dev/null 2>&1 || true
	ssh "${SSH_OPTS[@]}" "root@${HOST}" 'ping -c 3 -W 1 127.0.0.1 >/dev/null 2>&1' || true
elif ssh "${SSH_OPTS[@]}" "root@${HOST}" 'command -v iptables >/dev/null 2>&1'; then
	"${ROOT}/scripts/fwlive-iptables-ping-log.sh" add --ssh >/dev/null 2>&1 || true
	ssh "${SSH_OPTS[@]}" "root@${HOST}" 'ping -c 3 -W 1 127.0.0.1 >/dev/null 2>&1' || true
fi

# Ping traffic alone produces pass rows. Seed both actions so selecting Pass
# changes the visible rows even when keyed rendering reuses unchanged rows.
# These are synthetic parser fixtures, not evidence of real dropped traffic.
ssh "${SSH_OPTS[@]}" "root@${HOST}" '
	set -e
	logger -t kernel "fw4: ACCEPT IN=wan OUT= SRC=192.0.2.10 DST=198.51.100.10 PROTO=TCP SPT=12345 DPT=443"
	logger -t kernel "fw4: DROP IN=wan OUT= SRC=192.0.2.11 DST=198.51.100.11 PROTO=TCP SPT=12346 DPT=443"
' || die "could not seed synthetic pass/drop rows"

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

echo "== fwlive lab Playwright bundle (${FWLIVE_URL}) ==" >&2
FWLIVE_URL="$FWLIVE_URL" "$NODE" "${ROOT}/tests/fwlive-lab-playwright-bundle.mjs"
ok "chip-invert + proto-ui + ui-reliability (one context)"
