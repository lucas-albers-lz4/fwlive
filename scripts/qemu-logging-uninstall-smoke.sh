#!/usr/bin/env bash
# Device smoke: uninstall restores WAN zone log to pre-first-enable baseline.
#
#   ./scripts/qemu-logging-uninstall-smoke.sh
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-logging-uninstall-smoke.sh
#
# Prereqs: QEMU guest up with luci-app-fwlive installed from the package
# artifact (`qemu-install-fwlive.sh --artifact-only`).
#
# One script, two package-manager proofs:
# - `opkg remove` (24.10) / `apk del` (25.12) — uninstall hook
#   (`prerm` / `pre-deinstall`).
# - 25.12 same-version `apk add --force-reinstall` — preservation only
#   (`post-upgrade`, no `pre-deinstall`).
#
# Version-changing APK upgrades run post-upgrade only (two-version
# QEMU proof in docs/evidence/issue-848-2026-09-27.md). Host tests
# already model PKG_UPGRADE=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sdk-matrix.sh
source "$ROOT/scripts/lib/sdk-matrix.sh"
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

disabled_log_value() {
	local value="$1"
	case "$value" in
		''|*[!0-9]*) printf '' ; return ;;
	esac
	if [[ "${#value}" -gt 10 ]]; then
		printf ''
		return
	fi
	# Match the package's decimal bitmask behavior while avoiding Bash's
	# octal interpretation of values such as 08 and 0002.
	while [[ "$value" == 0* && "$value" != 0 ]]; do
		value="${value#0}"
	done
	value="${value:-0}"
	local remaining=$((10#$value & ~1))
	if (( remaining > 0 )); then
		printf '%s' "$remaining"
	fi
}

install_artifact() {
	OWRT_FWLIVE_VERSION="$OWRT_FWLIVE_VERSION" \
		"${ROOT}/scripts/qemu-install-fwlive.sh" --artifact-only >/dev/null 2>&1 \
		|| die "qemu-install-fwlive.sh --artifact-only failed${1:+ $1}"
}

echo "== fwlive logging-uninstall smoke (root@${HOST}:${PORT}) ==" >&2

ssh_guest 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU and install fwlive first"
ssh_guest 'command -v ubus >/dev/null && test -x /usr/libexec/rpcd/fwlive' \
	|| die "fwlive rpcd plugin missing"

PKG_MGR=opkg
if ssh_guest 'command -v apk >/dev/null'; then
	PKG_MGR=apk
fi
ok "guest package manager is ${PKG_MGR}"

if [[ -z "${OWRT_FWLIVE_VERSION:-}" ]]; then
	rel="$(ssh_guest '. /etc/openwrt_release && echo "$DISTRIB_RELEASE"')"
	OWRT_FWLIVE_VERSION="$(sdk_matrix_version_label "$rel")"
fi

"${ROOT}/scripts/qemu-reset-wan-logging.sh" >/dev/null

ZONE="$(ssh_guest 'ubus call fwlive logging_status 2>/dev/null | jsonfilter -e '\''$.wan_zone'\'' 2>/dev/null || true')"
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

if [[ "$PKG_MGR" == apk ]]; then
	# Same-version --force-reinstall is preservation only: apk runs
	# post-upgrade (PKG_UPGRADE=1) and does not run pre-deinstall.
	install_artifact "during same-version --force-reinstall"
	AFTER_REIN="$(uci_zone_log "$ZONE")"
	[[ "$AFTER_REIN" == "$AFTER_EN" ]] \
		|| die "same-version --force-reinstall changed WAN log (want '${AFTER_EN}', got '${AFTER_REIN}')"
	ssh_guest 'test -f /etc/fwlive/wan-log-baseline' \
		|| die "baseline file missing after same-version --force-reinstall"
	ok "same-version --force-reinstall preserved firewall.${ZONE}.log and baseline (post-upgrade, no pre-deinstall)"
	ssh_guest 'apk del luci-app-fwlive' >/dev/null
else
	ssh_guest 'opkg remove --force-depends luci-app-fwlive' >/dev/null
fi
AFTER_RM="$(uci_zone_log "$ZONE")"
[[ "$AFTER_RM" == "$BASE_LOG" ]] \
	|| die "uninstall did not restore baseline (want '${BASE_LOG}', got '${AFTER_RM}')"
ssh_guest 'test ! -f /etc/fwlive/wan-log-baseline' \
	|| die "baseline file still present after uninstall"
ok "uninstall restored firewall.${ZONE}.log to pre-enable state"

# Exercise the new disable-retirement path against the installed package. A
# later operator mask change must survive uninstall because Disable retired the
# package's stale pre-enable restore marker after the successful reload.
install_artifact "before disable/operator preservation smoke"
"${ROOT}/scripts/qemu-reset-wan-logging.sh" >/dev/null
ZONE="$(ssh_guest 'ubus call fwlive logging_status 2>/dev/null | jsonfilter -e '\''$.wan_zone'\'' 2>/dev/null || true')"
[[ -n "$ZONE" ]] || die "no WAN zone in firewall config for disable/operator smoke"
PRESERVE_BASE_LOG="$(uci_zone_log "$ZONE")"

EN="$(ssh_guest 'ubus call fwlive enable_wan_logging')"
printf '%s' "$EN" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' \
	|| die "second enable failed: $EN"
ssh_guest 'test -f /etc/fwlive/wan-log-baseline' \
	|| die "baseline marker missing after second enable"

DIS="$(ssh_guest 'ubus call fwlive disable_wan_logging')"
printf '%s' "$DIS" | grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' \
	|| die "disable failed before operator-preservation check: $DIS"
ssh_guest 'test ! -f /etc/fwlive/wan-log-baseline' \
	|| die "baseline marker remains after successful disable"
AFTER_DIS="$(uci_zone_log "$ZONE")"
EXPECTED_AFTER_DIS="$(disabled_log_value "$PRESERVE_BASE_LOG")"
[[ "$AFTER_DIS" == "$EXPECTED_AFTER_DIS" ]] \
	|| die "disable did not clear only the filter-log bit (want '${EXPECTED_AFTER_DIS:-<unset>}' from baseline '${PRESERVE_BASE_LOG:-<unset>}', got '${AFTER_DIS:-<unset>}')"
ok "disable cleared the filter-log bit from baseline '${PRESERVE_BASE_LOG:-<unset>}' and retired its marker"

if [[ "$EXPECTED_AFTER_DIS" == 2 ]]; then
	OPERATOR_LOG=4
else
	OPERATOR_LOG=2
fi
ssh_guest "uci -q set 'firewall.${ZONE}.log=${OPERATOR_LOG}' && uci commit firewall && /etc/init.d/firewall reload" \
	>/dev/null || die "could not commit and reload the later operator log mask"
AFTER_OPERATOR="$(uci_zone_log "$ZONE")"
[[ "$AFTER_OPERATOR" == "$OPERATOR_LOG" ]] \
	|| die "operator log mask was not applied (want '${OPERATOR_LOG}', got '${AFTER_OPERATOR}')"
ok "later operator change set firewall.${ZONE}.log=${OPERATOR_LOG}"

if [[ "$PKG_MGR" == apk ]]; then
	ssh_guest 'apk del luci-app-fwlive' >/dev/null
else
	ssh_guest 'opkg remove --force-depends luci-app-fwlive' >/dev/null
fi
AFTER_OPERATOR_RM="$(uci_zone_log "$ZONE")"
[[ "$AFTER_OPERATOR_RM" == "$OPERATOR_LOG" ]] \
	|| die "uninstall overwrote later operator log mask (want '${OPERATOR_LOG}', got '${AFTER_OPERATOR_RM}')"
ssh_guest 'test ! -f /etc/fwlive/wan-log-baseline' \
	|| die "stale baseline marker returned after disable/uninstall"
ok "uninstall preserved later operator log mask ${OPERATOR_LOG}"

install_artifact "after uninstall smoke"
ok "reinstalled luci-app-fwlive for lab (--artifact-only)"

echo "== logging-uninstall smoke passed ==" >&2
