#!/usr/bin/env bash
# feed_publish_copy_keys requires both public keys; host Packages filtering
# fails closed on grep I/O errors (#803 #821).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/feed-publish.sh
FEED_PUBLISH_SOURCE="${FWLIVE_FEED_PUBLISH_TEST_SOURCE:-${ROOT}/scripts/lib/feed-publish.sh}"
source "$FEED_PUBLISH_SOURCE"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# #821: both index paths must fail closed on grep I/O errors.
if grep -nE 'grep -vE.*Maintainer.*\|\| true' "${ROOT}/scripts/lib/feed-publish.sh"; then
	fail "Packages filter still swallows grep status with || true"
fi
grep -cE 'grep -vE .*\^\(Maintainer' "${ROOT}/scripts/lib/feed-publish.sh" | grep -qx 2 \
	|| fail "expected two Packages Maintainer filters"

staging="$(mktemp -d)"
opkg_pub="$(mktemp)"
apk_pub="$(mktemp)"
trap 'rm -rf "$staging" "$opkg_pub" "$apk_pub"' EXIT
printf 'opkg-public\n' >"$opkg_pub"
printf 'apk-public\n' >"$apk_pub"

# #803: missing opkg key fails even when apk is present.
if OPKG_FEED_PUBLIC_KEY="" APK_FEED_PUBLIC_KEY="$apk_pub" \
	feed_publish_copy_keys "$staging" >/dev/null 2>&1; then
	fail "copy_keys must refuse unset OPKG_FEED_PUBLIC_KEY"
fi
if OPKG_FEED_PUBLIC_KEY="/no/such/opkg.key" APK_FEED_PUBLIC_KEY="$apk_pub" \
	feed_publish_copy_keys "$staging" >/dev/null 2>&1; then
	fail "copy_keys must refuse a missing OPKG_FEED_PUBLIC_KEY path"
fi
[[ ! -e "${staging}/public.key" ]] || fail "failed copy must not leave public.key"
[[ ! -e "${staging}/fwlive-feed.rsa.pub" ]] || fail "failed copy must not leave apk pub"

# missing apk key fails even when opkg is present
if OPKG_FEED_PUBLIC_KEY="$opkg_pub" APK_FEED_PUBLIC_KEY="" \
	feed_publish_copy_keys "$staging" >/dev/null 2>&1; then
	fail "copy_keys must refuse unset APK_FEED_PUBLIC_KEY"
fi

OPKG_FEED_PUBLIC_KEY="$opkg_pub" APK_FEED_PUBLIC_KEY="$apk_pub" \
	feed_publish_copy_keys "$staging" || fail "copy_keys with both keys"
[[ -f "${staging}/public.key" ]] || fail "staged public.key"
[[ -f "${staging}/fwlive-feed.rsa.pub" ]] || fail "staged fwlive-feed.rsa.pub"
[[ "$(cat "${staging}/public.key")" == "opkg-public" ]] || fail "public.key contents"
[[ "$(cat "${staging}/fwlive-feed.rsa.pub")" == "apk-public" ]] || fail "apk pub contents"

# Exercise the real host index/signing function. The only substituted seams
# are the pinned index script and external grep/gzip/usign commands, so the
# production filter's stdout and exit status control signing.
host_work="$(mktemp -d)"
trap 'rm -rf "$staging" "$opkg_pub" "$apk_pub" "$host_work"' EXIT
host_pkg="${host_work}/feed"
host_tools="${host_work}/tools"
mkdir -p "$host_pkg" "$host_tools"
cat >"${host_work}/ipkg-make-index-template.sh" <<'EOF'
#!/bin/sh
printf 'Package: luci-app-fwlive\nMaintainer: test\nVersion: 0.0.1-1\n'
EOF
chmod +x "${host_work}/ipkg-make-index-template.sh"

# Avoid fetching the external pinned script; feed_publish_stage_opkg_host still
# invokes the production path and performs its real grep/gzip/sign sequence.
feed_publish_ipkg_index_script() {
	local fresh
	fresh="$(mktemp "${host_work}/ipkg-make-index.XXXXXX")" || return 1
	cp "${host_work}/ipkg-make-index-template.sh" "$fresh"
	chmod +x "$fresh"
	printf '%s\n' "$fresh"
}
feed_publish_probe_mkhash() { :; }

cat >"${host_tools}/grep" <<'EOF'
#!/bin/sh
case " $* " in
    *" -vE "*)
        # Model an I/O failure after grep emitted a partial index.
        printf 'Package: partial-index\n'
        exit 2
        ;;
