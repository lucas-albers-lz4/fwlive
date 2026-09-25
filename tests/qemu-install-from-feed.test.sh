#!/usr/bin/env bash
# Host proof: qemu-install-from-feed.sh compares guest vs published index (#421).
# Stubs ssh; uses a local file:// feed index. No live QEMU, no host apk.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/qemu-install-from-feed.sh"
# shellcheck source=scripts/lib/feed-publish.sh
source "$ROOT/scripts/lib/feed-publish.sh"
# shellcheck source=scripts/lib/sdk-matrix.sh
source "$ROOT/scripts/lib/sdk-matrix.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
	echo "qemu-install-from-feed test FAIL: $*" >&2
	exit 1
}

ok() {
	echo "qemu-install-from-feed test OK: $*"
}

bash -n "$SCRIPT" || fail "qemu-install-from-feed.sh has invalid shell syntax"

opkg_info_fix="$ROOT/tests/fixtures/feed-index-opkg-info"
apk_query_fix="$ROOT/tests/fixtures/feed-index-apk-query.json"
adbdump_fix="$ROOT/tests/fixtures/feed-index-adbdump.json"
[[ -f "$opkg_info_fix" ]] || fail "missing opkg info fixture"
[[ -f "$apk_query_fix" ]] || fail "missing apk query fixture"
[[ -f "$adbdump_fix" ]] || fail "missing adbdump fixture"

mkdir -p "$TMP/bin" "$TMP/feed/23.05" "$TMP/feed/24.10" "$TMP/feed/25.12/all"

write_packages() {
	local dest="$1"
	shift
	printf '%s\n' "$@" >"$dest"
}

write_packages "$TMP/packages.match" \
	'Package: luci-app-fwlive' \
	'Version: 0.1.45-1' \
	'Architecture: all'
gzip -9cn "$TMP/packages.match" >"$TMP/feed/24.10/Packages.gz"
gzip -9cn "$TMP/packages.match" >"$TMP/feed/23.05/Packages.gz"
printf 'adb\n' >"$TMP/feed/25.12/all/packages.adb"

write_packages "$TMP/opkg-info.stale" \
	'Package: luci-app-fwlive' \
	'Version: 0.1.44-1' \
	'Status: install user installed'
printf '%s\n' '[{"name":"luci-app-fwlive","version":"0.1.44-r1"}]' \
	>"$TMP/apk-query.stale.json"

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

cat >"$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -u
last="${!#}"
printf 'ssh %s\n' "$last" >>"${FWLIVE_STUB_LOG:?}"
case "$last" in
	'command -v apk >/dev/null 2>&1')
		if [[ "${FWLIVE_STUB_HAS_APK:-0}" == 1 ]]; then
			exit 0
		fi
		exit 1
		;;
	wget\ *)
		exit 0
		;;
	'opkg-key add /tmp/fwlive-feed.key')
		exit 0
		;;
	grep\ *)
		exit 0
		;;
	'opkg update')
		if [[ "${FWLIVE_STUB_FAIL_OPKG_UPDATE:-0}" == 1 ]]; then
			exit 1
		fi
		exit 0
		;;
	'opkg install luci-app-fwlive')
		if [[ "${FWLIVE_STUB_FAIL_OPKG_INSTALL:-0}" == 1 ]]; then
			exit 1
		fi
		exit 0
		;;
	'opkg info luci-app-fwlive')
		cat "${FWLIVE_STUB_OPKG_INFO:?}"
		exit 0
		;;
	'mkdir -p /etc/apk/keys' | cp\ *)
		exit 0
		;;
	'apk update')
		if [[ "${FWLIVE_STUB_FAIL_APK_UPDATE:-0}" == 1 ]]; then
			exit 1
		fi
		exit 0
		;;
	'apk add luci-app-fwlive')
		if [[ "${FWLIVE_STUB_FAIL_APK_ADD:-0}" == 1 ]]; then
			exit 1
		fi
		exit 0
		;;
	'apk query --installed --format json --fields name,version luci-app-fwlive')
		cat "${FWLIVE_STUB_APK_QUERY:?}"
		exit 0
		;;
	*)
		echo "unexpected remote command: $last" >&2
		exit 1
		;;
esac
EOF
chmod 755 "$TMP/bin/ssh"

FWLIVE_DOCKER_LOG="$TMP/docker.log"
FWLIVE_STUB_LOG="$TMP/ssh.log"
FWLIVE_SDK_APK_IMAGE="ghcr.io/openwrt/sdk:test-pin"
SDK_MATRIX_DIGEST_CACHE_DIR="$TMP/sdk-digests"
export FWLIVE_DOCKER_LOG FWLIVE_STUB_LOG FWLIVE_SDK_APK_IMAGE
export SDK_MATRIX_DIGEST_CACHE_DIR
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"

