#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/fwlive-test-busybox-awk.sh
source "${ROOT}/scripts/lib/fwlive-test-busybox-awk.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
	echo "fwlive BusyBox awk lane test FAIL: $*" >&2
	exit 1
}

make_fixture_root() {
	local root="$1"
	mkdir -p "${root}/scripts"
	cat >"${root}/scripts/ensure-busybox-awk.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' invoked >"${FWLIVE_TEST_ENSURE_MARKER}"
if [[ "${FWLIVE_TEST_ENSURE_FAIL:-}" == 1 ]]; then
	echo "fetch failure fixture" >&2
	exit 1
fi
printf '%s\n' "${FWLIVE_TEST_ENSURE_BIN}"
EOF
	chmod 0755 "${root}/scripts/ensure-busybox-awk.sh"
}

run_prepare_case() (
	local name="$1" system="$2" arch="$3" ci="$4" allow_skip="$5"
	local require_zero="$6" ensure_fail="$7" expected_rc="$8" expected_skips="$9"
	local ensure_called="${10}" expected_text="${11}" root="${TMP}/${name}"
	make_fixture_root "$root"
	fwlive_skipped_gates=0
	CI="$ci"
	FWLIVE_ALLOW_SKIP="$allow_skip"
	FWLIVE_TEST_REQUIRE_ZERO_SKIPS="$require_zero"
	FWLIVE_TEST_ENSURE_MARKER="${TMP}/${name}.called"
	FWLIVE_TEST_ENSURE_BIN="${TMP}/${name}/bin"
	FWLIVE_TEST_ENSURE_FAIL="$ensure_fail"
	export FWLIVE_TEST_ENSURE_MARKER FWLIVE_TEST_ENSURE_BIN FWLIVE_TEST_ENSURE_FAIL
	TEST_UNAME_S="$system"
	TEST_UNAME_M="$arch"
	uname() {
		case "$1" in
			-s) printf '%s\n' "$TEST_UNAME_S" ;;
			-m) printf '%s\n' "$TEST_UNAME_M" ;;
			*) return 1 ;;
		esac
	}
	set +e
	fwlive_test_prepare_busybox_awk "$root" 2>"${TMP}/${name}.log"
	local rc=$?
	set -e
	[[ "$rc" -eq "$expected_rc" ]] || fail "${name}: expected status ${expected_rc}, got ${rc}"
	[[ "$fwlive_skipped_gates" -eq "$expected_skips" ]] || fail "${name}: wrong skip count ${fwlive_skipped_gates}"
	if [[ "$ensure_called" == yes ]]; then
		[[ -e "$FWLIVE_TEST_ENSURE_MARKER" ]] || fail "${name}: expected helper call"
	else
		[[ ! -e "$FWLIVE_TEST_ENSURE_MARKER" ]] || fail "${name}: helper must not run"
	fi
	if [[ -n "$expected_text" ]]; then
		grep -Fq "$expected_text" "${TMP}/${name}.log" || fail "${name}: missing diagnostic '$expected_text'"
	fi
	if [[ "$expected_rc" -eq 0 ]]; then
		[[ "$FWLIVE_BUSYBOX_AWK_BIN" == "$FWLIVE_TEST_ENSURE_BIN" ]] || fail "${name}: wrong returned bin path"
	fi
)

run_prepare_case arch-skip Linux aarch64 "" "" "" "" 2 1 no "requires Linux x86_64"
run_prepare_case arch-ci Linux aarch64 true "" 1 "" 1 0 no "required in CI"
run_prepare_case offline-skip Linux x86_64 "" 1 "" 1 2 1 yes "FWLIVE_ALLOW_SKIP=1"
run_prepare_case offline-fail Linux x86_64 "" "" "" 1 1 0 yes "Could not prepare"
run_prepare_case strict-skip Linux x86_64 "" 1 1 1 1 0 yes "Could not prepare"
run_prepare_case success Linux x86_64 "" "" "" "" 0 0 yes ""