esac
exec /usr/bin/grep "$@"
EOF
cat >"${host_tools}/gzip" <<'EOF'
#!/bin/sh
printf 'gzip\n' >>"$HOST_TOOL_LOG"
exec /usr/bin/gzip "$@"
EOF
cat >"${host_tools}/usign" <<'EOF'
#!/bin/sh
printf 'usign %s\n' "$*" >>"$HOST_TOOL_LOG"
exit 0
EOF
cat >"${host_tools}/mkhash" <<'EOF'
#!/bin/sh
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'
EOF
chmod +x "${host_tools}/grep" "${host_tools}/gzip" "${host_tools}/usign" "${host_tools}/mkhash"

# A failed grep may have written bytes to Packages, but must stop before
# compression and signing. Assert those later production stages were skipped.
: >"${host_work}/tool-log"
if PATH="${host_tools}:${PATH}" HOST_TOOL_LOG="${host_work}/tool-log" \
	OPKG_FEED_SECRET_KEY=/dev/null \
	feed_publish_stage_opkg_host "$host_pkg" 24.10.8 \
	>"${host_work}/grep-failure.out" 2>"${host_work}/grep-failure.err"; then
	fail "host Packages filter must return nonzero on grep I/O error"
fi
[[ "$(cat "${host_pkg}/Packages")" == 'Package: partial-index' ]] \
	|| fail "grep fault fixture must leave the diagnostic partial index"
[[ ! -e "${host_pkg}/Packages.gz" ]] || fail "gzip must not run after grep I/O failure"
[[ ! -e "${host_pkg}/Packages.sig" ]] || fail "usign must not run after grep I/O failure"
[[ ! -s "${host_work}/tool-log" ]] || fail "gzip/usign must not run after grep I/O failure"

# Positive control: valid grep output proceeds through gzip and usign.
cat >"${host_tools}/grep" <<'EOF'
#!/bin/sh
exec /usr/bin/grep "$@"
EOF
chmod +x "${host_tools}/grep"
RETURN_LOG="${host_work}/return.log"
export RETURN_LOG
trap 'printf caller-return >>"$RETURN_LOG"' RETURN
expected_return="$(trap -p RETURN)"
PATH="${host_tools}:${PATH}" HOST_TOOL_LOG="${host_work}/tool-log" \
	OPKG_FEED_SECRET_KEY=/dev/null \
	feed_publish_stage_opkg_host "$host_pkg" 24.10.8 \
	>"${host_work}/positive.out" 2>"${host_work}/positive.err" \
	|| fail "host Packages filter positive control"
[[ -s "${host_pkg}/Packages.gz" ]] || fail "positive control must produce compressed index"
[[ -s "${host_work}/tool-log" ]] || fail "positive control must run gzip and usign"
grep -q '^gzip$' "${host_work}/tool-log" || fail "positive control did not run gzip"
grep -q '^usign ' "${host_work}/tool-log" || fail "positive control did not run usign"
[[ "$(trap -p RETURN)" == "$expected_return" ]] || fail "stage_opkg_host must restore caller RETURN trap"
trap - RETURN

# #1366: exercise the production SDK staging helper and the actual sh -ec
# payload passed to docker run. The docker/export/readiness seams stay on the
# host; only fixed /feed mount paths are mapped to private temporary paths.
# This host fixture requires /bin/sh, /usr/bin/grep, /usr/bin/gzip, sed and
# mktemp. It does not require a Docker daemon; the shim executes the payload.
for prerequisite in sed mktemp; do
	command -v "$prerequisite" >/dev/null 2>&1 \
		|| fail "SDK boundary fixture requires ${prerequisite}"
done
[[ -x /bin/sh && -x /usr/bin/grep && -x /usr/bin/gzip ]] \
	|| fail "SDK boundary fixture requires /bin/sh, /usr/bin/grep and /usr/bin/gzip"
sdk_work="${host_work}/sdk-boundary"
sdk_pkg_failure="${sdk_work}/pkg-failure"
sdk_pkg_valid="${sdk_work}/pkg-valid"
sdk_tool_fixture="${sdk_work}/tool-fixtures"
sdk_container_tmp="${sdk_work}/container-tmp"
sdk_dummy_key="${sdk_work}/dummy-opkg-secret.key"
mkdir -p "$sdk_pkg_failure" "$sdk_pkg_valid" "$sdk_tool_fixture" "$sdk_container_tmp"
printf 'dummy-key-for-host-fixture\n' >"$sdk_dummy_key"

cat >"${sdk_tool_fixture}/ipkg-make-index.sh" <<'EOF'
#!/bin/sh
printf 'Package: luci-app-fwlive\nMaintainer: fixture\nVersion: 0.0.1-1\n'
EOF
cat >"${sdk_tool_fixture}/grep" <<'EOF'
#!/bin/sh
case " $* " in
    *" -vE "*)
        printf 'grep-filter\n' >>"$SDK_TEST_TOOL_LOG"
        if [ "${SDK_TEST_FILTER_FAIL:-0}" = 1 ]; then
            # Model an I/O failure after nonempty stdout, as the research probe did.
            printf 'Package: partial-index\n'
            exit 2
        fi
        ;;