FEED_BASE="file://${TMP}/feed"

opkg_install_urls_ok() {
	local log="$1" version="$2" feed_dir
	feed_dir="$(feed_publish_feed_dir "$version")"
	grep -Fq "wget -O /tmp/fwlive-feed.key '${FEED_BASE}/public.key'" "$log" \
		&& grep -Fq "src/gz fwlive ${FEED_BASE}/${feed_dir}" "$log"
}

apk_install_urls_ok() {
	local log="$1" version="$2" feed_dir index_url
	feed_dir="$(feed_publish_feed_dir "$version")"
	index_url="${FEED_BASE}/${feed_dir}/all/packages.adb"
	grep -Fq "wget -O /tmp/fwlive-feed.rsa.pub '${FEED_BASE}/fwlive-feed.rsa.pub'" "$log" \
		&& grep -Fq "$index_url" "$log"
}

assert_opkg_install_urls() {
	local log="$1" version="$2"
	opkg_install_urls_ok "$log" "$version" \
		|| fail "opkg cell must wget public.key and configure src/gz fwlive ${FEED_BASE}/$(feed_publish_feed_dir "$version") ($(cat "$log"))"
}

assert_apk_install_urls() {
	local log="$1" version="$2"
	apk_install_urls_ok "$log" "$version" \
		|| fail "apk cell must wget fwlive-feed.rsa.pub and configure packages.adb index for $version ($(cat "$log"))"
}

assert_manager_matches_format() {
	local log="$1" version="$2" fmt
	fmt="$(sdk_matrix_package_format "$version")" \
		|| fail "sdk_matrix_package_format failed for $version"
	case "$fmt" in
		ipk)
			grep -Fq 'opkg update' "$log" \
				|| fail "$version (ipk) must run opkg update"
			grep -Fq 'opkg install luci-app-fwlive' "$log" \
				|| fail "$version (ipk) must run opkg install"
			if grep -Fq 'apk update' "$log"; then
				fail "$version (ipk) must not run apk update"
			fi
			if grep -Fq 'apk add luci-app-fwlive' "$log"; then
				fail "$version (ipk) must not run apk add"
			fi
			;;
		apk)
			grep -Fq 'apk update' "$log" \
				|| fail "$version (apk) must run apk update"
			grep -Fq 'apk add luci-app-fwlive' "$log" \
				|| fail "$version (apk) must run apk add"
			if grep -Fq 'opkg update' "$log"; then
				fail "$version (apk) must not run opkg update"
			fi
			if grep -Fq 'opkg install luci-app-fwlive' "$log"; then
				fail "$version (apk) must not run opkg install"
			fi
			;;
		*)
			fail "unknown sdk_matrix_package_format '$fmt' for $version"
			;;
	esac
}

run_install() {
	local log="$1" install_script
	shift
	install_script="${FWLIVE_INSTALL_SCRIPT:-$SCRIPT}"
	: >"$FWLIVE_STUB_LOG"
	: >"$FWLIVE_DOCKER_LOG"
	rm -f "$TMP/apk-invoked"
	set +e
	PATH="$TMP/bin:$PATH" \
		FWLIVE_FEED_BASE_URL="$FEED_BASE" \
		OPENWRT_HOST=127.0.0.1 \
		OPENWRT_SSH_PORT=2222 \
		OPENWRT_USER=root \
		FWLIVE_STUB_LOG="$FWLIVE_STUB_LOG" \
		FWLIVE_STUB_HAS_APK="${FWLIVE_STUB_HAS_APK:-0}" \
		FWLIVE_STUB_OPKG_INFO="${FWLIVE_STUB_OPKG_INFO:-}" \
		FWLIVE_STUB_APK_QUERY="${FWLIVE_STUB_APK_QUERY:-}" \
		FWLIVE_STUB_FAIL_OPKG_UPDATE="${FWLIVE_STUB_FAIL_OPKG_UPDATE:-0}" \
		FWLIVE_STUB_FAIL_OPKG_INSTALL="${FWLIVE_STUB_FAIL_OPKG_INSTALL:-0}" \
		FWLIVE_STUB_FAIL_APK_UPDATE="${FWLIVE_STUB_FAIL_APK_UPDATE:-0}" \
		FWLIVE_STUB_FAIL_APK_ADD="${FWLIVE_STUB_FAIL_APK_ADD:-0}" \
		FWLIVE_ADBDUMP_FIXTURE="${FWLIVE_ADBDUMP_FIXTURE:-}" \
		FWLIVE_DOCKER_LOG="$FWLIVE_DOCKER_LOG" \
		FWLIVE_SDK_APK_IMAGE="$FWLIVE_SDK_APK_IMAGE" \
		SDK_MATRIX_DIGEST_CACHE_DIR="$SDK_MATRIX_DIGEST_CACHE_DIR" \
		"$install_script" --no-smoke "$@" >"$log" 2>&1
	rc=$?
	set -e
	return "$rc"
}

