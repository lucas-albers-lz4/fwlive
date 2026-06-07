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
FWLIVE_VERSION="${OWRT_FWLIVE_VERSION:-}"

if [[ -z "$IPK" ]]; then
	shopt -s nullglob
	_pkg_globs() {
		local base="$1"
		printf '%s/luci-app-fwlive_*.ipk %s/luci-app-fwlive-*.apk %s/luci-app-fwlive_*.apk' "$base" "$base" "$base"
	}
	if [[ -n "$FWLIVE_VERSION" ]]; then
		shopt -s nullglob
		# Prefer guest arch when known (x86 QEMU lab vs armsr SDK default).
		arch_order=(x86_64 aarch64_generic)
		if [[ "${OWRT_FWLIVE_ARCH:-}" == aarch64_generic ]]; then
			arch_order=(aarch64_generic x86_64)
		fi
		for arch in "${arch_order[@]}"; do
			base="$ROOT/out/${arch}/${FWLIVE_VERSION}/fwview"
			# shellcheck disable=SC2086
			candidates+=( $(_pkg_globs "$base") )
		done
		shopt -u nullglob
	else
		shopt -s nullglob
		for ver in 25.12.0 24.10.5 24.10 23.05.5 23.05 snapshot; do
			for arch in x86_64 aarch64_generic; do
				base="$ROOT/out/${arch}/${ver}/fwview"
				# shellcheck disable=SC2086
				candidates+=( $(_pkg_globs "$base") )
			done
		done
		shopt -u nullglob
	fi
	shopt -u nullglob
	[[ ${#candidates[@]} -ge 1 ]] || {
		echo "No package found (.ipk/.apk). Build first:" >&2
		echo "  ./scripts/docker-sdk.sh build --target x86-64 --version 24.10" >&2
		echo "  ./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10" >&2
		echo "  ./scripts/docker-sdk.sh build --target armsr-armv8 --version 23.05" >&2
		exit 1
	}
	chosen=""
	if [[ -n "${OWRT_FWLIVE_ARCH:-}" ]]; then
		for c in "${candidates[@]}"; do
			if [[ "$c" == *"/${OWRT_FWLIVE_ARCH}/"* ]]; then
				chosen="$c"
				break
			fi
		done
	fi
	IPK="${chosen:-$(ls -t "${candidates[@]}" 2>/dev/null | head -1)}"
fi
[[ -f "$IPK" ]] || { echo "ipk not found: $IPK" >&2; exit 1; }

ARCH="$(ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" 'uname -m')"
case "$ARCH" in
	x86_64) want='x86_64' ;;
	aarch64) want='aarch64_generic' ;;
	*) echo "unsupported guest arch: $ARCH" >&2; exit 1 ;;
esac
if [[ "$IPK" != *"$want"* && "$IPK" != *"all.ipk"* && "$IPK" != *"all.apk"* ]]; then
	echo "warn: package path may not match guest arch ($ARCH): $IPK" >&2
fi

pkg_ext="${IPK##*.}"
REMOTE="/tmp/luci-app-fwlive.${pkg_ext}"
echo "Installing $IPK → ${OPENWRT_USER}@${OPENWRT_HOST}:${OPENWRT_SSH_PORT}"

# Dropbear has no sftp-server; prefer legacy scp, fall back to ssh stdin.
if scp -O -P "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "$IPK" \
	"${OPENWRT_USER}@${OPENWRT_HOST}:${REMOTE}" 2>/dev/null; then
	:
else
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"cat > ${REMOTE}" < "$IPK"
fi
if [[ "$pkg_ext" == apk ]] || ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
	'command -v apk >/dev/null'; then
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"apk add --allow-untrusted ${REMOTE} && rm -f ${REMOTE}"
else
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"opkg install ${REMOTE} && rm -f ${REMOTE}"
fi

FWLIVE_PKG="$ROOT/openwrt-feed/luci-app-fwlive"
FWLIVE_DIR="$FWLIVE_PKG/htdocs/luci-static/resources"
RPCD_BIN="$FWLIVE_PKG/root/usr/libexec/rpcd/fwlive"
LIBEXEC_FILTER="$FWLIVE_PKG/root/usr/libexec/fwlive-log-filter.sh"
LIBEXEC_ISFW="$FWLIVE_PKG/root/usr/libexec/fwlive-is-firewall-event.sh"
ACL_JSON="$FWLIVE_PKG/root/usr/share/rpcd/acl.d/luci-app-fwlive.json"
MENU_JSON="$FWLIVE_PKG/root/usr/share/luci/menu.d/luci-app-fwlive.json"
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
if [[ -f "$RPCD_BIN" ]]; then
	echo "Syncing rpcd fwlive plugin + ACL..."
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"mkdir -p /usr/libexec/rpcd /usr/libexec /usr/share/rpcd/acl.d"
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"cat > /usr/libexec/rpcd/fwlive && chmod +x /usr/libexec/rpcd/fwlive" \
		< "$RPCD_BIN"
	if [[ -f "$LIBEXEC_FILTER" ]]; then
		ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
			"cat > /usr/libexec/fwlive-log-filter.sh && chmod +x /usr/libexec/fwlive-log-filter.sh" \
			< "$LIBEXEC_FILTER"
	fi
	if [[ -f "$LIBEXEC_ISFW" ]]; then
		ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
			"cat > /usr/libexec/fwlive-is-firewall-event.sh" \
			< "$LIBEXEC_ISFW"
	fi
	if [[ -f "$ACL_JSON" ]]; then
		ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
			"cat > /usr/share/rpcd/acl.d/luci-app-fwlive.json" \
			< "$ACL_JSON"
	fi
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"/etc/init.d/rpcd restart"
fi
if [[ -f "$MENU_JSON" ]]; then
	echo "Syncing LuCI menu entry..."
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"cat > /usr/share/luci/menu.d/luci-app-fwlive.json" < "$MENU_JSON"
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" \
		"rm -f /tmp/luci-indexcache; /etc/init.d/uhttpd restart"
fi

echo ""
echo "Open: http://localhost:8080/cgi-bin/luci/admin/status/fwlive"
echo "Ping log test (slirp: host→guest ICMP often fails; generate on guest):"
echo "  ./scripts/fwlive-nft-ping-log.sh add --ssh"
echo "  ssh -p ${OPENWRT_SSH_PORT} root@${OPENWRT_HOST} 'ping -c 5 127.0.0.1'"
echo "  ./scripts/fwlive-ubus-read.sh --lines 20"
