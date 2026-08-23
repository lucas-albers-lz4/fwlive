#!/usr/bin/env bash
# Device smoke: uninstall restores WAN zone log to pre-first-enable baseline.
#
#   ./scripts/qemu-logging-uninstall-smoke.sh
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-logging-uninstall-smoke.sh
#
# Prereqs: QEMU guest up with luci-app-fwlive installed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")

die() { echo "logging-uninstall smoke FAIL: $*" >&2; exit 1; }
ok() { echo "logging-uninstall smoke OK: $*"; }

ssh_guest() {
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

uci_zone_log() {
	local zone="$1"
	ssh_guest "uci -q get firewall.${zone}.log || true"
}

echo "== fwlive logging-uninstall smoke (root@${HOST}:${PORT}) ==" >&2

ssh_guest 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU and install fwlive first"
ssh_guest 'command -v ubus >/dev/null && test -x /usr/libexec/rpcd/fwlive' \
	|| die "fwlive rpcd plugin missing"

"${ROOT}/scripts/qemu-reset-wan-logging.sh" >/dev/null

ZONE="$(ssh_guest "uci -q show firewall | sed -n \"s/^firewall\\.\\([^.]*\\)\\.name='wan'\$/\\1/p\" | head -1")"
[[ -n "$ZONE" ]] || die "no WAN zone in firewall config"
BASE_LOG="$(uci_zone_log "$ZONE")"
ok "baseline WAN log empty/unset (uci='${BASE_LOG}')"

EN="$(ssh_guest 'ubus call fwlive enable_wan_logging')"
printf '%s' "$EN" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' \
	|| die "enable failed: $EN"
AFTER_EN="$(uci_zone_log "$ZONE")"
[[ -n "$AFTER_EN" ]] || die "expected non-empty log after enable"
ssh_guest 'test -f /etc/fwlive/wan-log-baseline' \
	|| die "baseline file missing after enable"
ok "enable wrote baseline and set firewall.${ZONE}.log=${AFTER_EN}"

ssh_guest 'opkg remove --force-depends luci-app-fwlive' >/dev/null
AFTER_RM="$(uci_zone_log "$ZONE")"
[[ "$AFTER_RM" == "$BASE_LOG" ]] \
	|| die "uninstall did not restore baseline (want '${BASE_LOG}', got '${AFTER_RM}')"
ssh_guest 'test ! -f /etc/fwlive/wan-log-baseline' \
	|| die "baseline file still present after uninstall"
ok "uninstall restored firewall.${ZONE}.log to pre-enable state"

OWRT_FWLIVE_VERSION="${OWRT_FWLIVE_VERSION:-24.10.5}" "${ROOT}/scripts/qemu-install-fwlive.sh" >/dev/null 2>&1 \
	|| die "qemu-install-fwlive.sh failed after uninstall smoke"
ok "reinstalled luci-app-fwlive for lab"

echo "== logging-uninstall smoke passed ==" >&2
