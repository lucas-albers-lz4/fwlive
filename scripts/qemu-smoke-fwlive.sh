#!/usr/bin/env bash
# Headless smoke test for luci-app-fwlive on a running QEMU guest.
#
#   ./scripts/qemu-smoke-fwlive.sh
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-smoke-fwlive.sh
#
# Checks: SSH, release, ubus log.read, fwlive rules, LuCI static assets, optional ping log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
HTTP_PORT="${OWRT_HOSTFWD_HTTP:-8080}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")

die() { echo "smoke FAIL: $*" >&2; exit 1; }
ok() { echo "smoke OK: $*"; }

ssh_guest() {
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

echo "== fwlive QEMU smoke (root@${HOST}:${PORT}) ==" >&2

ssh_guest 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU and run qemu-lab-prepare-image.sh if needed"

RELEASE="$(ssh_guest '. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE:-unknown}"')"
ARCH="$(ssh_guest 'uname -m')"
ok "guest ${ARCH} OpenWrt ${RELEASE}"

ssh_guest 'ubus call log read '"'"'{"lines":5,"stream":false,"oneshot":true}'"'"'' >/dev/null \
	|| die "ubus log.read failed"
ok "ubus log.read"

ssh_guest 'ubus call fwlive rules' >/dev/null \
	|| die "ubus fwlive rules failed (rpcd plugin / ACL?)"
ok "ubus fwlive rules"

ssh_guest 'test -f /www/luci-static/resources/view/status/fwlive.js' \
	|| die "missing LuCI view JS"
ssh_guest 'test -f /www/luci-static/resources/fwlive/log.js' \
	|| die "missing fwlive/log.js"
ok "LuCI static assets"

HTTP_HEADERS="$(curl -sS -D - -o /dev/null \
	"http://${HOST}:${HTTP_PORT}/cgi-bin/luci/admin/status/fwlive" 2>/dev/null || true)"
HTTP_CODE="$(printf '%s' "$HTTP_HEADERS" | awk 'toupper($1) ~ /^HTTP/ { print $2; exit }')"
if [[ -z "$HTTP_CODE" ]]; then
	die "LuCI page unreachable"
fi
case "$HTTP_CODE" in
	200|302|303) ok "LuCI page HTTP ${HTTP_CODE}" ;;
	403)
		if printf '%s' "$HTTP_HEADERS" | grep -qi 'x-luci-login-required'; then
			ok "LuCI page HTTP 403 (login required — dispatcher OK)"
		else
			die "LuCI page HTTP 403 (check uhttpd ucode_prefix in qemu-lab-prepare-image.sh)"
		fi
		;;
	*) die "LuCI page HTTP ${HTTP_CODE} (expected 200/302/403-login)" ;;
esac

if ssh_guest 'command -v nft >/dev/null 2>&1'; then
	"${ROOT}/scripts/fwlive-nft-ping-log.sh" add --ssh >/dev/null 2>&1 || true
	ssh_guest 'ping -c 3 -W 1 127.0.0.1 >/dev/null 2>&1' || true
	sleep 1
	ROWS="$("${ROOT}/scripts/fwlive-ubus-read.sh" --lines 30 2>/dev/null | wc -l | tr -d ' ')"
	if [[ "${ROWS:-0}" -ge 1 ]]; then
		ok "firewall log pipeline (${ROWS} parsed row(s))"
	else
		echo "smoke WARN: no parsed firewall rows yet (nft log rule may need traffic)" >&2
	fi
fi

echo "== smoke passed ==" >&2
