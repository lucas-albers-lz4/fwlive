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
opkg_want='0.1.45-1'
opkg_stale='0.1.44-1'
packages_fix="$ROOT/tests/fixtures/feed-index-packages"
adbdump_fix="$ROOT/tests/fixtures/feed-index-adbdump.json"
opkg_info_fix="$ROOT/tests/fixtures/feed-index-opkg-info"
apk_query_fix="$ROOT/tests/fixtures/feed-index-apk-query.json"

[[ -f "$packages_fix" ]] || fail "missing Packages fixture: $packages_fix"
[[ -f "$adbdump_fix" ]] || fail "missing adbdump fixture: $adbdump_fix"
[[ -f "$opkg_info_fix" ]] || fail "missing opkg info fixture: $opkg_info_fix"
[[ -f "$apk_query_fix" ]] || fail "missing apk query fixture: $apk_query_fix"

[[ "$FEED_INDEX_GUEST_OPKG_CMD" == 'opkg info luci-app-fwlive' ]] \
	|| fail "pinned opkg guest query drifted: $FEED_INDEX_GUEST_OPKG_CMD"
[[ "$FEED_INDEX_GUEST_APK_CMD" == 'apk query --installed --format json --fields name,version luci-app-fwlive' ]] \
	|| fail "pinned apk guest query drifted: $FEED_INDEX_GUEST_APK_CMD"
grep -Fq 'ssh_run "$FEED_INDEX_GUEST_OPKG_CMD"' "$ROOT/scripts/qemu-install-from-feed.sh" \
	|| fail "qemu-install-from-feed.sh must run the pinned opkg query"
grep -Fq 'ssh_run "$FEED_INDEX_GUEST_APK_CMD"' "$ROOT/scripts/qemu-install-from-feed.sh" \
	|| fail "qemu-install-from-feed.sh must run the pinned apk query"
ok "pinned guest queries are wired"

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

if feed_index_versions_match "$opkg_want" "$want" >/dev/null 2>&1; then
	fail "opkg $opkg_want must not match apk $want (per-cell compare)"
fi
ok "opkg vs apk spelling fails"

if feed_index_versions_match '' "$want" >/dev/null 2>&1; then
	fail "empty form must fail closed"
fi
ok "empty version form fails"

write_packages() {
	local dest="$1"
	shift
	printf '%s\n' "$@" >"$dest"
}

got="$(feed_index_opkg_version "$packages_fix")"
feed_index_versions_match "$got" "$opkg_want" || fail "Packages Version should be $opkg_want (got '$got')"
ok "matching Packages Version succeeds"

write_packages "$TMP/Packages.stale" \
	'Package: luci-app-fwlive' \
	"Version: $stale"
got="$(feed_index_opkg_version "$TMP/Packages.stale")"
if feed_index_versions_match "$got" "$want" >/dev/null 2>&1; then
	fail "stale Packages Version $stale must not match $want"
fi
ok "stale Packages Version fails"

write_packages "$TMP/Packages.wrong" \
	'Package: luci-app-fwlive-extra' \
	"Version: $want" \
	'' \
	'Package: luci-base' \
	'Version: 24.10.0-1'
if feed_index_opkg_version "$TMP/Packages.wrong" >/dev/null 2>&1; then
	fail "wrong package in Packages must fail"
fi
ok "wrong package in Packages fails"

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

gzip -9cn "$packages_fix" >"$TMP/Packages.gz"
got="$(feed_index_opkg_version "$TMP/Packages.gz")"
feed_index_versions_match "$got" "$opkg_want" || fail "Packages.gz Version should be $opkg_want (got '$got')"
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

stale_json='{"packages":[{"name":"luci-app-fwlive","version":"0.1.44-r1"}]}'
wrong_json='{"packages":[{"name":"luci-app-fwlive-extra","version":"0.1.45-r1"}]}'
missing_json='{"packages":[{"name":"other","version":"1.0-r1"}]}'
empty_json='{"packages":[{"name":"luci-app-fwlive","version":""}]}'
pkgver_json='{"packages":[{"name":"luci-app-fwlive","pkgver":"0.1.45-r1"}]}'

FWLIVE_ADBDUMP_FIXTURE="$adbdump_fix"
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

write_adb_dump "$TMP/adbdump-wrong.json" "$wrong_json"
FWLIVE_ADBDUMP_FIXTURE="$TMP/adbdump-wrong.json"
if feed_index_apk_pkgver "$adb" >/dev/null 2>&1; then
	fail "wrong package in packages.adb dump must fail"
fi
ok "wrong package in packages.adb dump fails"

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

write_adb_dump "$TMP/adbdump-pkgver.json" "$pkgver_json"
FWLIVE_ADBDUMP_FIXTURE="$TMP/adbdump-pkgver.json"
got="$(feed_index_apk_pkgver "$adb")"
feed_index_versions_match "$got" "$want" || fail "packages.adb pkgver field should be $want (got '$got')"
ok "packages.adb pkgver field is accepted"