esac
exec /usr/bin/grep "$@"
EOF
cat >"${sdk_tool_fixture}/gzip" <<'EOF'
#!/bin/sh
printf 'gzip\n' >>"$SDK_TEST_TOOL_LOG"
exec /usr/bin/gzip "$@"
EOF
cat >"${sdk_tool_fixture}/usign" <<'EOF'
#!/bin/sh
printf 'usign %s\n' "$*" >>"$SDK_TEST_TOOL_LOG"
signature=
while [ "$#" -gt 0 ]; do
    case "$1" in
        -x) signature="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$signature" ] || exit 1
printf 'dummy-signature\n' >"$signature"
EOF
cat >"${sdk_tool_fixture}/mkhash" <<'EOF'
#!/bin/sh
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n'
EOF
chmod +x "${sdk_tool_fixture}/ipkg-make-index.sh" "${sdk_tool_fixture}/grep" \
	"${sdk_tool_fixture}/gzip" "${sdk_tool_fixture}/usign" "${sdk_tool_fixture}/mkhash"

cat >"${host_tools}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == run ]] || exit 91
shift
declare -a command=() mounts=()
pkg_mount=
key_mount=
tools_mount=
lib_mount=
while (($#)); do
	if [[ "$1" == -v ]]; then
		[[ "$#" -ge 2 ]] || exit 92
		mount="$2"
		mounts+=("$mount")
		case "$mount" in
			*:/feed/pkgdir) pkg_mount="${mount%:/feed/pkgdir}" ;;
			*:/feed/opkg-secret.key:ro) key_mount="${mount%:/feed/opkg-secret.key:ro}" ;;
			*:/feed/tools:ro) tools_mount="${mount%:/feed/tools:ro}" ;;
			*:/feed/lib:ro) lib_mount="${mount%:/feed/lib:ro}" ;;
		esac
		shift 2
	else
		command+=("$1")
		shift
	fi
done
[[ "${#mounts[@]}" -eq 4 ]] || exit 93
[[ "$pkg_mount" == "$SDK_TEST_EXPECT_PKGDIR" ]] || exit 94
[[ "$key_mount" == "$SDK_TEST_EXPECT_KEY" ]] || exit 95
[[ -d "$tools_mount" && -d "$lib_mount" ]] || exit 96
[[ " ${command[*]} " == *" --network none "* ]] || exit 97
[[ " ${command[*]} " == *" --user root "* ]] || exit 98
[[ " ${command[*]} " == *" --platform linux/amd64 "* ]] || exit 99
command_count="${#command[@]}"
((command_count >= 4)) || exit 100
[[ "${command[$((command_count - 4))]}" == "$SDK_MATRIX_IMAGE" ]] || exit 101
[[ "${command[$((command_count - 3))]}" == sh ]] || exit 102
[[ "${command[$((command_count - 2))]}" == -ec ]] || exit 103
payload="${command[$((command_count - 1))]}"
[[ "$payload" == *'grep -vE "^(Maintainer'* ]] || exit 104
printf '%s\n' "$payload" >"$SDK_TEST_PAYLOAD_CAPTURE"
printf 'payload\n' >>"$SDK_TEST_DOCKER_LOG"
mapped_payload="$(printf '%s\n' "$payload" | sed \
	-e "s|/feed/pkgdir|$pkg_mount|g" \
	-e "s|/feed/opkg-secret.key|$key_mount|g" \
	-e "s|/feed/tools|$tools_mount|g" \
	-e "s|/feed/lib|$lib_mount|g")"
TMPDIR="$SDK_TEST_CONTAINER_TMP" /bin/sh -ec "$mapped_payload"
EOF
chmod +x "${host_tools}/docker"