FWLIVE_STUB_HAS_APK=0
FWLIVE_STUB_OPKG_INFO="$opkg_info_fix"
FWLIVE_STUB_APK_QUERY="$apk_query_fix"
FWLIVE_ADBDUMP_FIXTURE="$adbdump_fix"
FWLIVE_STUB_FAIL_OPKG_UPDATE=0
FWLIVE_STUB_FAIL_OPKG_INSTALL=0
FWLIVE_STUB_FAIL_APK_UPDATE=0
FWLIVE_STUB_FAIL_APK_ADD=0
export FWLIVE_STUB_HAS_APK FWLIVE_STUB_OPKG_INFO FWLIVE_STUB_APK_QUERY
export FWLIVE_ADBDUMP_FIXTURE
export FWLIVE_STUB_FAIL_OPKG_UPDATE FWLIVE_STUB_FAIL_OPKG_INSTALL
export FWLIVE_STUB_FAIL_APK_UPDATE FWLIVE_STUB_FAIL_APK_ADD

if run_install "$TMP/opkg-24.log" --version 24.10; then
	ok "24.10 matching opkg info vs Packages.gz succeeds"
else
	fail "24.10 match failed: $(cat "$TMP/opkg-24.log")"
fi
assert_opkg_install_urls "$FWLIVE_STUB_LOG" 24.10
assert_manager_matches_format "$FWLIVE_STUB_LOG" 24.10
grep -Fq 'opkg info luci-app-fwlive' "$FWLIVE_STUB_LOG" \
	|| fail "24.10 cell did not run opkg info"
grep -Fq 'opkg install luci-app-fwlive' "$FWLIVE_STUB_LOG" \
	|| fail "24.10 cell did not install via opkg"
[[ ! -s "$FWLIVE_DOCKER_LOG" ]] || fail "24.10 opkg cell invoked docker"
[[ ! -e "$TMP/apk-invoked" ]] || fail "host apk was invoked on 24.10"

if run_install "$TMP/opkg-23.log" --version 23.05; then
	ok "23.05 matching opkg info vs Packages.gz succeeds"
else
	fail "23.05 match failed: $(cat "$TMP/opkg-23.log")"
fi
assert_opkg_install_urls "$FWLIVE_STUB_LOG" 23.05
assert_manager_matches_format "$FWLIVE_STUB_LOG" 23.05

FWLIVE_STUB_OPKG_INFO="$TMP/opkg-info.stale"
export FWLIVE_STUB_OPKG_INFO
if run_install "$TMP/opkg-stale.log" --version 24.10; then
	fail "stale opkg info must fail the 24.10 feed install"
fi
grep -Fq "version mismatch" "$TMP/opkg-stale.log" \
	|| fail "stale opkg cell must report version mismatch ($(cat "$TMP/opkg-stale.log"))"
ok "stale opkg info fails feed install"

FWLIVE_STUB_OPKG_INFO="$opkg_info_fix"
export FWLIVE_STUB_OPKG_INFO

FWLIVE_STUB_FAIL_OPKG_UPDATE=1
export FWLIVE_STUB_FAIL_OPKG_UPDATE
if run_install "$TMP/fail-opkg-update.log" --version 24.10; then
	fail "opkg update stub failure must fail feed install"
fi
ok "opkg update failure propagates"
FWLIVE_STUB_FAIL_OPKG_UPDATE=0
export FWLIVE_STUB_FAIL_OPKG_UPDATE

FWLIVE_STUB_FAIL_OPKG_INSTALL=1
export FWLIVE_STUB_FAIL_OPKG_INSTALL
if run_install "$TMP/fail-opkg-install.log" --version 24.10; then
	fail "opkg install stub failure must fail feed install"
fi
ok "opkg install failure propagates"
FWLIVE_STUB_FAIL_OPKG_INSTALL=0
export FWLIVE_STUB_FAIL_OPKG_INSTALL

# Keep scripts/… layout so BASH_SOURCE ROOT still finds scripts/lib.
wrong_opkg_root="$TMP/wrong-opkg-feed"
mkdir -p "$wrong_opkg_root/scripts"
ln -s "$ROOT/scripts/lib" "$wrong_opkg_root/scripts/lib"
wrong_opkg_script="$wrong_opkg_root/scripts/qemu-install-from-feed.sh"
sed 's|local feed_url="${base}/${feed_dir}"|local feed_url="${base}/wrong-feed"|' \
	"$SCRIPT" >"$wrong_opkg_script"
chmod +x "$wrong_opkg_script"
FWLIVE_INSTALL_SCRIPT="$wrong_opkg_script"
export FWLIVE_INSTALL_SCRIPT
run_install "$TMP/wrong-opkg-feed.log" --version 24.10 || true
[[ -s "$FWLIVE_STUB_LOG" ]] ||
	fail "mutated opkg installer must reach ssh_run ($(cat "$TMP/wrong-opkg-feed.log"))"
