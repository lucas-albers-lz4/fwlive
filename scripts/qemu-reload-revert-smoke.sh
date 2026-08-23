#!/usr/bin/env bash
# Device smoke (#72 / #64): firewall reload failure rolls back WAN log UCI.
#
# Temporarily wraps /etc/init.d/firewall so `reload` fails, then calls
# ubus fwlive enable/disable_wan_logging and asserts UCI restoration + error JSON.
#
# Prereqs: QEMU guest up with luci-app-fwlive installed.
#
#   ./scripts/qemu-reload-revert-smoke.sh
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-reload-revert-smoke.sh
#
# See docs/developer/environment.md (Device edge cases).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")
# Persistent overlay (not /tmp) so a guest reboot mid-test cannot lose the backup
# while leaving the wrapper in place (#83).
WRAP_DIR="/etc/fwlive-reload-wrap.$$"
REAL_FW="/etc/init.d/firewall"
BAK_FW="${WRAP_DIR}/firewall.real"
WRAPPER_INSTALLED=0

die() { echo "reload-revert smoke FAIL: $*" >&2; exit 1; }
ok() { echo "reload-revert smoke OK: $*"; }

ssh_guest() {
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

restore_firewall() {
	if [[ "$WRAPPER_INSTALLED" -eq 1 ]]; then
		ssh_guest "if [ -f '${BAK_FW}' ]; then
			cp -a '${BAK_FW}' '${REAL_FW}'
			chmod +x '${REAL_FW}'
			cmp -s '${BAK_FW}' '${REAL_FW}' || exit 2
			rm -rf '${WRAP_DIR}'
		else
			echo 'reload-revert: backup missing at ${BAK_FW}' >&2
			exit 3
		fi" || die "failed to restore ${REAL_FW} from ${BAK_FW}"
		WRAPPER_INSTALLED=0
		ok "restored ${REAL_FW} from persistent backup"
	fi
}
trap restore_firewall EXIT INT TERM HUP

install_failing_reload() {
	ssh_guest "mkdir -p '${WRAP_DIR}' && cp -a '${REAL_FW}' '${BAK_FW}' && test -f '${BAK_FW}'"
	# Stream wrapper over SSH stdin (local expands BAK_FW; remote keeps $1 / $@).
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "cat > '${REAL_FW}' && chmod +x '${REAL_FW}'" <<EOF
#!/bin/sh
if [ "\${1:-}" = "reload" ]; then
	echo "fwlive-lab: simulated firewall reload failure" >&2
	exit 1
fi
exec '${BAK_FW}' "\$@"
EOF
	WRAPPER_INSTALLED=1
}

uci_zone_log() {
	local zone="$1"
	ssh_guest "uci -q get firewall.${zone}.log || true"
}

echo "== fwlive reload-revert smoke (root@${HOST}:${PORT}) ==" >&2

ssh_guest 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU and install fwlive first"
ssh_guest 'command -v ubus >/dev/null && test -x /usr/libexec/rpcd/fwlive' \
	|| die "fwlive rpcd plugin missing"
ssh_guest "test -x '${REAL_FW}'" \
	|| die "${REAL_FW} missing"

# Baseline: WAN logging ON
EN="$(ssh_guest 'ubus call fwlive enable_wan_logging')"
printf '%s' "$EN" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' \
	|| die "could not enable WAN logging for baseline: $EN"

ZONE="$(ssh_guest "ubus call fwlive logging_status" | sed -n 's/.*"wan_zone": *"\([^"]*\)".*/\1/p' | head -1)"
[[ -n "$ZONE" ]] || die "no wan_zone from logging_status"
BEFORE="$(uci_zone_log "$ZONE")"
[[ -n "$BEFORE" ]] || die "expected non-empty firewall.${ZONE}.log after enable"
ok "baseline WAN logging on (firewall.${ZONE}.log=${BEFORE})"

# --- disable path: reload fails → UCI restored to BEFORE ---
install_failing_reload
DIS="$(ssh_guest 'ubus call fwlive disable_wan_logging')"
printf '%s' "$DIS" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*false' \
	|| die "disable expected ok:false on reload fail, got: $DIS"
printf '%s' "$DIS" | grep -q 'firewall_reload_failed' \
	|| die "disable expected error firewall_reload_failed, got: $DIS"
AFTER_DIS="$(uci_zone_log "$ZONE")"
[[ "$AFTER_DIS" == "$BEFORE" ]] \
	|| die "disable reload-fail did not restore UCI (want ${BEFORE}, got '${AFTER_DIS}')"
ok "disable + reload fail → UCI unchanged (${AFTER_DIS}) + firewall_reload_failed"
restore_firewall

# Baseline for enable path: WAN logging OFF
OFF="$(ssh_guest 'ubus call fwlive disable_wan_logging')"
printf '%s' "$OFF" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' \
	|| die "could not disable WAN logging for enable-path baseline: $OFF"
OFF_VAL="$(uci_zone_log "$ZONE")"
ok "baseline WAN logging off (uci='${OFF_VAL}')"

# --- enable path: reload fails → UCI restored to OFF_VAL ---
install_failing_reload
EN_FAIL="$(ssh_guest 'ubus call fwlive enable_wan_logging')"
printf '%s' "$EN_FAIL" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*false' \
	|| die "enable expected ok:false on reload fail, got: $EN_FAIL"
printf '%s' "$EN_FAIL" | grep -q 'firewall_reload_failed' \
	|| die "enable expected error firewall_reload_failed, got: $EN_FAIL"
AFTER_EN="$(uci_zone_log "$ZONE")"
[[ "$AFTER_EN" == "$OFF_VAL" ]] \
	|| die "enable reload-fail did not restore UCI (want '${OFF_VAL}', got '${AFTER_EN}')"
ok "enable + reload fail → UCI unchanged ('${AFTER_EN}') + firewall_reload_failed"
restore_firewall

# Leave guest with logging OFF and no baseline (lab-friendly default).
"${ROOT}/scripts/qemu-reset-wan-logging.sh" >/dev/null
ok "reset WAN logging for lab"

# UI error path (handleEnableLogging → "Could not enable logging.") is not
# exercised here — covered by the JS handler; this smoke is ubus/UCI only.

echo "== reload-revert smoke passed ==" >&2
