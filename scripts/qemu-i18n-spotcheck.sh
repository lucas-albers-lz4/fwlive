#!/usr/bin/env bash
# Lab spot-check (#72 / #46 / #640): switch LuCI to de / ru / zh-cn and assert fwlive strings.
#
# Force-reinstalls luci-i18n-fwlive-* from out/ (never short-circuits on already-
# installed) and installs luci-i18n-base-* from downloads.openwrt.org. Restores
# luci.main.lang afterward (delete if unset). Missing expected languages fail
# with a DEGRADED verdict — the run does not pass on a subset.
#
# Lab assumption: guest root has an empty password (same as other QEMU smokes).
#
#   ./scripts/qemu-i18n-spotcheck.sh
#   OPENWRT_SSH_PORT=2222 ./scripts/qemu-i18n-spotcheck.sh
#   FWLIVE_I18N_DIR=out/<arch>/<ver>/fwlive ./scripts/qemu-i18n-spotcheck.sh
#
# Default OUT path is the 24.10.8 x86_64 lab layout; override FWLIVE_I18N_DIR for
# other arches/versions. Runtime UCI lang is zh-cn; PO dir is zh_Hans (luci.mk
# LUCI_LC_ALIAS.zh_Hans=zh-cn).
#
# Keep EXPECT_LANGS in sync with EXPECT in tests/fwlive-i18n-spotcheck.mjs.
#
# See docs/developer/environment.md (Device edge cases).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
HTTP_PORT="${OWRT_HOSTFWD_HTTP:-8080}"
FWLIVE_URL="${FWLIVE_URL:-http://${HOST}:${HTTP_PORT}}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")
OUT_I18N="${FWLIVE_I18N_DIR:-${ROOT}/out/x86_64/24.10.8/fwlive}"
NODE="${NODE:-}"
PREV_LANG=""
HAD_LANG=0
PKG_MGR=""
# Locked to the Playwright EXPECT table — do not expand without updating both.
EXPECT_LANGS=(de ru zh-cn)
COVERED=()
MISSING=()

die() { echo "i18n spotcheck FAIL: $*" >&2; exit 1; }
ok() { echo "i18n spotcheck OK: $*"; }
warn() { echo "i18n spotcheck WARN: $*" >&2; }

join_langs() {
	local IFS=' '
	printf '%s' "$*"
}

verdict() {
	local status="$1"
	local covered_list missing_list
	covered_list="$(join_langs "${COVERED[@]+"${COVERED[@]}"}")"
	missing_list="$(join_langs "${MISSING[@]+"${MISSING[@]}"}")"
	echo "i18n spotcheck ${status}: covered=[${covered_list}] missing=[${missing_list}]" >&2
}

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

if ssh_guest 'command -v apk >/dev/null 2>&1'; then
	PKG_MGR=apk
elif ssh_guest 'command -v opkg >/dev/null 2>&1'; then
	PKG_MGR=opkg
else
	die "neither opkg nor apk on guest"
fi
ok "guest package manager is ${PKG_MGR}"

if [[ "$PKG_MGR" == apk ]]; then
	ssh_guest 'apk update >/dev/null 2>&1 || true'
else
	ssh_guest 'opkg update >/dev/null 2>&1 || true'
fi

ensure_base_i18n() {
	local lang="$1"
	if [[ "$PKG_MGR" == apk ]]; then
		if ssh_guest "apk add luci-i18n-base-${lang}"; then
			ok "luci-i18n-base-${lang} present"
			return 0
		fi
	else
		if ssh_guest "opkg list-installed | grep -q '^luci-i18n-base-${lang} '"; then
			ok "luci-i18n-base-${lang} present"
			return 0
		fi
		if ssh_guest "opkg install luci-i18n-base-${lang}"; then
			ok "installed luci-i18n-base-${lang}"
			return 0
		fi
	fi
	warn "luci-i18n-base-${lang} unavailable — cannot cover ${lang}"
	return 1
}

# Newest matching ipk/apk under FWLIVE_I18N_DIR, then any out/*/fwlive tree.
find_fwlive_i18n_artifact() {
	local lang="$1"
	local pkg="luci-i18n-fwlive-${lang}"
	local art=""
	if [[ -d "$OUT_I18N" ]]; then
		art="$(ls -1t "${OUT_I18N}/${pkg}"_*.ipk "${OUT_I18N}/${pkg}"_*.apk 2>/dev/null | head -1 || true)"
	fi
	if [[ -z "$art" ]]; then
		art="$(ls -1t \
			"${ROOT}"/out/*/fwlive/"${pkg}"_*.ipk \
			"${ROOT}"/out/*/*/fwlive/"${pkg}"_*.ipk \
			"${ROOT}"/out/*/fwlive/"${pkg}"_*.apk \
			"${ROOT}"/out/*/*/fwlive/"${pkg}"_*.apk \
			2>/dev/null | head -1 || true)"
	fi
	[[ -n "$art" && -f "$art" ]] || return 1
	printf '%s\n' "$art"
}

# Always push the current artifact and --force-reinstall. An already-installed
# package is stale until replaced from this tree's build output (#640).
install_fwlive_i18n() {
	local lang="$1"
	local pkg="luci-i18n-fwlive-${lang}"
	local art=""
	if ! art="$(find_fwlive_i18n_artifact "$lang")"; then
		warn "no ${pkg}_*.{ipk,apk} under ${OUT_I18N} (or out/*/fwlive) — cannot cover ${lang}"
		return 1
	fi
	local base
	base="$(basename "$art")"
	push_file "$art" "/tmp/${base}"
	if [[ "$PKG_MGR" == apk ]]; then
		ssh_guest "apk add --allow-untrusted --force-reinstall '/tmp/${base}'" \
			|| die "apk --force-reinstall ${base} failed"
	else
		ssh_guest "opkg install --force-reinstall '/tmp/${base}'" \
			|| die "opkg --force-reinstall ${base} failed"
	fi
	ok "force-reinstalled ${base}"
}

for lang in "${EXPECT_LANGS[@]}"; do
	if ! ensure_base_i18n "$lang"; then
		MISSING+=("$lang")
		continue
	fi
	if ! install_fwlive_i18n "$lang"; then
		MISSING+=("$lang")
		continue
	fi
	COVERED+=("$lang")
done

if [[ ${#COVERED[@]} -eq 0 ]]; then
	verdict DEGRADED
	die "no expected luci-i18n-fwlive-* languages covered (missing: $(join_langs "${MISSING[*]}"))"
fi

for lang in "${COVERED[@]}"; do
	ssh_guest "uci set luci.main.lang='${lang}'; uci commit luci"
	ok "luci.main.lang=${lang}"
	FWLIVE_URL="$FWLIVE_URL" FWLIVE_LANG="$lang" "$NODE" "${ROOT}/tests/fwlive-i18n-spotcheck.mjs" \
		|| die "Playwright spotcheck failed for ${lang}"
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
	verdict DEGRADED
	die "expected languages not covered: $(join_langs "${MISSING[*]}")"
fi

verdict OK
ok "covered=[$(join_langs "${COVERED[*]}")] missing=[]"
echo "== i18n spotcheck passed ==" >&2
