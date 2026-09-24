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
# Version-changing APK upgrades are not covered (no two-version QEMU
# experiment). Host tests already model PKG_UPGRADE=1.
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

install_artifact "after uninstall smoke"
ok "reinstalled luci-app-fwlive for lab (--artifact-only)"

echo "== logging-uninstall smoke passed ==" >&2
