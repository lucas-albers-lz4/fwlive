#!/usr/bin/env bash
# Exercise the packaged prerm action contract without requiring an SDK or root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$ROOT/openwrt-feed/luci-app-fwlive/Makefile"
# shellcheck source=../scripts/lib/sdk-apk.sh
source "$ROOT/scripts/lib/sdk-apk.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HOOK="$WORK/prerm"
HOOK_RAW="$WORK/prerm-raw"
HELPER="$WORK/fwlive-logging.sh"
MARKER="$WORK/restore-marker"
BIN="$WORK/bin"
mkdir -p "$BIN"

awk '
	$0 == "define Package/luci-app-fwlive/prerm" { in_prerm=1; next }
	in_prerm && $0 == "endef" { exit }
	in_prerm {
		sub(/^\t/, "")
		gsub(/\$\$/, "$")
		print
	}
' "$MAKEFILE" >"$HOOK_RAW"
sed "s|^\. /usr/libexec/fwlive-logging\\.sh$|. $HELPER|" "$HOOK_RAW" >"$HOOK"
chmod 755 "$HOOK" "$HOOK_RAW"

cat >"$HELPER" <<'EOF'
#!/bin/sh
restore_wan_log_baseline() {
	printf '%s\n' restore >>"${FWLIVE_PRERM_MARKER:?}"
	[ "${FWLIVE_RESTORE_RC:-0}" -eq 0 ]
}
EOF
chmod 644 "$HELPER"

cat >"$BIN/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$BIN/logger"

fail() {
	echo "fwlive-package-lifecycle test FAIL: $*" >&2
	exit 1
}

ok() {
	echo "fwlive-package-lifecycle test OK: $*"
}

install_hook_from_body() {
	local src="$1"
	local dest="$2"
	sed "s|^\. /usr/libexec/fwlive-logging\\.sh$|. $HELPER|" "$src" >"$dest"
	chmod 755 "$dest"
}

pack_synthetic_ipk() {
	local dest="$1"
	local prerm_pkg="$2"
	local stage="$WORK/ipk-stage"
	rm -rf "$stage"
	mkdir -p "$stage/ctrl" "$stage/empty"
	printf '%s\n' '#!/bin/sh' 'default_prerm $0 $@' >"$stage/ctrl/prerm"
	chmod 755 "$stage/ctrl/prerm"
	cp "$prerm_pkg" "$stage/ctrl/prerm-pkg"
	chmod 755 "$stage/ctrl/prerm-pkg"
	printf '2.0\n' >"$stage/debian-binary"
	tar -C "$stage/ctrl" -czf "$stage/control.tar.gz" ./prerm ./prerm-pkg
	tar -C "$stage/empty" -czf "$stage/data.tar.gz" .
	rm -f "$dest"
	if command -v ar >/dev/null 2>&1; then
		(cd "$stage" && ar rc "$dest" debian-binary control.tar.gz data.tar.gz)
	else
		tar -C "$stage" -cf "$dest" ./debian-binary ./control.tar.gz ./data.tar.gz
	fi
}

extract_ipk_prerm() {
	local pkg="$1"
	local dest_dir="$2"
	local control="$dest_dir/control.tar.gz"
	mkdir -p "$dest_dir"
	if tar -xzOf "$pkg" ./control.tar.gz >"$control" 2>/dev/null; then
		:
	elif tar -xOf "$pkg" ./control.tar.gz >"$control" 2>/dev/null; then
		:
	elif ar p "$pkg" control.tar.gz >"$control" 2>/dev/null; then
		:
	else
		fail 'could not extract IPK control archive'
	fi
	tar -tzf "$control" | grep -qx './prerm'
	tar -tzf "$control" | grep -qx './prerm-pkg'
	tar -xzOf "$control" ./prerm >"$dest_dir/prerm"
	tar -xzOf "$control" ./prerm-pkg >"$dest_dir/prerm-pkg"
}

