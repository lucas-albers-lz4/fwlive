#!/usr/bin/env bash
# Install luci-app-fwlive on a QEMU guest from a published GitHub Pages feed URL.
#
#   FWLIVE_FEED_BASE_URL=https://lucas-albers-lz4.github.io/fwlive-packages \
#     ./scripts/qemu-install-from-feed.sh --version 24.10
#
# Prereqs: QEMU guest up (run-openwrt-x86-qemu.sh), SSH on port 2222.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sdk-matrix.sh
source "${ROOT}/scripts/lib/sdk-matrix.sh"
# shellcheck source=lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"
# shellcheck source=lib/feed-index-version.sh
source "${ROOT}/scripts/lib/feed-index-version.sh"

OPENWRT_HOST="${OPENWRT_HOST:-127.0.0.1}"
OPENWRT_SSH_PORT="${OPENWRT_SSH_PORT:-2222}"
OPENWRT_USER="${OPENWRT_USER:-root}"
FWLIVE_FEED_BASE_URL="${FWLIVE_FEED_BASE_URL:?set FWLIVE_FEED_BASE_URL (GitHub Pages base, no trailing slash)}"
VERSION="${OWRT_FWLIVE_VERSION:-24.10}"
RUN_SMOKE=1

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

usage() {
	cat <<EOF
Usage: qemu-install-from-feed.sh [options]

Options:
  --version VERSION   23.05 | 24.10 | 25.12 (default: 24.10)
  --no-smoke          skip qemu-smoke-fwlive.sh after install
  -h, --help

Environment:
  FWLIVE_FEED_BASE_URL   e.g. https://lucas-albers-lz4.github.io/fwlive-packages
  OPKG_FEED_PUBLIC_KEY_URL  override opkg public key URL (default: \${BASE}/public.key)
  APK_FEED_PUBLIC_KEY_URL   override apk public key URL (default: \${BASE}/fwlive-feed.rsa.pub)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) VERSION="${2:?}"; shift 2 ;;
		--no-smoke) RUN_SMOKE=0; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "unknown arg: $1" >&2; usage >&2; exit 1 ;;
	esac
done

sdk_matrix_validate_version "$VERSION"
feed_dir="$(feed_publish_feed_dir "$VERSION")"
base="${FWLIVE_FEED_BASE_URL%/}"
opkg_key_url="${OPKG_FEED_PUBLIC_KEY_URL:-${base}/public.key}"
apk_key_url="${APK_FEED_PUBLIC_KEY_URL:-${base}/fwlive-feed.rsa.pub}"

ssh_run() {
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" "$@"
}

guest_uses_apk() {
	ssh_run 'command -v apk >/dev/null 2>&1'
}

install_opkg() {
	local feed_url="${base}/${feed_dir}"
	echo "→ opkg feed ${feed_url}" >&2
	ssh_run "wget -O /tmp/fwlive-feed.key '${opkg_key_url}'"
	ssh_run 'opkg-key add /tmp/fwlive-feed.key'
	ssh_run "grep -q 'src/gz fwlive ${feed_url}' /etc/opkg/customfeeds.conf 2>/dev/null || \
		echo 'src/gz fwlive ${feed_url}' >> /etc/opkg/customfeeds.conf"
	ssh_run 'opkg update'
	ssh_run 'opkg install luci-app-fwlive'
}

install_apk() {
	local index_url="${base}/${feed_dir}/all/packages.adb"
	echo "→ apk index ${index_url}" >&2
	ssh_run "wget -O /tmp/fwlive-feed.rsa.pub '${apk_key_url}'"
	ssh_run 'mkdir -p /etc/apk/keys'
	ssh_run 'cp /tmp/fwlive-feed.rsa.pub /etc/apk/keys/fwlive-feed.rsa.pub'
	ssh_run "grep -qF '${index_url}' /etc/apk/repositories.d/fwlive.list 2>/dev/null || \
		echo '${index_url}' >> /etc/apk/repositories.d/fwlive.list"
	ssh_run 'apk update'
	ssh_run 'apk add luci-app-fwlive'
}

# Fetch Packages.gz / packages.adb from the same cell URL the guest uses
# (https feed or a local file:// index).
fetch_feed_index() {
	local dest="$1" url="$2"
	echo "→ fetch index ${url}" >&2
	curl -fsSL --connect-timeout 15 --max-time 60 -o "$dest" -- "$url" || {
		echo "feed-index: failed to fetch $url" >&2
		return 1
	}
	[[ -s "$dest" ]] || {
		echo "feed-index: empty index at $url" >&2
		return 1
	}
}

assert_opkg_cell() {
	local tmp="$1" want raw got
	fetch_feed_index "$tmp/Packages.gz" "${base}/${feed_dir}/Packages.gz" || return 1
	want="$(feed_index_opkg_version "$tmp/Packages.gz")" || return 1
	raw="$(ssh_run "$FEED_INDEX_GUEST_OPKG_CMD")" || return 1
	printf '%s\n' "$raw" >"$tmp/opkg-info" || return 1
	got="$(feed_index_guest_opkg_version "$tmp/opkg-info")" || return 1
	feed_index_versions_match "$got" "$want"
}

assert_apk_cell() {
	local tmp="$1" want raw got
	fetch_feed_index "$tmp/packages.adb" "${base}/${feed_dir}/all/packages.adb" || return 1
	want="$(feed_index_apk_pkgver "$tmp/packages.adb")" || return 1
	raw="$(ssh_run "$FEED_INDEX_GUEST_APK_CMD")" || return 1
	printf '%s\n' "$raw" >"$tmp/apk-query.json" || return 1
	got="$(feed_index_guest_apk_query_pkgver "$tmp/apk-query.json")" || return 1
	feed_index_versions_match "$got" "$want"
}

# Fail the smoke when the guest version does not match this cell's index.
assert_installed_matches_index() {
	local tmp rc=0 fmt
	tmp="$(mktemp -d)"
	fmt="$(sdk_matrix_package_format "$VERSION")" || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		case "$fmt" in
			ipk)
				echo "→ assert opkg info vs ${base}/${feed_dir}/Packages.gz" >&2
				assert_opkg_cell "$tmp" || rc=$?
				;;
			apk)
				echo "→ assert apk query vs ${base}/${feed_dir}/all/packages.adb" >&2
				assert_apk_cell "$tmp" || rc=$?
				;;
			*)
				echo "feed-index: unknown package format '$fmt'" >&2
				rc=1
				;;
		esac
	fi
	rm -rf "$tmp"
	return "$rc"
}

echo "Installing luci-app-fwlive from ${base} (OpenWrt ${VERSION})..." >&2

if guest_uses_apk; then
	install_apk
else
	install_opkg
fi

assert_installed_matches_index

if [[ "$RUN_SMOKE" -eq 1 ]]; then
	"${ROOT}/scripts/qemu-smoke-fwlive.sh" --require-log-pipeline
fi

echo "Feed install complete." >&2
