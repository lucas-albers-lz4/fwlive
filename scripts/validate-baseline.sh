#!/usr/bin/env bash
# Gate before matrix validation: confirm parser tests and key scripts are healthy.
#
#   ./scripts/validate-baseline.sh
#   ./scripts/validate-baseline.sh --with-smoke   # also run qemu-smoke if guest is up
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_SMOKE=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--with-smoke) WITH_SMOKE=1; shift ;;
		-h|--help)
			sed -n '1,8p' "$0"
			exit 0
			;;
		*) echo "unknown arg: $1" >&2; exit 1 ;;
	esac
done

echo "== validate baseline ==" >&2

required=(
	scripts/fwlive-test.sh
	scripts/docker-sdk.sh
	scripts/lib/sdk-matrix.sh
	scripts/lib/feed-publish.sh
	scripts/lib/validate-matrix.sh
	scripts/verify-reproducible-build.sh
	scripts/publish-packages.sh
	scripts/qemu-install-from-feed.sh
	scripts/validate-feed-smoke.sh
	scripts/wait-feed-pages.sh
	scripts/feeds.lock/23.05.5/feeds.conf
	scripts/feeds.lock/22.03.7/feeds.conf
	scripts/feeds.lock/21.02.7/feeds.conf
	scripts/feeds.lock/24.10.8/feeds.conf
	scripts/feeds.lock/25.12.5/feeds.conf
	scripts/qemu-smoke-fwlive.sh
	scripts/qemu-install-fwlive.sh
	scripts/qemu-lab-prepare-image.sh
	scripts/qemu-wait-guest.sh
	scripts/download-openwrt-x86-64.sh
	scripts/download-openwrt-armsr-armv8.sh
	scripts/run-openwrt-x86-qemu.sh
	scripts/run-openwrt-armsr-armv8-qemu.sh
	core/fwlive-log.js
	openwrt-feed/luci-app-fwlive/Makefile
	.github/workflows/publish-packages.yml
	docs/binary-feed.md
)

for f in "${required[@]}"; do
	[[ -e "${ROOT}/${f}" ]] || { echo "baseline FAIL: missing ${f}" >&2; exit 1; }
done
echo "baseline OK: required paths present" >&2

"${ROOT}/scripts/fwlive-test.sh"

echo "baseline OK: parser tests" >&2
"${ROOT}/scripts/docker-sdk.sh" list >/dev/null
echo "baseline OK: SDK matrix list" >&2

if [[ "$WITH_SMOKE" -eq 1 ]]; then
	if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ConnectTimeout=3 -p "${OPENWRT_SSH_PORT:-2222}" root@127.0.0.1 'echo up' 2>/dev/null; then
		"${ROOT}/scripts/qemu-smoke-fwlive.sh"
		echo "baseline OK: live smoke" >&2
	else
		echo "baseline SKIP: no QEMU guest on port ${OPENWRT_SSH_PORT:-2222} (--with-smoke)" >&2
	fi
fi

echo "== baseline passed ==" >&2