packaged_body_contract_ok() {
	local body="$1"
	grep -Fq 'PKG_UPGRADE' "$body" || return 1
	grep -Fq 'case "${2-}"' "$body" || grep -Fq 'case "$2"' "$body" || return 1
	grep -Fq 'remove' "$body" || return 1
	if grep -E -q '\[[[:space:]]*"\$1"[[:space:]]*=[[:space:]]*"remove"[[:space:]]*\][[:space:]]*\|\|[[:space:]]*exit[[:space:]]+0' "$body"; then
		return 1
	fi
	return 0
}

assert_packaged_body_contract() {
	local body="$1"
	local label="$2"
	packaged_body_contract_ok "$body" ||
		fail "$label lacks PKG_UPGRADE / \$2 action dispatch, or still matches [ \"\$1\" = \"remove\" ] || exit 0"
	ok "$label has PKG_UPGRADE and \$2 action dispatch"
}

run_hook() {
	local action="$1"
	rm -f "$MARKER"
	if [ "$action" = __empty__ ]; then
		IPKG_INSTROOT=/ FWLIVE_PRERM_MARKER="$MARKER" PATH="$BIN:$PATH" "$HOOK"
	else
		IPKG_INSTROOT=/ FWLIVE_PRERM_MARKER="$MARKER" PATH="$BIN:$PATH" "$HOOK" "$action"
	fi
}

run_opkg_hook() {
	local action="$1"
	rm -f "$MARKER"
	if [ "$action" = __empty__ ]; then
		IPKG_INSTROOT=/ FWLIVE_PRERM_MARKER="$MARKER" PATH="$BIN:$PATH" \
			"$HOOK" "$WORK/usr/lib/opkg/info/luci-app-fwlive.prerm"
	else
		IPKG_INSTROOT=/ FWLIVE_PRERM_MARKER="$MARKER" PATH="$BIN:$PATH" \
			"$HOOK" "$WORK/usr/lib/opkg/info/luci-app-fwlive.prerm" "$action"
	fi
}

run_apk_uninstall_hook() {
	rm -f "$MARKER"
	IPKG_INSTROOT=/ FWLIVE_PRERM_MARKER="$MARKER" PATH="$BIN:$PATH" \
		"$HOOK" 0.1.44-r1
}

assert_restored() {
	[ -s "$MARKER" ] || fail "$1 must restore the baseline"
}

assert_not_restored() {
	[ ! -e "$MARKER" ] || fail "$1 must not restore the baseline"
}

run_lifecycle_matrix() {
	local label="$1"
	run_hook remove
	assert_restored "$label-remove"
	ok "$label: explicit remove restores the baseline"

	run_hook upgrade
	assert_not_restored "$label-upgrade"
	ok "$label: direct upgrade preserves the baseline"

	run_hook __empty__
	assert_not_restored "$label-empty"
	ok "$label: empty action fails closed without restoring the baseline"

	run_hook unexpected
	assert_not_restored "$label-unexpected"
	ok "$label: unknown package action fails closed without restoring"

	run_hook 123
	assert_not_restored "$label-numeric-action"
	ok "$label: numeric non-version action fails closed without restoring"

	run_hook 1a2
	assert_not_restored "$label-1a2"
	ok "$label: 1a2 is not a version and must not restore"

	run_opkg_hook remove
	assert_restored "$label-opkg-remove"
	ok "$label: generated opkg wrapper remove restores the baseline"

	run_opkg_hook upgrade
	assert_not_restored "$label-opkg-upgrade"
	ok "$label: generated opkg wrapper upgrade preserves the baseline"

	run_opkg_hook __empty__
	assert_not_restored "$label-opkg-empty"
	ok "$label: generated opkg wrapper with no action fails closed"

	run_apk_uninstall_hook
	assert_restored "$label-apk-uninstall"
	ok "$label: APK version-valued uninstall restores the baseline"

	# OpenWrt APK post-upgrade (package-pack.mk) exports PKG_UPGRADE=1;
	# belt-and-braces with the upgrade action arg.
	rm -f "$MARKER"
	if IPKG_INSTROOT=/ FWLIVE_PRERM_MARKER="$MARKER" PATH="$BIN:$PATH" PKG_UPGRADE=1 \
		"$HOOK" "$WORK/usr/lib/opkg/info/luci-app-fwlive.prerm" remove; then
		:
	else
		fail "$label: PKG_UPGRADE=1 invocation must succeed"
	fi
	assert_not_restored "$label-pkg-upgrade"
	ok "$label: PKG_UPGRADE=1 with remove-shaped argv must not restore"

	rm -f "$MARKER"
	if IPKG_INSTROOT="$WORK/staging" FWLIVE_PRERM_MARKER="$MARKER" PATH="$BIN:$PATH" "$HOOK" remove; then
		:
	else
		fail "$label: non-root staging invocation must succeed"
	fi
	assert_not_restored "$label-staging"
	ok "$label: non-root staging invocation skips runtime helpers"

	rm -f "$MARKER"
	if IPKG_INSTROOT=/ FWLIVE_PRERM_MARKER="$MARKER" FWLIVE_RESTORE_RC=1 PATH="$BIN:$PATH" "$HOOK" remove; then
		:
	else
		fail "$label: restore failure must not fail package removal"
	fi
	assert_restored "$label-restore-failure"
	ok "$label: restore failure remains best-effort and keeps the removal hook successful"
}

