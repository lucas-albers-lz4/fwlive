#!/usr/bin/env bash
# Exercise the packaged prerm action contract without requiring an SDK or root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$ROOT/openwrt-feed/luci-app-fwlive/Makefile"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

HOOK="$WORK/prerm"
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
' "$MAKEFILE" |
	sed "s|^\. /usr/libexec/fwlive-logging\\.sh$|. $HELPER|" >"$HOOK"
chmod 755 "$HOOK"

PKG="${FWLIVE_PACKAGE:-${FWLIVE_IPK:-}}"
if [ -z "$PKG" ]; then
	PKG="$(find "$ROOT/out" -type f -path '*/fwlive/*' \
		-name "luci-app-fwlive_$(sed -n 's/^PKG_VERSION:=//p' "$MAKEFILE")*.ipk" \
		-print 2>/dev/null | LC_ALL=C sort | tail -n 1 || true)"
fi
if [ -n "$PKG" ]; then
	case "$PKG" in
		*.ipk)
			CONTROL="$WORK/control.tar.gz"
			if tar -xzOf "$PKG" ./control.tar.gz >"$CONTROL" 2>/dev/null; then
				:
			elif tar -xOf "$PKG" ./control.tar.gz >"$CONTROL" 2>/dev/null; then
				:
			elif ar p "$PKG" control.tar.gz >"$CONTROL" 2>/dev/null; then
				:
			else
				echo 'fwlive-package-lifecycle test FAIL: could not extract IPK control archive' >&2
				exit 1
			fi
			tar -tzf "$CONTROL" | grep -qx './prerm'
			tar -tzf "$CONTROL" | grep -qx './prerm-pkg'
			tar -xzOf "$CONTROL" ./prerm >"$WORK/ipk-prerm"
			tar -xzOf "$CONTROL" ./prerm-pkg >"$WORK/ipk-prerm-pkg"
			grep -Fq 'default_prerm $0 $@' "$WORK/ipk-prerm"
			grep -Fq 'restore_wan_log_baseline' "$WORK/ipk-prerm-pkg"
			echo 'fwlive-package-lifecycle artifact OK: generated IPK carries wrapper and prerm body'
			;;
		*.apk)
			echo 'fwlive-package-lifecycle artifact note: APK control is verified in the OpenWrt QEMU cell'
			;;
		*)
			echo "fwlive-package-lifecycle test FAIL: unsupported package: $PKG" >&2
			exit 1
			;;
	esac
elif [ "${FWLIVE_REQUIRE_PACKAGE:-0}" = 1 ]; then
	echo 'fwlive-package-lifecycle test FAIL: no current package artifact found' >&2
	exit 1
fi

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

run_hook remove
assert_restored remove
ok 'explicit remove restores the baseline'

run_hook upgrade
assert_not_restored upgrade
ok 'direct upgrade preserves the baseline'

run_hook __empty__
assert_not_restored empty
ok 'empty action fails closed without restoring the baseline'

run_hook unexpected
assert_not_restored unexpected
ok 'unknown package action fails closed without restoring'

run_hook 123
assert_not_restored numeric-action
ok 'numeric non-version action fails closed without restoring'

run_opkg_hook remove
assert_restored opkg-remove
ok 'generated opkg wrapper remove restores the baseline'

run_opkg_hook upgrade
assert_not_restored opkg-upgrade
ok 'generated opkg wrapper upgrade preserves the baseline'

run_opkg_hook __empty__
assert_not_restored opkg-empty
ok 'generated opkg wrapper with no action fails closed'

run_apk_uninstall_hook
assert_restored apk-uninstall
ok 'APK version-valued uninstall restores the baseline'

rm -f "$MARKER"
if IPKG_INSTROOT="$WORK/staging" FWLIVE_PRERM_MARKER="$MARKER" PATH="$BIN:$PATH" "$HOOK" remove; then
	:
else
	fail 'non-root staging invocation must succeed'
fi
assert_not_restored staging
ok 'non-root staging invocation skips runtime helpers'

rm -f "$MARKER"
if IPKG_INSTROOT=/ FWLIVE_PRERM_MARKER="$MARKER" FWLIVE_RESTORE_RC=1 PATH="$BIN:$PATH" "$HOOK" remove; then
	:
else
	fail 'restore failure must not fail package removal'
fi
assert_restored restore-failure
ok 'restore failure remains best-effort and keeps the removal hook successful'

echo 'fwlive package lifecycle test passed'
