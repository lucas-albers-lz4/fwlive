#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
touch "$TMP/fake.ipk"

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
	*'opkg install'*) exit 0 ;;
	*) echo "unexpected remote command in artifact-only mode: $last" >&2; exit 1 ;;
esac
EOF
chmod 755 "$TMP/bin/scp" "$TMP/bin/ssh"

grep -Fq 'qemu-install-fwlive.sh" --artifact-only' \
	"$ROOT/scripts/lib/validate-matrix.sh"

FWLIVE_STUB_LOG="$TMP/ssh.log" \
PATH="$TMP/bin:$PATH" \
OPENWRT_HOST=127.0.0.1 \
OPENWRT_SSH_PORT=2222 \
OPENWRT_USER=root \
"$ROOT/scripts/qemu-install-fwlive.sh" --artifact-only "$TMP/fake.ipk" >/dev/null

grep -Fq 'opkg install' "$TMP/ssh.log"
if grep -Eq 'cat > /|mkdir -p /www|/etc/init.d' "$TMP/ssh.log"; then
	echo 'artifact-only install unexpectedly synced source files' >&2
	exit 1
fi

echo 'qemu install artifact-only mode test passed'
