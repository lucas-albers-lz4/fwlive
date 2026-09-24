#!/usr/bin/env bash
# Host checks for the pinned SDK apk helper. Never invoke host `apk`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/sdk-apk.sh
source "$ROOT/scripts/lib/sdk-apk.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
	echo "sdk-apk test FAIL: $*" >&2
	exit 1
}

ok() {
	echo "sdk-apk test OK: $*"
}

[[ "$(sdk_apk_root)" == "$ROOT" ]] || fail "sdk_apk_root must be the repo root"

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
FWLIVE_ADBDUMP_FIXTURE="$ROOT/tests/fixtures/apk-adbdump-control.json"
FWLIVE_SDK_APK_IMAGE="ghcr.io/openwrt/sdk:test-pin"
SDK_MATRIX_DIGEST_CACHE_DIR="$TMP/sdk-digests"
export FWLIVE_DOCKER_LOG FWLIVE_ADBDUMP_FIXTURE FWLIVE_SDK_APK_IMAGE
export SDK_MATRIX_DIGEST_CACHE_DIR
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"
PATH="$TMP/bin:$PATH"
pkg="$TMP/luci-app-fwlive-0.1.45-r1.apk"
: >"$pkg"

out="$(sdk_apk_adbdump --format json "$pkg")"
grep -Fq 'adbdump --format json /work/luci-app-fwlive-0.1.45-r1.apk' "$FWLIVE_DOCKER_LOG" \
	|| fail "docker stub was not invoked with apk adbdump --format json"
grep -Fq '/builder/staging_dir/host/bin/apk --allow-untrusted' "$FWLIVE_DOCKER_LOG" \
	|| fail "docker stub must run the SDK apk path, not host apk"
grep -Fq -- '--network none' "$FWLIVE_DOCKER_LOG" \
	|| fail "sdk apk docker run must isolate network"
[[ ! -e "$TMP/apk-invoked" ]] || fail "host apk was invoked"
printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "pre-deinstall" in d["scripts"]' \
	|| fail "adbdump fixture JSON was not returned"
ok "sdk_apk_adbdump uses pinned SDK apk via docker"

if sdk_apk_adbdump "$TMP/missing.apk" >/dev/null 2>&1; then
	fail "missing file must fail before docker"
fi
ok "missing adbdump input fails closed"

unset FWLIVE_SDK_APK_IMAGE
pin='ghcr.io/openwrt/sdk@sha256:dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444'
cache="$(sdk_matrix_digest_cache_path x86-64 25.12)"
printf '%s\n' "$pin" >"$cache"
got="$(sdk_apk_image x86-64 25.12)"
[[ "$got" == "$pin" ]] || fail "sdk_apk_image must use a repository-qualified digest pin (got '$got')"
: >"$FWLIVE_DOCKER_LOG"
sdk_apk_adbdump --format json "$pkg" >/dev/null
grep -Fq "$pin" "$FWLIVE_DOCKER_LOG" \
	|| fail "sdk_apk_run must pass the cached repository digest to docker"
ok "sdk_apk_image uses a repository-qualified digest cache pin"

id_only='@sha256:feedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeed'
printf '%s\n' "$id_only" >"$cache"
got="$(sdk_apk_image x86-64 25.12)"
[[ "$got" == "$id_only" ]] && fail "sdk_apk_image must not use an image-ID-only digest pin"
[[ "$got" == ghcr.io/openwrt/sdk:* ]] || fail "image-ID-only pin must fall back to SDK_MATRIX_IMAGE (got '$got')"
: >"$FWLIVE_DOCKER_LOG"
sdk_apk_adbdump --format json "$pkg" >/dev/null
grep -Fq "$got" "$FWLIVE_DOCKER_LOG" \
	|| fail "sdk_apk_run must pass the tag fallback, not an image-ID-only digest"
grep -Fq '@sha256:feedfeed' "$FWLIVE_DOCKER_LOG" \
	&& fail "sdk_apk_run must not pass an image-ID-only digest to docker"
ok "sdk_apk_image rejects image-ID-only digest cache pins"

echo "sdk-apk helper test passed"
