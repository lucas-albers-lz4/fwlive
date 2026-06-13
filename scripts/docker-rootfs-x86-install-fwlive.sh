#!/usr/bin/env bash
# Install luci-app-fwlive .apk into the running owrt-x64-exp container.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${OWRT_CONTAINER:-owrt-x64-exp}"
APK="${1:-}"

if [[ -z "$APK" ]]; then
	shopt -s nullglob
	# Prefer x86_64 builds for the x86 rootfs experiment; fall back to legacy flat paths.
	candidates=(
		"$ROOT"/out/x86_64/snapshot/fwlive/luci-app-fwlive-*.apk
		"$ROOT"/out/x86_64/*/fwlive/luci-app-fwlive-*.apk
		"$ROOT"/out/x86_64/fwlive/luci-app-fwlive-*.apk
		"$ROOT"/out/aarch64_generic/snapshot/fwlive/luci-app-fwlive-*.apk
		"$ROOT"/out/aarch64_generic/fwlive/luci-app-fwlive-*.apk
	)
	shopt -u nullglob
	[[ ${#candidates[@]} -ge 1 ]] || {
		echo "usage: $0 [path/to/luci-app-fwlive.apk]" >&2
		echo "Build x86 package: ./scripts/docker-sdk.sh build --target x86-64" >&2
		exit 1
	}
	APK="${candidates[0]}"
fi
[[ -f "$APK" ]] || { echo "apk not found: $APK" >&2; exit 1; }

docker inspect "$CONTAINER" >/dev/null 2>&1 || {
	echo "container $CONTAINER not running — start: ./scripts/run-openwrt-x86-experiment.sh" >&2
	exit 1
}

# /tmp is volatile on OpenWrt; /root persists for docker cp.
docker cp "$APK" "${CONTAINER}:/root/luci-app-fwlive.apk"
docker exec "$CONTAINER" apk add --allow-untrusted /root/luci-app-fwlive.apk

# Dev override: feed may be ahead of the last SDK-built .apk (e.g. inlined parser).
FWLIVE_DIR="$ROOT/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources"
if [[ -f "$FWLIVE_DIR/view/status/fwlive.js" ]]; then
	docker cp "$FWLIVE_DIR/view/status/fwlive.js" "${CONTAINER}:/www/luci-static/resources/view/status/fwlive.js"
	docker cp "$FWLIVE_DIR/fwlive/log.js" "${CONTAINER}:/www/luci-static/resources/fwlive/log.js"
	docker exec "$CONTAINER" rm -f /www/luci-static/resources/fwlive/parser.js
fi

echo "LuCI → Status → Firewall Live View" >&2
echo "http://127.0.0.1:8080/cgi-bin/luci/admin/status/fwlive" >&2
echo "If you still see a fwlive.parser error, clear site data for localhost:8080" >&2
echo "(LuCI keeps the same ?v= URL; hard refresh may not reload cached JS)." >&2
