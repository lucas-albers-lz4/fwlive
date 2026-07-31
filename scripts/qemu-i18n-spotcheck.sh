#!/usr/bin/env bash
# Lab spot-check (#72 / #46): switch LuCI to de / ru / zh-cn and assert fwlive strings.
#
# Installs luci-i18n-fwlive-* from out/ (when present) and luci-i18n-base-* from
# downloads.openwrt.org. Restores luci.main.lang afterward (delete if unset).
#
# Lab assumption: guest root has an empty password (same as other QEMU smokes).
#
#   ./scripts/qemu-i18n-spotcheck.sh
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-i18n-spotcheck.sh
#   FWLIVE_I18N_DIR=out/<arch>/<ver>/fwlive ./scripts/qemu-i18n-spotcheck.sh
#
# Default OUT path is the 24.10.5 x86_64 lab layout; override FWLIVE_I18N_DIR for
# other arches/versions. Runtime UCI lang is zh-cn; PO dir is zh_Hans (luci.mk
# LUCI_LC_ALIAS.zh_Hans=zh-cn).
#
# See docs/developer/environment.md (Device edge cases).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
HTTP_PORT="${OWRT_HOSTFWD_HTTP:-8080}"
FWLIVE_URL="${FWLIVE_URL:-http://${HOST}:${HTTP_PORT}}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")
OUT_I18N="${FWLIVE_I18N_DIR:-${ROOT}/out/x86_64/24.10.5/fwlive}"
NODE="${NODE:-}"
PREV_LANG=""
HAD_LANG=0

die() { echo "i18n spotcheck FAIL: $*" >&2; exit 1; }
ok() { echo "i18n spotcheck OK: $*"; }
warn() { echo "i18n spotcheck WARN: $*" >&2; }

ssh_guest() {
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

push_file() {
	local src="$1" dest="$2"
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "cat > '${dest}'" < "$src"
}

restore_lang() {
	if [[ "$HAD_LANG" -eq 1 ]]; then
		ssh_guest "uci set luci.main.lang='${PREV_LANG}'; uci commit luci" 2>/dev/null || true
	else
		# Key was unset — delete rather than writing option lang 'auto'.
		ssh_guest "uci -q delete luci.main.lang; uci commit luci" 2>/dev/null || true
	fi
}
trap restore_lang EXIT INT TERM HUP

if [[ -z "$NODE" ]]; then
	if command -v node >/dev/null 2>&1; then
		NODE=node
	elif command -v nodejs >/dev/null 2>&1; then
		NODE=nodejs
	else
		die "nodejs required for Playwright spotcheck"
	fi
fi

echo "== fwlive i18n spotcheck (root@${HOST}:${PORT}) ==" >&2

ssh_guest 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable — start QEMU and install fwlive first"

if PREV_LANG="$(ssh_guest 'uci -q get luci.main.lang')"; then
	HAD_LANG=1
	ok "saved luci.main.lang=${PREV_LANG}"
else
	HAD_LANG=0
	PREV_LANG=""
	ok "luci.main.lang was unset (will delete on restore)"
fi

# Ensure base language packs (OpenWrt downloads). Skip a lang if base install fails
# so offline guests can still check fwlive strings for languages already present.
ssh_guest 'opkg update >/dev/null 2>&1 || true'
BASE_OK=()
for lang in de ru zh-cn; do
	if ssh_guest "opkg list-installed | grep -q '^luci-i18n-base-${lang} '"; then
		ok "luci-i18n-base-${lang} present"
		BASE_OK+=("$lang")
		continue
	fi
	if ssh_guest "opkg install luci-i18n-base-${lang}"; then
		ok "installed luci-i18n-base-${lang}"
		BASE_OK+=("$lang")
	else
		warn "opkg install luci-i18n-base-${lang} failed — skip ${lang}"
	fi
done
[[ ${#BASE_OK[@]} -gt 0 ]] || die "no luci-i18n-base-* languages available to test"

# Push fwlive i18n packages from out/ when available.
install_fwlive_i18n() {
	local lang="$1"
	local pkg="luci-i18n-fwlive-${lang}"
	if ssh_guest "opkg list-installed | grep -q '^${pkg} '"; then
		ok "${pkg} already installed"
		return 0
	fi
	local ipk=""
	if [[ -d "$OUT_I18N" ]]; then
		ipk="$(ls -1t "${OUT_I18N}/${pkg}"_*.ipk 2>/dev/null | head -1 || true)"
	fi
	if [[ -z "$ipk" ]]; then
		# Fall back to any out/*/fwlive tree (newest matching ipk).
		ipk="$(ls -1t "${ROOT}"/out/*/fwlive/"${pkg}"_*.ipk "${ROOT}"/out/*/*/fwlive/"${pkg}"_*.ipk 2>/dev/null | head -1 || true)"
	fi
	if [[ -z "$ipk" ]]; then
		warn "no ${pkg}_*.ipk under ${OUT_I18N} (or out/*/fwlive) — skip ${lang}"
		return 1
	fi
	local base
	base="$(basename "$ipk")"
	push_file "$ipk" "/tmp/${base}"
	ssh_guest "opkg install '/tmp/${base}'" || die "opkg install ${base} failed"
	ok "installed ${base}"
}

LANGS=()
for lang in "${BASE_OK[@]}"; do
	if install_fwlive_i18n "$lang"; then
		LANGS+=("$lang")
	fi
done
[[ ${#LANGS[@]} -gt 0 ]] || die "no luci-i18n-fwlive-* packages available to test"

for lang in "${LANGS[@]}"; do
	ssh_guest "uci set luci.main.lang='${lang}'; uci commit luci"
	ok "luci.main.lang=${lang}"
	FWLIVE_URL="$FWLIVE_URL" FWLIVE_LANG="$lang" "$NODE" "${ROOT}/tests/fwlive-i18n-spotcheck.mjs" \
		|| die "Playwright spotcheck failed for ${lang}"
done

ok "checked languages: ${LANGS[*]}"
echo "== i18n spotcheck passed ==" >&2
