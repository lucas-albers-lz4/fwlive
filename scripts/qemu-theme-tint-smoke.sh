#!/usr/bin/env bash
# Lab overlay smoke: bootstrap + Material LuCI themes, assert visible Row tint.
# Not published-feed purity — installs theme packages on a running QEMU guest.
#
# Prereqs:
#   - QEMU guest up with luci-app-fwlive installed
#   - Host: node + playwright (same as tests/fwlive-chip-invert-smoke.mjs)
#
# Usage:
#   ./scripts/qemu-theme-tint-smoke.sh
#   OPENWRT_SSH_PORT=2222 FWLIVE_URL=http://127.0.0.1:8080 ./scripts/qemu-theme-tint-smoke.sh
#
# See docs/developer/environment.md (Theme tint matrix).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
HTTP_PORT="${OWRT_HOSTFWD_HTTP:-8080}"
FWLIVE_URL="${FWLIVE_URL:-http://${HOST}:${HTTP_PORT}}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")
NODE="${NODE:-}"
RESTORE_THEME=""

die() { echo "theme-tint smoke FAIL: $*" >&2; exit 1; }
ok() { echo "theme-tint smoke OK: $*"; }

ssh_guest() {
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

if [[ -z "$NODE" ]]; then
	if command -v node >/dev/null 2>&1; then
		NODE=node
	elif command -v nodejs >/dev/null 2>&1; then
		NODE=nodejs
	else
		die "nodejs required for theme tint Playwright smoke"
	fi
fi

echo "== fwlive theme tint smoke (root@${HOST}:${PORT}) ==" >&2

ssh_guest 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU and install fwlive first"

# Hardened CSS must be present on the guest (Phase 1).
ssh_guest 'grep -q -- "--fwlive-pass-color" /www/luci-static/resources/view/status/fwlive.js' \
	|| die "guest fwlive.js missing --fwlive-pass-color (rebuild/reinstall package)"
ssh_guest 'grep -q -- "var(--success-color," /www/luci-static/resources/view/status/fwlive.js' \
	|| die "guest fwlive.js missing Material --success-color chain"
ssh_guest 'grep -q "rgba(70, 165, 70" /www/luci-static/resources/view/status/fwlive.js' \
	|| die "guest fwlive.js missing rgba base tint"
ok "guest CSS has tint resilience tokens"

# Seed firewall log rows when possible (same helpers as qemu-smoke-fwlive.sh).
if ssh_guest 'command -v nft >/dev/null 2>&1'; then
	"${ROOT}/scripts/fwlive-nft-ping-log.sh" add --ssh >/dev/null 2>&1 || true
	ssh_guest 'ping -c 3 -W 1 127.0.0.1 >/dev/null 2>&1' || true
elif ssh_guest 'command -v iptables >/dev/null 2>&1'; then
	"${ROOT}/scripts/fwlive-iptables-ping-log.sh" add --ssh >/dev/null 2>&1 || true
	ssh_guest 'ping -c 3 -W 1 127.0.0.1 >/dev/null 2>&1' || true
fi
sleep 1

pkg_install() {
	local pkg="$1"
	if ssh_guest 'command -v apk >/dev/null 2>&1'; then
		ssh_guest "apk add '${pkg}'" || die "apk add ${pkg} failed"
	elif ssh_guest 'command -v opkg >/dev/null 2>&1'; then
		ssh_guest 'opkg update' >/dev/null 2>&1 || true
		ssh_guest "opkg install '${pkg}'" || die "opkg install ${pkg} failed"
	else
		die "neither opkg nor apk on guest"
	fi
}

ensure_theme_pkg() {
	local pkg="$1"
	local path_hint="$2"
	if ssh_guest "test -d '${path_hint}'"; then
		ok "theme present: ${pkg}"
		return 0
	fi
	echo "→ installing ${pkg} (lab overlay)" >&2
	pkg_install "$pkg"
	ssh_guest "test -d '${path_hint}'" || die "${pkg} installed but ${path_hint} missing"
	ok "installed ${pkg}"
}

set_theme() {
	local name="$1"
	local media="$2"
	ssh_guest "uci set luci.themes.${name}='${media}' 2>/dev/null || true"
	ssh_guest "uci set luci.main.mediaurlbase='${media}'"
	ssh_guest 'uci commit luci'
	ok "active theme mediaurlbase=${media}"
}

run_paint_assert() {
	local label="$1"
	FWLIVE_URL="$FWLIVE_URL" FWLIVE_THEME_LABEL="$label" \
		"$NODE" "${ROOT}/tests/fwlive-theme-tint-smoke.mjs" \
		|| die "visible tint assert failed under ${label}"
	ok "visible tint under ${label}"
}

RESTORE_THEME="$(ssh_guest 'uci -q get luci.main.mediaurlbase' || true)"

cleanup() {
	if [[ -n "${RESTORE_THEME}" ]]; then
		ssh_guest "uci set luci.main.mediaurlbase='${RESTORE_THEME}'" >/dev/null 2>&1 || true
		ssh_guest 'uci commit luci' >/dev/null 2>&1 || true
		echo "restored mediaurlbase=${RESTORE_THEME}" >&2
	fi
}
trap cleanup EXIT

ensure_theme_pkg 'luci-theme-bootstrap' '/www/luci-static/bootstrap'
set_theme 'Bootstrap' '/luci-static/bootstrap'
run_paint_assert 'bootstrap'

ensure_theme_pkg 'luci-theme-material' '/www/luci-static/material'
set_theme 'Material' '/luci-static/material'
run_paint_assert 'material'

echo "== theme tint smoke passed (bootstrap + material) ==" >&2