run_wrapper_hop() {
	local body="$1"
	local wrapper="$WORK/usr/lib/opkg/info/luci-app-fwlive.prerm"
	mkdir -p "$(dirname "$wrapper")"
	cp "$body" "${wrapper}-pkg"
	chmod 755 "${wrapper}-pkg"
	# Generated opkg prerm is `default_prerm $0 $@`. OpenWrt sources
	# "$1-pkg" in a subshell so the body sees $1=<wrapper> and $2=action.
	# That hop made tag v0.1.44's `[ "$1" = "remove" ]` never fire.
	cat >"$wrapper" <<'EOF'
#!/bin/sh
default_prerm() {
	( . "$1-pkg" )
}
default_prerm $0 $@
EOF
	chmod 755 "$wrapper"

	rm -f "$MARKER"
	IPKG_INSTROOT=/ FWLIVE_PRERM_MARKER="$MARKER" PATH="$BIN:$PATH" \
		"$wrapper" remove
	assert_restored wrapper-remove
	ok 'default_prerm hop: remove restores the baseline'

	rm -f "$MARKER"
	IPKG_INSTROOT=/ FWLIVE_PRERM_MARKER="$MARKER" PATH="$BIN:$PATH" \
		"$wrapper" upgrade
	assert_not_restored wrapper-upgrade
	ok 'default_prerm hop: upgrade preserves the baseline'
}

oracle_ipk() {
	local pkg="$1"
	local dest="$WORK/oracle-extract"
	rm -rf "$dest"
	extract_ipk_prerm "$pkg" "$dest"
	grep -Fq 'default_prerm $0 $@' "$dest/prerm" ||
		fail 'packaged wrapper must call default_prerm $0 $@'
	assert_packaged_body_contract "$dest/prerm-pkg" 'packaged prerm-pkg'
	install_hook_from_body "$dest/prerm-pkg" "$dest/hook"
	HOOK="$dest/hook"
	run_lifecycle_matrix "$2"
}

inspect_apk_payload_dir() {
	local payload="${FWLIVE_PAYLOAD_DIR:-}"
	local found=""
	if [ -n "$payload" ]; then
		[ -d "$payload" ] || fail "payload directory not found: $payload"
		# apk extract ships data files only. Control scripts live in ADB
		# metadata, so do not treat a payload helper that mentions
		# restore_wan_log_baseline (fwlive-logging.sh) as pre-deinstall.
		found="$(find "$payload" -type f -name 'pre-deinstall' -print 2>/dev/null | LC_ALL=C sort | sed -n '1p' || true)"
		if [ -n "$found" ]; then
			assert_packaged_body_contract "$found" "APK payload pre-deinstall $found"
			return 0
		fi
		echo 'fwlive-package-lifecycle artifact note: APK payload extract has no pre-deinstall (apk extract ships data files; control scripts live in ADB metadata).'
		return 0
	fi
	echo 'fwlive-package-lifecycle artifact note: no FWLIVE_PAYLOAD_DIR for file-shaped pre-deinstall.'
}

