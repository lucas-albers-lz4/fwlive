#!/usr/bin/env bash
# Register fwview feed and install luci-app-fwlive inside the SDK in the Docker volume.
# Uses /work/fwview/openwrt-feed (repo mounted read-only in compose).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

docker compose run --rm sdk-legacy sh -ec '
	cd /openwrt-sdk
	test -f Makefile
	if [ -f feeds.conf.default ] && ! grep -q "^src-git.*base" feeds.conf 2>/dev/null; then
		cp feeds.conf.default feeds.conf
	fi
	./scripts/feeds update base luci packages
	./scripts/feeds install -p base liblua libucode libubox libubus libuci rpcd
	./scripts/feeds install luci-base
	if ! grep -q "^src-link fwview" feeds.conf 2>/dev/null; then
		echo "src-link fwview /work/fwview/openwrt-feed" >> feeds.conf
	fi
	./scripts/feeds update fwview
	./scripts/feeds install luci-app-fwlive
	# Avoid stale generated deps confusing make (can trigger ".packagedeps: unterminated variable reference").
	rm -rf tmp
	make defconfig
'

echo "Feeds ready. Build with: ./scripts/docker-sdk-make.sh" >&2