[[ ! -e "$TMP/apk-invoked" ]] || fail "host apk was invoked on fail-closed apk paths"

got="$(feed_index_guest_opkg_version "$opkg_info_fix")"
feed_index_versions_match "$got" "$opkg_want" \
	|| fail "opkg info Version should be $opkg_want (got '$got')"
ok "matching opkg info Version succeeds"

write_packages "$TMP/opkg-info.stale" \
	'Package: luci-app-fwlive' \
	"Version: $opkg_stale" \
	'Status: install user installed'
got="$(feed_index_guest_opkg_version "$TMP/opkg-info.stale")"
if feed_index_versions_match "$got" "$opkg_want" >/dev/null 2>&1; then
	fail "stale opkg info Version $opkg_stale must not match $opkg_want"
fi
ok "stale opkg info Version fails"

write_packages "$TMP/opkg-info.notinst" \
	'Package: luci-app-fwlive' \
	"Version: $opkg_want" \
	'Status: unknown ok not-installed'
if feed_index_guest_opkg_version "$TMP/opkg-info.notinst" >/dev/null 2>&1; then
	fail "opkg info not-installed Status must fail"
fi
ok "opkg info not-installed fails"

write_packages "$TMP/opkg-info.half" \
	'Package: luci-app-fwlive' \
	"Version: $opkg_want" \
	'Status: install ok half-installed'
if feed_index_guest_opkg_version "$TMP/opkg-info.half" >/dev/null 2>&1; then
	fail "opkg info half-installed Status must fail"
fi
ok "opkg info half-installed fails"

write_packages "$TMP/opkg-info.nostatus" \
	'Package: luci-app-fwlive' \
	"Version: $opkg_want"
if feed_index_guest_opkg_version "$TMP/opkg-info.nostatus" >/dev/null 2>&1; then
	fail "opkg info without Status must fail"
fi
ok "opkg info without Status fails"

write_packages "$TMP/opkg-info.wrong" \
	'Package: luci-app-fwlive-extra' \
	"Version: $opkg_want" \
	'Status: install user installed'
if feed_index_guest_opkg_version "$TMP/opkg-info.wrong" >/dev/null 2>&1; then
	fail "wrong package in opkg info must fail"
fi
ok "wrong package in opkg info fails"

: >"$FWLIVE_DOCKER_LOG"
got="$(feed_index_guest_apk_query_pkgver "$apk_query_fix")"
[[ ! -s "$FWLIVE_DOCKER_LOG" ]] || fail "guest apk query must not invoke docker"
[[ ! -e "$TMP/apk-invoked" ]] || fail "host apk was invoked for guest apk query"
feed_index_versions_match "$got" "$want" \
	|| fail "apk query pkgver should be $want (got '$got')"
ok "matching apk query pkgver succeeds"

write_adb_dump "$TMP/apk-query-stale.json" \
	'[{"name":"luci-app-fwlive","version":"0.1.44-r1"}]'
got="$(feed_index_guest_apk_query_pkgver "$TMP/apk-query-stale.json")"
if feed_index_versions_match "$got" "$want" >/dev/null 2>&1; then
	fail "stale apk query pkgver $stale must not match $want"
fi
ok "stale apk query pkgver fails"

write_adb_dump "$TMP/apk-query-wrong.json" \
	'[{"name":"luci-app-fwlive-extra","version":"0.1.45-r1"}]'
if feed_index_guest_apk_query_pkgver "$TMP/apk-query-wrong.json" >/dev/null 2>&1; then
	fail "wrong package in apk query must fail"
fi
ok "wrong package in apk query fails"

write_adb_dump "$TMP/apk-query-missing.json" '[]'
if feed_index_guest_apk_query_pkgver "$TMP/apk-query-missing.json" >/dev/null 2>&1; then
	fail "empty apk query must fail"
fi
ok "empty apk query fails"

write_adb_dump "$TMP/apk-query-empty.json" \
	'[{"name":"luci-app-fwlive","version":""}]'
if feed_index_guest_apk_query_pkgver "$TMP/apk-query-empty.json" >/dev/null 2>&1; then
	fail "empty pkgver in apk query must fail"
fi
ok "empty apk query pkgver fails"

write_adb_dump "$TMP/apk-query-pkgver.json" \
	'[{"name":"luci-app-fwlive","pkgver":"0.1.45-r1"}]'
got="$(feed_index_guest_apk_query_pkgver "$TMP/apk-query-pkgver.json")"
feed_index_versions_match "$got" "$want" \
	|| fail "apk query pkgver field should be $want (got '$got')"
ok "apk query pkgver field is accepted"

[[ ! -s "$FWLIVE_DOCKER_LOG" ]] || fail "guest apk query path invoked docker"
[[ ! -e "$TMP/apk-invoked" ]] || fail "host apk was invoked on guest query paths"

echo "feed-index-version helper test passed"