test_ensure_busybox_awk_cache_and_download_timeout() {
	local cache curl_dir fixture_root fixture_deb fixture_sha deb_name output rc
	cache="${TMP}/cached lane"
	curl_dir="${TMP}/curl-bin"
	fixture_root="${TMP}/fixture-root"
	fixture_deb="${TMP}/fixture.deb"
	deb_name='busybox-static_1.37.0-6+b9_amd64.deb'
	mkdir -p "${fixture_root}/usr/bin" "${cache}/bin" "$curl_dir"
	cat >"${fixture_root}/usr/bin/busybox" <<'EOF'
#!/bin/sh
if [ "$#" -eq 0 ]; then
	printf '%s\n' 'BusyBox v1.37.0 fixture'
elif [ "$1" = awk ]; then
	printf '%s\n' 'verified-artifact'
else
	exit 2
fi
EOF
	chmod 0755 "${fixture_root}/usr/bin/busybox"
	tar -czf "${TMP}/data.tar.gz" -C "$fixture_root" usr/bin/busybox
	(cd "$TMP" && ar cr "$fixture_deb" data.tar.gz)
	fixture_sha="$(sha256sum "$fixture_deb" | awk '{print $1}')"
	cp "$fixture_deb" "${cache}/${deb_name}"
	cat >"${cache}/busybox-static" <<'EOF'
#!/bin/sh
printf '%s\n' 'BusyBox v1.37.0 poisoned'
EOF
	cat >"${cache}/bin/awk" <<EOF
#!/bin/sh
touch '${TMP}/poisoned-wrapper-was-run'
exit 0
EOF
	cat >"${curl_dir}/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${FWLIVE_TEST_CURL_ARGS}"
out=""
while (($#)); do
	if [[ "$1" == -o ]]; then
		out="$2"
		shift 2
	else
		shift
	fi
done
[[ -n "$out" ]] || exit 2
cp "$FWLIVE_TEST_FIXTURE_DEB" "$out"
EOF
	chmod 0755 "${cache}/busybox-static" "${cache}/bin/awk" "${curl_dir}/curl"

	output="$(FWLIVE_BUSYBOX_AWK_DIR="$cache" FWLIVE_BUSYBOX_AWK_SHA256="$fixture_sha" FWLIVE_TEST_CURL_ARGS="${TMP}/cached-curl.args" FWLIVE_TEST_FIXTURE_DEB="$fixture_deb" PATH="${curl_dir}:${PATH}" "${ROOT}/scripts/ensure-busybox-awk.sh")"
	[[ "$output" == "${cache}/bin" ]] || fail "cached helper returned wrong bin path ($output)"
	[[ ! -e "${TMP}/cached-curl.args" ]] || fail "valid package cache must avoid network fetch"
	[[ "$("${cache}/bin/awk")" == verified-artifact ]] || fail "cache hit did not restore the executable from the verified package"
	[[ ! -e "${TMP}/poisoned-wrapper-was-run" ]] || fail "cache hit trusted a poisoned awk wrapper"

	# A corrupt package cache is replaced from the URL, with bounded curl.
	printf '%s\n' corrupted >"${cache}/${deb_name}"
	output="$(FWLIVE_BUSYBOX_AWK_DIR="$cache" FWLIVE_BUSYBOX_AWK_SHA256="$fixture_sha" FWLIVE_BUSYBOX_AWK_URL='https://snapshot.debian.org/file/3827ed7fbd1b3928d5cb45bbe390c27862193e70' FWLIVE_TEST_CURL_ARGS="${TMP}/curl.args" FWLIVE_TEST_FIXTURE_DEB="$fixture_deb" PATH="${curl_dir}:${PATH}" "${ROOT}/scripts/ensure-busybox-awk.sh")"
	[[ "$output" == "${cache}/bin" ]] || fail "download recovery returned wrong bin path ($output)"
	grep -Fxq -- '--connect-timeout' "${TMP}/curl.args" || fail "download has no connection timeout"
	grep -Fxq -- '10' "${TMP}/curl.args" || fail "download connection timeout is not bounded"
	grep -Fxq -- '--max-time' "${TMP}/curl.args" || fail "download has no transfer timeout"
	grep -Fxq -- '60' "${TMP}/curl.args" || fail "download transfer timeout is not bounded"
	grep -Fxq -- '--retry-max-time' "${TMP}/curl.args" || fail "download retries have no total timeout"
	grep -Fxq -- '90' "${TMP}/curl.args" || fail "download retry window is not bounded"
	grep -Fxq -- 'https://snapshot.debian.org/file/3827ed7fbd1b3928d5cb45bbe390c27862193e70' "${TMP}/curl.args" \
		|| fail "default URL must use the content-addressed Debian snapshot file"
	[[ "$("${cache}/bin/awk")" == verified-artifact ]] || fail "download did not install the verified executable"

	# A local checksum override is enforced on package cache hits too.
	set +e
	FWLIVE_BUSYBOX_AWK_DIR="$cache" FWLIVE_BUSYBOX_AWK_SHA256="$(printf '0%.0s' {1..64})" FWLIVE_TEST_CURL_ARGS="${TMP}/override-curl.args" FWLIVE_TEST_FIXTURE_DEB="$fixture_deb" PATH="${curl_dir}:${PATH}" \
		"${ROOT}/scripts/ensure-busybox-awk.sh" >/dev/null 2>"${TMP}/override.log"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || fail "checksum override must reject a cached package with a different hash"
	[[ -e "${TMP}/override-curl.args" ]] || fail "checksum override was bypassed on package cache hit"
	grep -Fq 'sha256 mismatch' "${TMP}/override.log" || fail "wrong checksum override has no mismatch diagnostic"
	grep -Eq '^[0-9a-f]{64}  busybox-static_1\.37\.0-6\+b9_amd64\.deb$' "${ROOT}/scripts/busybox-awk-1.37.sha256" \
		|| fail "artifact checksum manifest is malformed"
}

test_ensure_busybox_awk_cache_and_download_timeout
echo "fwlive BusyBox awk lane tests passed"