# Back-compat name used by the synthetic payload-dir cases below.
inspect_apk_artifact() {
	inspect_apk_payload_dir
}

apk_write_script_from_json() {
	local json="$1"
	local name="$2"
	local dest="$3"
	command -v python3 >/dev/null 2>&1 || fail 'python3 is required to parse apk adbdump JSON'
	python3 - "$json" "$name" "$dest" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
scripts = data.get("scripts") or {}
body = scripts.get(sys.argv[2])
if not isinstance(body, str) or not body.strip():
	sys.exit(1)
pathlib.Path(sys.argv[3]).write_text(body)
PY
}

extract_apk_package_prerm_body() {
	local src="$1"
	local dest="$2"
	awk '
		$0 == "default_prerm" || $0 ~ /^default_prerm([[:space:]]|$)/ { take=1; next }
		take { print }
	' "$src" >"$dest"
	[ -s "$dest" ]
}

assert_apk_adbdump_json() {
	local json="$1"
	local dest="$WORK/apk-adbdump"
	local body="$dest/package-prerm"
	rm -rf "$dest"
	mkdir -p "$dest"
	[ -f "$json" ] || fail "apk adbdump JSON not found: $json"
	apk_write_script_from_json "$json" pre-deinstall "$dest/pre-deinstall" ||
		fail "apk adbdump JSON missing scripts.pre-deinstall: $json"
	apk_write_script_from_json "$json" post-upgrade "$dest/post-upgrade" ||
		fail "apk adbdump JSON missing scripts.post-upgrade: $json"
	assert_packaged_body_contract "$dest/pre-deinstall" "apk adbdump pre-deinstall"
	grep -Fq 'restore_wan_log_baseline' "$dest/pre-deinstall" ||
		fail "apk adbdump pre-deinstall lacks restore_wan_log_baseline"
	grep -Eq 'PKG_UPGRADE=1' "$dest/post-upgrade" ||
		fail "apk adbdump post-upgrade lacks PKG_UPGRADE=1"
	if grep -Fq 'restore_wan_log_baseline' "$dest/post-upgrade"; then
		fail "apk adbdump post-upgrade must not restore the WAN log baseline"
	fi
	ok "apk adbdump JSON has pre-deinstall hook and post-upgrade PKG_UPGRADE=1"
	extract_apk_package_prerm_body "$dest/pre-deinstall" "$body" ||
		fail "apk adbdump pre-deinstall has no package prerm after default_prerm"
	install_hook_from_body "$body" "$dest/hook"
	HOOK="$dest/hook"
	run_lifecycle_matrix apk-adbdump
	ok "apk adbdump pre-deinstall body executed the lifecycle matrix"
}

inspect_apk_package() {
	local pkg="$1"
	local json="$WORK/adbdump.json"
	if [ -n "${FWLIVE_ADBDUMP_JSON:-}" ]; then
		[ -f "$FWLIVE_ADBDUMP_JSON" ] || fail "FWLIVE_ADBDUMP_JSON not found: $FWLIVE_ADBDUMP_JSON"
		cp "$FWLIVE_ADBDUMP_JSON" "$json"
	else
		sdk_apk_adbdump --format json "$pkg" >"$json" ||
			fail "pinned SDK apk adbdump failed for $pkg"
	fi
	assert_apk_adbdump_json "$json"
	echo "fwlive-package-lifecycle artifact OK: APK adbdump pre-deinstall executed the lifecycle matrix"
}

run_lifecycle_matrix makefile
run_wrapper_hop "$HOOK"

# Positive synthetic IPK: new body must pass extract + matrix.
pack_synthetic_ipk "$WORK/new.ipk" "$HOOK_RAW"
oracle_ipk "$WORK/new.ipk" synthetic-new-ipk
ok 'synthetic IPK with the current prerm body passes the packaged oracle'

