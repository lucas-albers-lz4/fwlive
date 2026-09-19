#!/usr/bin/env bash
# Real apk artifacts require FWLIVE_PAYLOAD_DIR. Host `apk` must not extract.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$ROOT/openwrt-feed/luci-app-fwlive/Makefile")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PKG="$WORK/luci-app-fwlive-${VERSION}-r1.apk"
: >"$PKG"

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/apk" <<'EOF'
#!/bin/sh
echo "decoy apk invoked" >&2
echo decoy > "$(dirname "$0")/../apk-invoked"
exit 0
EOF
chmod +x "$FAKE_BIN/apk"

set +e
out="$(
	PATH="$FAKE_BIN:$PATH" \
		FWLIVE_PACKAGE="$PKG" \
		bash "$ROOT/tests/fwlive-package-payload.test.sh" 2>&1
)"
status=$?
set -e

[ "$status" -ne 0 ] || {
	echo "expected apk without FWLIVE_PAYLOAD_DIR to fail" >&2
	printf '%s\n' "$out" >&2
	exit 1
}
printf '%s\n' "$out" | grep -q FWLIVE_PAYLOAD_DIR || {
	echo "expected FWLIVE_PAYLOAD_DIR in error" >&2
	printf '%s\n' "$out" >&2
	exit 1
}
[ ! -e "$WORK/apk-invoked" ] || {
	echo "host apk was invoked" >&2
	exit 1
}

echo "fwlive apk payload host-apk refusal test passed"