grep -Fq 'wrong-feed' "$FWLIVE_STUB_LOG" ||
	fail "mutated opkg installer must use wrong-feed URL ($(cat "$FWLIVE_STUB_LOG"))"
if opkg_install_urls_ok "$FWLIVE_STUB_LOG" 24.10; then
	fail "mutated opkg feed_url must fail URL assertions (issue #671 red-proof)"
fi
ok "wrong opkg feed_url fails URL assertions"
unset FWLIVE_INSTALL_SCRIPT
export -n FWLIVE_INSTALL_SCRIPT 2>/dev/null || unset FWLIVE_INSTALL_SCRIPT

FWLIVE_STUB_HAS_APK=1
export FWLIVE_STUB_HAS_APK

if run_install "$TMP/apk-25.log" --version 25.12; then
	ok "25.12 matching apk query vs packages.adb succeeds"
else
	fail "25.12 match failed: $(cat "$TMP/apk-25.log")"
fi
assert_apk_install_urls "$FWLIVE_STUB_LOG" 25.12
assert_manager_matches_format "$FWLIVE_STUB_LOG" 25.12
grep -Fq 'apk query --installed --format json --fields name,version luci-app-fwlive' \
	"$FWLIVE_STUB_LOG" \
	|| fail "25.12 cell did not run the pinned apk query"
grep -Fq 'adbdump --format json' "$FWLIVE_DOCKER_LOG" \
	|| fail "25.12 cell must dump packages.adb via SDK apk"
[[ ! -e "$TMP/apk-invoked" ]] || fail "host apk was invoked on 25.12"

FWLIVE_STUB_APK_QUERY="$TMP/apk-query.stale.json"
export FWLIVE_STUB_APK_QUERY
if run_install "$TMP/apk-stale.log" --version 25.12; then
	fail "stale apk query must fail the 25.12 feed install"
fi
grep -Fq "version mismatch" "$TMP/apk-stale.log" \
	|| fail "stale apk cell must report version mismatch ($(cat "$TMP/apk-stale.log"))"
ok "stale apk query fails feed install"
[[ ! -e "$TMP/apk-invoked" ]] || fail "host apk was invoked on stale apk cell"

FWLIVE_STUB_APK_QUERY="$apk_query_fix"
export FWLIVE_STUB_APK_QUERY

FWLIVE_STUB_FAIL_APK_UPDATE=1
export FWLIVE_STUB_FAIL_APK_UPDATE
if run_install "$TMP/fail-apk-update.log" --version 25.12; then
	fail "apk update stub failure must fail feed install"
fi
ok "apk update failure propagates"
FWLIVE_STUB_FAIL_APK_UPDATE=0
export FWLIVE_STUB_FAIL_APK_UPDATE

FWLIVE_STUB_FAIL_APK_ADD=1
export FWLIVE_STUB_FAIL_APK_ADD
if run_install "$TMP/fail-apk-add.log" --version 25.12; then
	fail "apk add stub failure must fail feed install"
fi
ok "apk add failure propagates"
FWLIVE_STUB_FAIL_APK_ADD=0
export FWLIVE_STUB_FAIL_APK_ADD

wrong_apk_root="$TMP/wrong-apk-index"
mkdir -p "$wrong_apk_root/scripts"
ln -s "$ROOT/scripts/lib" "$wrong_apk_root/scripts/lib"
wrong_apk_script="$wrong_apk_root/scripts/qemu-install-from-feed.sh"
sed 's|local index_url="${base}/${feed_dir}/all/packages.adb"|local index_url="${base}/wrong-feed/all/packages.adb"|' \
	"$SCRIPT" >"$wrong_apk_script"
chmod +x "$wrong_apk_script"
FWLIVE_INSTALL_SCRIPT="$wrong_apk_script"
export FWLIVE_INSTALL_SCRIPT
run_install "$TMP/wrong-apk-index.log" --version 25.12 || true
[[ -s "$FWLIVE_STUB_LOG" ]] ||
	fail "mutated apk installer must reach ssh_run ($(cat "$TMP/wrong-apk-index.log"))"
grep -Fq 'wrong-feed' "$FWLIVE_STUB_LOG" ||
	fail "mutated apk installer must use wrong-feed URL ($(cat "$FWLIVE_STUB_LOG"))"
if apk_install_urls_ok "$FWLIVE_STUB_LOG" 25.12; then
	fail "mutated apk index_url must fail URL assertions (issue #671 red-proof)"
fi
ok "wrong apk index_url fails URL assertions"
unset FWLIVE_INSTALL_SCRIPT

echo "qemu-install-from-feed helper test passed"
