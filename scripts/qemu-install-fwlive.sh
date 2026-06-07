#!/usr/bin/env bash
# Install luci-app-fwlive on a running QEMU OpenWrt guest (hostfwd SSH).
#
#   ./scripts/qemu-install-fwlive.sh
#   ./scripts/qemu-install-fwlive.sh out/x86_64/24.10.5/fwview/luci-app-fwlive_*.ipk
#
# Prereqs: guest reachable at ssh -p 2222 root@127.0.0.1 (run-openwrt-*-qemu.sh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENWRT_HOST="${OPENWRT_HOST:-127.0.0.1}"
OPENWRT_SSH_PORT="${OPENWRT_SSH_PORT:-2222}"
OPENWRT_USER="${OPENWRT_USER:-root}"
IPK="${1:-}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

if [[ -z "$IPK" ]]; then
	shopt -s nullglob
	candidates=(
		"$ROOT"/out/x86_64/24.10.5/fwview/luci-app-fwlive_*.ipk
		"$ROOT"/out/x86_64/24.10/fwview/luci-app-fwlive_*.ipk
		"$ROOT"/out/aarch64_generic/24.10.5/fwview/luci-app-fwlive_*.ipk
		"$ROOT"/out/aarch64_generic/24.10/fwview/luci-app-fwlive_*.ipk
	)
	shopt -u nullglob
	[[ ${#candidates[@]} -ge 1 ]] || {
		echo "No .ipk found. Build first:" >&2
		echo "  ./scripts/docker-sdk.sh build --target x86-64 --version 24.10" >&2
		echo "  ./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10" >&2
		exit 1
	}
	IPK="${candidates[0]}"
fi
[[ -f "$IPK" ]] || { echo "ipk not found: $IPK" >&2; exit 1; }

ARCH="$(ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" 'uname -m')"
case "$ARCH" in
	x86_64) want='x86_64' ;;
	aarch64) want='aarch64_generic' ;;
	*) echo "unsupported guest arch: $ARCH" >&2; exit 1 ;;
esac
if [[ "$IPK" != *"$want"* && "$IPK" != *"all.ipk"* ]]; then
	echo "warn: ipk path may not match guest arch ($ARCH): $IPK" >&2
fi

REMOTE="/tmp/luci-app-fwlive.ipk"
echo "Installing $IPK → ${OPENWRT_USER}@${OPENWRT_HOST}:${OPENWRT_SSH_PORT}"

# Dropbear has no sftp-server; prefer legacy scp, fall back to ssh stdin.
if scp -O -P "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "$IPK" \
	"${OPENWRT_USER}@${OPENWRT_HOST}:${REMOTE}" 2>/dev/null; then
	:
else
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"cat > ${REMOTE}" < "$IPK"
fi
ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
	"opkg install ${REMOTE} && rm -f ${REMOTE}"

FWLIVE_DIR="$ROOT/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources"
if [[ -f "$FWLIVE_DIR/view/status/fwlive.js" ]]; then
	echo "Syncing dev JS from feed (may be ahead of .ipk)..."
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"mkdir -p /www/luci-static/resources/view/status /www/luci-static/resources/fwlive"
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"cat > /www/luci-static/resources/view/status/fwlive.js" \
		< "$FWLIVE_DIR/view/status/fwlive.js"
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"cat > /www/luci-static/resources/fwlive/log.js" \
		< "$FWLIVE_DIR/fwlive/log.js"
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"rm -f /www/luci-static/resources/fwlive/parser.js"
fi

echo ""
echo "Open: http://localhost:8080/cgi-bin/luci/admin/status/fwlive"
echo "Ping log test (slirp: host→guest ICMP often fails; generate on guest):"
echo "  ./scripts/fwlive-nft-ping-log.sh add --ssh"
echo "  ssh -p ${OPENWRT_SSH_PORT} root@${OPENWRT_HOST} 'ping -c 5 127.0.0.1'"
echo "  ./scripts/fwlive-ubus-read.sh --lines 20"
