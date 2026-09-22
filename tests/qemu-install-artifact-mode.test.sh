#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
touch "$TMP/fake.ipk"
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
	*'rm -f /www/luci-static/resources/view/status/fwlive.js'*) exit 0 ;;
	*'opkg install --force-reinstall '*) exit 0 ;;
	*'opkg install /tmp/'*) exit 0 ;;
	*'apk add --allow-untrusted --force-reinstall '*) exit 0 ;;
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
	PATH="$TMP/bin:$PATH" \
	OPENWRT_HOST=127.0.0.1 \
	OPENWRT_SSH_PORT=2222 \
	OPENWRT_USER=root \
	"$ROOT/scripts/qemu-install-fwlive.sh" "${@:2}" >/dev/null
}

run_install "$TMP/artifact.log" --artifact-only "$TMP/fake.ipk"

grep -Fq 'rm -f /www/luci-static/resources/view/status/fwlive.js' "$TMP/artifact.log"
grep -Fq 'opkg install --force-reinstall' "$TMP/artifact.log"
if grep -Eq 'cat > /www/|cat > /usr/libexec/|mkdir -p /www' "$TMP/artifact.log"; then
	echo 'artifact-only install unexpectedly synced source files' >&2
	exit 1
fi

run_install "$TMP/apk-artifact.log" --artifact-only "$TMP/fake.apk"

grep -Fq 'rm -f /www/luci-static/resources/view/status/fwlive.js' "$TMP/apk-artifact.log"
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

echo 'qemu install artifact-only mode test passed'
