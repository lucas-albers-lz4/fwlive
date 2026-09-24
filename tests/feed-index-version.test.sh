#!/usr/bin/env bash
# Host proof: luci-app-fwlive Version/pkgver from feed indexes (#421).
# APK path stubs docker like sdk-apk.test.sh — never host apk, no live SDK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/feed-index-version.sh
source "$ROOT/scripts/lib/feed-index-version.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
	echo "feed-index-version test FAIL: $*" >&2
	exit 1
}

ok() {
	echo "feed-index-version test OK: $*"
}

want='0.1.45-r1'
stale='0.1.44-r1'

feed_index_versions_match "$want" "$want" || fail "matching -r1 forms must succeed"
ok "matching version succeeds"

if feed_index_versions_match "$stale" "$want" >/dev/null 2>&1; then
	fail "stale version must not match"
fi
ok "stale version fails"

if feed_index_versions_match '0.1.45' "$want" >/dev/null 2>&1; then
	fail "must compare with -r1 (PKG_VERSION alone is wrong)"
fi
ok "version without -r1 fails"

if feed_index_versions_match '' "$want" >/dev/null 2>&1; then
	fail "empty form must fail closed"
fi
ok "empty version form fails"

write_packages() {
	local dest="$1"
	shift
	printf '%s\n' "$@" >"$dest"
}

write_packages "$TMP/Packages" \
	'Package: luci-base' \
	'Version: 24.10.0-1' \
	'' \
	'Package: luci-app-fwlive' \
	"Version: $want" \
	'Depends: luci-base' \
	'Architecture: all' \
	'' \
	'Package: other' \
	'Version: 1.0-1'

got="$(feed_index_opkg_version "$TMP/Packages")"
feed_index_versions_match "$got" "$want" || fail "Packages Version should be $want (got '$got')"
ok "matching Packages Version succeeds"

write_packages "$TMP/Packages.stale" \
	'Package: luci-app-fwlive' \
	"Version: $stale"
got="$(feed_index_opkg_version "$TMP/Packages.stale")"
if feed_index_versions_match "$got" "$want" >/dev/null 2>&1; then
	fail "stale Packages Version $stale must not match $want"
fi
ok "stale Packages Version fails"

write_packages "$TMP/Packages.missing" \
	'Package: luci-base' \
	'Version: 24.10.0-1'
if feed_index_opkg_version "$TMP/Packages.missing" >/dev/null 2>&1; then
	fail "missing luci-app-fwlive in Packages must fail"
fi
ok "missing package in Packages fails"

write_packages "$TMP/Packages.emptyver" \
	'Package: luci-app-fwlive' \
	'Version:'
if feed_index_opkg_version "$TMP/Packages.emptyver" >/dev/null 2>&1; then
	fail "empty Version in Packages must fail"
fi
ok "empty Packages Version fails"

gzip -9cn "$TMP/Packages" >"$TMP/Packages.gz"
got="$(feed_index_opkg_version "$TMP/Packages.gz")"
feed_index_versions_match "$got" "$want" || fail "Packages.gz Version should be $want (got '$got')"
ok "matching Packages.gz Version succeeds"

mkdir -p "$TMP/bin"
cat >"$TMP/bin/apk" <<'EOF'
#!/bin/sh
echo "decoy host apk invoked" >&2
echo decoy > "$(dirname "$0")/../apk-invoked"
exit 1
EOF
chmod 755 "$TMP/bin/apk"

cat >"$TMP/bin/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"${FWLIVE_DOCKER_LOG:?}"
for arg in "$@"; do
	case "$arg" in
		adbdump)
			cat "${FWLIVE_ADBDUMP_FIXTURE:?}"
			exit 0
			;;
	esac
done
echo "docker stub: expected adbdump" >&2
exit 1
EOF
chmod 755 "$TMP/bin/docker"

FWLIVE_DOCKER_LOG="$TMP/docker.log"
FWLIVE_SDK_APK_IMAGE="ghcr.io/openwrt/sdk:test-pin"
SDK_MATRIX_DIGEST_CACHE_DIR="$TMP/sdk-digests"
export FWLIVE_DOCKER_LOG FWLIVE_SDK_APK_IMAGE SDK_MATRIX_DIGEST_CACHE_DIR
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"
PATH="$TMP/bin:$PATH"

adb="$TMP/packages.adb"
: >"$adb"

write_adb_dump() {
	local dest="$1" json="$2"
	printf '%s\n' "$json" >"$dest"
}

match_json='{"packages":[{"name":"other","version":"1.0-r1"},{"name":"luci-app-fwlive","version":"0.1.45-r1"}]}'
stale_json='{"packages":[{"name":"luci-app-fwlive","version":"0.1.44-r1"}]}'
missing_json='{"packages":[{"name":"other","version":"1.0-r1"}]}'
empty_json='{"packages":[{"name":"luci-app-fwlive","version":""}]}'

write_adb_dump "$TMP/adbdump-match.json" "$match_json"
FWLIVE_ADBDUMP_FIXTURE="$TMP/adbdump-match.json"
export FWLIVE_ADBDUMP_FIXTURE
: >"$FWLIVE_DOCKER_LOG"
got="$(feed_index_apk_pkgver "$adb")"
grep -Fq 'adbdump --format json /work/packages.adb' "$FWLIVE_DOCKER_LOG" \
	|| fail "docker stub was not invoked with apk adbdump --format json"
grep -Fq '/builder/staging_dir/host/bin/apk --allow-untrusted' "$FWLIVE_DOCKER_LOG" \
	|| fail "docker stub must run the SDK apk path, not host apk"
[[ ! -e "$TMP/apk-invoked" ]] || fail "host apk was invoked"
feed_index_versions_match "$got" "$want" || fail "packages.adb pkgver should be $want (got '$got')"
ok "matching packages.adb pkgver uses pinned SDK apk"

write_adb_dump "$TMP/adbdump-stale.json" "$stale_json"
FWLIVE_ADBDUMP_FIXTURE="$TMP/adbdump-stale.json"
got="$(feed_index_apk_pkgver "$adb")"
if feed_index_versions_match "$got" "$want" >/dev/null 2>&1; then
	fail "stale packages.adb pkgver $stale must not match $want"
fi
ok "stale packages.adb pkgver fails"

write_adb_dump "$TMP/adbdump-missing.json" "$missing_json"
FWLIVE_ADBDUMP_FIXTURE="$TMP/adbdump-missing.json"
if feed_index_apk_pkgver "$adb" >/dev/null 2>&1; then
	fail "missing luci-app-fwlive in packages.adb dump must fail"
fi
ok "missing package in packages.adb dump fails"

write_adb_dump "$TMP/adbdump-empty.json" "$empty_json"
FWLIVE_ADBDUMP_FIXTURE="$TMP/adbdump-empty.json"
if feed_index_apk_pkgver "$adb" >/dev/null 2>&1; then
	fail "empty pkgver in packages.adb dump must fail"
fi
ok "empty packages.adb pkgver fails"
[[ ! -e "$TMP/apk-invoked" ]] || fail "host apk was invoked on fail-closed apk paths"

echo "feed-index-version helper test passed"
