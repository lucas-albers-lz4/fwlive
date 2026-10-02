#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
mkdir -p "$TMP/ipk/data/usr/libexec" "$TMP/ipk/ctrl"
printf '# fixture helper\n' > "$TMP/ipk/data/usr/libexec/fwlive-logging.sh"
printf 'Package: luci-app-fwlive\nVersion: 0.1.49-r1\n' > "$TMP/ipk/ctrl/control"
tar -C "$TMP/ipk/data" -czf "$TMP/ipk/data.tar.gz" .
tar -C "$TMP/ipk/ctrl" -czf "$TMP/ipk/control.tar.gz" ./control
tar -C "$TMP/ipk" -czf "$TMP/fake.ipk" data.tar.gz control.tar.gz
touch "$TMP/fake.apk"

# Matrix wiring: --artifact-only must live in the install helper, not a comment elsewhere.
install_fn="$(sed -n '/^validate_matrix_install_ipk()/,/^}/p' \
	"$ROOT/scripts/lib/validate-matrix.sh")"
printf '%s\n' "$install_fn" | grep -Fq -- '--artifact-only'

cat >"$TMP/bin/scp" <<'EOF'
#!/bin/sh
printf 'scp %s\n' "$*" >>"$FWLIVE_STUB_LOG"
exit 0
EOF

cat >"$TMP/bin/ssh" <<'EOF'
#!/bin/sh
last=''
for arg do last="$arg"; done
printf 'ssh %s\n' "$last" >>"$FWLIVE_STUB_LOG"
case "$last" in
	'uname -m') printf 'x86_64\n' ;;
	*'command -v apk >/dev/null'*) exit 1 ;;
	*'rm -f /www/luci-static/resources/view/status/fwlive.js'*)
		# Model the installed prerm dependency rather than merely logging SSH.
		rm -f "$FWLIVE_STUB_HELPER"; exit 0 ;;
	*'opkg install --force-reinstall '*)
		/bin/sh -c '. "$FWLIVE_STUB_HELPER"' || exit 2
		exit 0 ;;
	*'opkg install /tmp/'*) exit 0 ;;
	*'apk add --allow-untrusted --force-reinstall '*) exit 0 ;;
	*'test -x /usr/libexec/rpcd/fwlive'*) exit "${FWLIVE_STUB_PAYLOAD_RC:-0}" ;;
	'opkg status luci-app-fwlive') printf 'Version: %s\nStatus: install user installed\n' "${FWLIVE_STUB_VERSION:-0.1.49-r1}" ;;
	'sha256sum -c -') cat > "$FWLIVE_STUB_LOG.manifest"; exit "${FWLIVE_STUB_HASH_RC:-0}" ;;
	'apk info -e luci-app-fwlive') exit 0 ;;
	*'ubus -v list fwlive'*) exit "${FWLIVE_STUB_RPC_RC:-0}" ;;
	*'mkdir -p /www/luci-static/resources/'*) exit 0 ;;
	*'mkdir -p /usr/libexec'*) exit 0 ;;
	*'cat > /www/luci-static/resources/'*) exit 0 ;;
	*'cat > /usr/libexec/'*) exit 0 ;;
	*'cat > /usr/share/'*) exit 0 ;;
	*'/etc/init.d/rpcd restart'*) exit 0 ;;
	*'rm -f /tmp/luci-indexcache; /etc/init.d/uhttpd restart'*) exit 0 ;;
	*'rm -f /www/luci-static/resources/fwlive/parser.js'*) exit 0 ;;
	*) echo "unexpected remote command: $last" >&2; exit 1 ;;
esac
EOF
chmod 755 "$TMP/bin/scp" "$TMP/bin/ssh"

run_install() {
	FWLIVE_STUB_LOG="$1" \
	FWLIVE_STUB_HELPER="$TMP/ipk/data/usr/libexec/fwlive-logging.sh" \
	PATH="$TMP/bin:$PATH" \
	OPENWRT_HOST=127.0.0.1 \
	OPENWRT_SSH_PORT=2222 \
	OPENWRT_USER=root \
	"$ROOT/scripts/qemu-install-fwlive.sh" "${@:2}" >/dev/null
}

run_install "$TMP/artifact.log" --artifact-only "$TMP/fake.ipk"

if grep -Fq 'rm -f /www/luci-static/resources/view/status/fwlive.js' "$TMP/artifact.log"; then echo 'preinstall wipe breaks prerm' >&2; exit 1; fi
grep -Fq 'opkg install --force-reinstall' "$TMP/artifact.log"
if grep -Eq 'cat > /www/|cat > /usr/libexec/|mkdir -p /www' "$TMP/artifact.log"; then
	echo 'artifact-only install unexpectedly synced source files' >&2
	exit 1
fi

run_install "$TMP/apk-artifact.log" --artifact-only "$TMP/fake.apk"

if grep -Fq 'rm -f /www/luci-static/resources/view/status/fwlive.js' "$TMP/apk-artifact.log"; then echo 'APK must preserve installed payload during transition' >&2; exit 1; fi
grep -Fq 'apk add --allow-untrusted --force-reinstall' "$TMP/apk-artifact.log"
if grep -Eq 'cat > /www/|cat > /usr/libexec/|mkdir -p /www' "$TMP/apk-artifact.log"; then
	echo 'artifact-only APK install unexpectedly synced source files' >&2
	exit 1
fi

run_install "$TMP/default.log" "$TMP/fake.ipk"

grep -Eq 'cat > /www/luci-static/resources/view/status/fwlive.js' "$TMP/default.log"
if grep -Fq 'opkg install --force-reinstall' "$TMP/default.log"; then
	echo 'default install unexpectedly force-reinstalled' >&2
	exit 1
fi
if grep -Fq 'rm -f /www/luci-static/resources/view/status/fwlive.js' "$TMP/default.log"; then
	echo 'default install unexpectedly wiped overlay files before install' >&2
	exit 1
fi

# Repeat the same-version transition, keeping installed prerm usable both times.
run_install "$TMP/artifact-repeat.log" --artifact-only "$TMP/fake.ipk"
grep -Fq '/usr/libexec/fwlive-logging.sh' "$TMP/artifact.log.manifest"
for failure in payload hash rpc version; do
	case "$failure" in
		payload) export FWLIVE_STUB_PAYLOAD_RC=1 ;;
		hash) export FWLIVE_STUB_HASH_RC=1 ;;
		rpc) export FWLIVE_STUB_RPC_RC=1 ;;
		version) export FWLIVE_STUB_VERSION=wrong ;;
	esac
	if run_install "$TMP/fail-$failure.log" --artifact-only "$TMP/fake.ipk" 2>/dev/null; then
		echo "artifact verification $failure unexpectedly passed" >&2; exit 1
	fi
	unset FWLIVE_STUB_PAYLOAD_RC FWLIVE_STUB_HASH_RC FWLIVE_STUB_RPC_RC FWLIVE_STUB_VERSION
done
echo 'qemu install artifact-only mode test passed (host transition/verification fixtures)'