# Negative synthetic IPK: always-restore must fail the execute matrix.
always_restore="$WORK/always-restore-prerm-pkg"
cat >"$always_restore" <<'EOF'
#!/bin/sh
case "${IPKG_INSTROOT}" in
	''|/) ;;
	*) exit 0 ;;
esac
. /usr/libexec/fwlive-logging.sh
restore_wan_log_baseline || logger -t fwlive "WAN log baseline restore failed during uninstall"
exit 0
EOF
pack_synthetic_ipk "$WORK/old-always.ipk" "$always_restore"
rm -rf "$WORK/old-always-extract"
extract_ipk_prerm "$WORK/old-always.ipk" "$WORK/old-always-extract"
packaged_body_contract_ok "$WORK/old-always-extract/prerm-pkg" &&
	fail 'always-restore body must fail the packaged-body contract'
install_hook_from_body "$WORK/old-always-extract/prerm-pkg" "$WORK/old-always-hook"
HOOK="$WORK/old-always-hook"
if (
	fail() { echo "oracle reject: $*" >&2; exit 1; }
	ok() { :; }
	run_lifecycle_matrix always-restore
); then
	fail 'always-restore packaged body must fail the lifecycle matrix'
fi
ok 'synthetic IPK with the always-restore body fails the packaged oracle'

# Negative: v0.1.44 `[ "$1" = "remove" ] || exit 0` form.
old_remove="$WORK/old-remove-prerm-pkg"
cat >"$old_remove" <<'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
[ "$1" = "remove" ] || exit 0
. /usr/libexec/fwlive-logging.sh
restore_wan_log_baseline || logger -t fwlive "WAN log baseline restore failed during uninstall"
exit 0
EOF
pack_synthetic_ipk "$WORK/old-remove.ipk" "$old_remove"
rm -rf "$WORK/old-remove-extract"
extract_ipk_prerm "$WORK/old-remove.ipk" "$WORK/old-remove-extract"
packaged_body_contract_ok "$WORK/old-remove-extract/prerm-pkg" &&
	fail 'old $1=remove body must fail the packaged-body contract'
install_hook_from_body "$WORK/old-remove-extract/prerm-pkg" "$WORK/old-remove-hook"
HOOK="$WORK/old-remove-hook"
if (
	fail() { echo "oracle reject: $*" >&2; exit 1; }
	ok() { :; }
	run_lifecycle_matrix old-dollar1-remove
); then
	fail 'old $1=remove packaged body must fail the lifecycle matrix'
fi
ok 'synthetic IPK with the old $1=remove body fails the packaged oracle'

# APK payload extract: require PKG_UPGRADE and $2/remove, not only restore_wan_log_baseline.
apk_bad="$WORK/apk-payload-bad"
mkdir -p "$apk_bad"
printf '%s\n' 'restore_wan_log_baseline' >"$apk_bad/pre-deinstall"
if (
	fail() { echo "oracle reject: $*" >&2; exit 1; }
	ok() { :; }
	FWLIVE_PAYLOAD_DIR="$apk_bad" inspect_apk_artifact
); then
	fail 'restore-only APK pre-deinstall must fail the control-script contract'
fi
ok 'APK payload restore-only pre-deinstall fails the control-script contract'
apk_good="$WORK/apk-payload-good"
mkdir -p "$apk_good"
cat >"$apk_good/pre-deinstall" <<'EOF'
[ "${PKG_UPGRADE:-}" = 1 ] && exit 0
case "${2-}" in
	remove) ;;
esac
restore_wan_log_baseline
EOF
FWLIVE_PAYLOAD_DIR="$apk_good" inspect_apk_artifact

# CI apk extract is data files; fwlive-logging.sh mentions restore_wan_log_baseline
# but is not pre-deinstall.
apk_data="$WORK/apk-payload-data"
mkdir -p "$apk_data/usr/libexec"
cat >"$apk_data/usr/libexec/fwlive-logging.sh" <<'EOF'
restore_wan_log_baseline() { :; }
EOF
FWLIVE_PAYLOAD_DIR="$apk_data" inspect_apk_artifact
ok 'APK data-only payload extract skips hook execute (logging.sh is not pre-deinstall)'

