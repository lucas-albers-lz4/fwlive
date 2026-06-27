#!/usr/bin/env bash
# Guard: GitHub Release assets need unique basenames (one ipk per OpenWrt line).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"

assert_eq() {
	local got="$1" want="$2" msg="$3"
	if [[ "$got" != "$want" ]]; then
		echo "FAIL: $msg (got '$got', want '$want')" >&2
		exit 1
	fi
}

assert_eq "$(feed_publish_release_asset_basename \
	"${ROOT}/out/x86_64/21.02.7/fwlive/luci-app-fwlive_0.1.16_all.ipk")" \
	"luci-app-fwlive_0.1.16_21.02_all.ipk" \
	"21.02 ipk suffix"

assert_eq "$(feed_publish_release_asset_basename \
	"${ROOT}/out/x86_64/22.03.7/fwlive/luci-app-fwlive_0.1.16_all.ipk")" \
	"luci-app-fwlive_0.1.16_22.03_all.ipk" \
	"22.03 ipk suffix"

assert_eq "$(feed_publish_release_asset_basename \
	"${ROOT}/out/x86_64/23.05.5/fwlive/luci-app-fwlive_0.1.16_all.ipk")" \
	"luci-app-fwlive_0.1.16_23.05_all.ipk" \
	"23.05 ipk suffix"

assert_eq "$(feed_publish_release_asset_basename \
	"${ROOT}/out/x86_64/25.12.0/fwlive/luci-app-fwlive-0.1.16-r1.apk")" \
	"luci-app-fwlive-0.1.16-r1.apk" \
	"apk unchanged"

fixture="$(mktemp -d)"
staging="$(mktemp -d)"
trap 'rm -rf "$fixture" "$staging"' EXIT
export FEED_PUBLISH_ROOT="$fixture"
mkdir -p "${fixture}/out/x86_64"/{21.02.7,22.03.7,23.05.5}/fwlive
echo ipk21 > "${fixture}/out/x86_64/21.02.7/fwlive/luci-app-fwlive_0.1.16_all.ipk"
echo ipk22 > "${fixture}/out/x86_64/22.03.7/fwlive/luci-app-fwlive_0.1.16_all.ipk"
echo ipk23 > "${fixture}/out/x86_64/23.05.5/fwlive/luci-app-fwlive_0.1.16_all.ipk"
feed_publish_stage_release_assets "$staging"
test -f "$staging/luci-app-fwlive_0.1.16_21.02_all.ipk"
test -f "$staging/luci-app-fwlive_0.1.16_22.03_all.ipk"
test -f "$staging/luci-app-fwlive_0.1.16_23.05_all.ipk"

echo "feed-publish release asset tests passed"