feed_publish_apply_sdk_pin() {
	[[ "$1" == 24.10.8 ]] || return 1
	SDK_MATRIX_IMAGE=fwlive-test-sdk:boundary
	export SDK_MATRIX_IMAGE
}
sdk_matrix_feeds_ready() { return 0; }
feed_publish_export_opkg_tools() {
	local tools_dir="$1"
	cp -a "${SDK_TEST_TOOL_FIXTURE}/." "$tools_dir/"
}
SDK_MATRIX_IMAGE=fwlive-test-sdk:boundary
SDK_TEST_TOOL_FIXTURE="$sdk_tool_fixture"
SDK_TEST_TOOL_LOG="${sdk_work}/tool-log"
SDK_TEST_DOCKER_LOG="${sdk_work}/docker-log"
SDK_TEST_PAYLOAD_CAPTURE="${sdk_work}/sdk-payload.sh"
SDK_TEST_CONTAINER_TMP="$sdk_container_tmp"
SDK_TEST_EXPECT_KEY="$sdk_dummy_key"
FEED_PUBLISH_ROOT="$ROOT"
OPKG_FEED_SECRET_KEY="$sdk_dummy_key"
PATH="${host_tools}:${PATH}"
export SDK_MATRIX_IMAGE SDK_TEST_TOOL_FIXTURE SDK_TEST_TOOL_LOG SDK_TEST_DOCKER_LOG
export SDK_TEST_PAYLOAD_CAPTURE SDK_TEST_CONTAINER_TMP SDK_TEST_EXPECT_KEY
export FEED_PUBLISH_ROOT OPKG_FEED_SECRET_KEY PATH

: >"$SDK_TEST_TOOL_LOG"
: >"$SDK_TEST_DOCKER_LOG"
SDK_TEST_EXPECT_PKGDIR="$sdk_pkg_failure"
export SDK_TEST_EXPECT_PKGDIR
SDK_TEST_FILTER_FAIL=1
export SDK_TEST_FILTER_FAIL
sdk_failure_rc=0
if feed_publish_stage_opkg_sdk 24.10.8 "$sdk_pkg_failure" \
	>"${sdk_work}/sdk-filter-failure.out" 2>"${sdk_work}/sdk-filter-failure.err"; then
	fail "SDK staging must reject partial Packages output with grep status 2"
else
	sdk_failure_rc=$?
fi
unset SDK_TEST_FILTER_FAIL
[[ "$sdk_failure_rc" -eq 2 ]] || fail "SDK staging must propagate filter exit 2, got ${sdk_failure_rc}"
[[ "$(cat "${sdk_pkg_failure}/Packages")" == 'Package: partial-index' ]] \
	|| fail "SDK filter fixture must leave nonempty partial Packages output"
[[ ! -e "${sdk_pkg_failure}/Packages.gz" ]] \
	|| fail "SDK gzip must not run after filter I/O failure"
[[ ! -e "${sdk_pkg_failure}/Packages.sig" ]] \
	|| fail "SDK usign must not run after filter I/O failure"
[[ "$(cat "$SDK_TEST_TOOL_LOG")" == grep-filter ]] \
	|| fail "SDK failure must stop after the filter before gzip/usign"
[[ "$(cat "$SDK_TEST_DOCKER_LOG")" == payload ]] \
	|| fail "SDK failure must execute the payload captured from docker run"
grep -qF 'grep -vE "^(Maintainer' "$SDK_TEST_PAYLOAD_CAPTURE" \
	|| fail "captured SDK payload must contain the production Packages filter"

# Positive SDK control: valid index filtering reaches dummy gzip/usign tools.
: >"$SDK_TEST_TOOL_LOG"
SDK_TEST_EXPECT_PKGDIR="$sdk_pkg_valid"
export SDK_TEST_EXPECT_PKGDIR
feed_publish_stage_opkg_sdk 24.10.8 "$sdk_pkg_valid" \
	>"${sdk_work}/sdk-positive.out" 2>"${sdk_work}/sdk-positive.err" \
	|| fail "SDK valid-index control must succeed through the production staging helper"
[[ -s "${sdk_pkg_valid}/Packages" ]] || fail "SDK positive control must produce Packages"
[[ -s "${sdk_pkg_valid}/Packages.gz" ]] || fail "SDK positive control must run gzip"
[[ -s "${sdk_pkg_valid}/Packages.sig" ]] || fail "SDK positive control must run dummy usign"
grep -q '^grep-filter$' "$SDK_TEST_TOOL_LOG" || fail "SDK positive control did not run the filter"
grep -q '^gzip$' "$SDK_TEST_TOOL_LOG" || fail "SDK positive control did not run gzip"
grep -q '^usign ' "$SDK_TEST_TOOL_LOG" || fail "SDK positive control did not run usign"
[[ "$(wc -l <"$SDK_TEST_DOCKER_LOG")" -eq 2 ]] \
	|| fail "SDK failure and positive control must each cross the docker boundary"

unset SDK_MATRIX_IMAGE SDK_TEST_TOOL_FIXTURE SDK_TEST_TOOL_LOG SDK_TEST_DOCKER_LOG
unset SDK_TEST_PAYLOAD_CAPTURE SDK_TEST_CONTAINER_TMP SDK_TEST_EXPECT_KEY SDK_TEST_EXPECT_PKGDIR
unset FEED_PUBLISH_ROOT OPKG_FEED_SECRET_KEY

echo "feed-publish copy-keys / Packages filter (#803 #821 #1366) passed"