# Real control metadata is ADB JSON from pinned SDK `apk adbdump --format json`.
assert_apk_adbdump_json "$ROOT/tests/fixtures/apk-adbdump-control.json"
ok 'committed apk adbdump fixture passes the control-script contract'

python3 - "$HOOK_RAW" "$WORK/generated-adbdump.json" <<'PY'
import json
import pathlib
import sys

body = pathlib.Path(sys.argv[1]).read_text()
wrapped = (
	"#!/bin/sh\n"
	"[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0\n"
	". ${IPKG_INSTROOT}/lib/functions.sh\n"
	'export root="${IPKG_INSTROOT}"\n'
	'export pkgname="luci-app-fwlive"\n'
	"default_prerm\n"
	+ body
)
post = "#!/bin/sh\nexport PKG_UPGRADE=1\ndefault_postinst\n"
pathlib.Path(sys.argv[2]).write_text(
	json.dumps(
		{
			"info": {"name": "luci-app-fwlive"},
			"scripts": {"pre-deinstall": wrapped, "post-upgrade": post},
		}
	)
)
PY
assert_apk_adbdump_json "$WORK/generated-adbdump.json"
ok 'current Makefile prerm wrapped as apk adbdump JSON executes the lifecycle matrix'

apk_json_bad="$WORK/adbdump-restore-only.json"
python3 - "$apk_json_bad" <<'PY'
import json
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(
	json.dumps(
		{
			"scripts": {
				"pre-deinstall": "restore_wan_log_baseline\n",
				"post-upgrade": "#!/bin/sh\nexport PKG_UPGRADE=1\n",
			}
		}
	)
)
PY
if (
	fail() { echo "oracle reject: $*" >&2; exit 1; }
	ok() { :; }
	assert_apk_adbdump_json "$apk_json_bad"
); then
	fail 'restore-only apk adbdump pre-deinstall must fail the control-script contract'
fi
ok 'restore-only apk adbdump JSON fails the control-script contract'

python3 - "$ROOT/tests/fixtures/apk-adbdump-control.json" "$WORK/adbdump-upgrade-restore.json" <<'PY'
import json
import pathlib
import sys

data = json.loads(pathlib.Path(sys.argv[1]).read_text())
data["scripts"]["post-upgrade"] = (
	"#!/bin/sh\nexport PKG_UPGRADE=1\nrestore_wan_log_baseline\n"
)
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
PY
if (
	fail() { echo "oracle reject: $*" >&2; exit 1; }
	ok() { :; }
	assert_apk_adbdump_json "$WORK/adbdump-upgrade-restore.json"
); then
	fail 'apk adbdump post-upgrade must not restore the baseline'
fi
ok 'apk adbdump post-upgrade restore fails the control-script contract'

PKG="${FWLIVE_PACKAGE:-${FWLIVE_IPK:-}}"
if [ -z "$PKG" ]; then
	PKG="$(find "$ROOT/out" -type f -path '*/fwlive/*' \
		-name "luci-app-fwlive_$(sed -n 's/^PKG_VERSION:=//p' "$MAKEFILE")*.ipk" \
		-print 2>/dev/null | LC_ALL=C sort | tail -n 1 || true)"
fi
if [ -n "$PKG" ]; then
	case "$PKG" in
		*.ipk)
			oracle_ipk "$PKG" packaged-ipk
			echo 'fwlive-package-lifecycle artifact OK: generated IPK prerm-pkg executed the lifecycle matrix'
			;;
		*.apk)
			inspect_apk_package "$PKG"
			;;
		*)
			fail "unsupported package: $PKG"
			;;
	esac
elif [ "${FWLIVE_REQUIRE_PACKAGE:-0}" = 1 ]; then
	fail 'no current package artifact found'
fi

echo 'fwlive package lifecycle test passed'
