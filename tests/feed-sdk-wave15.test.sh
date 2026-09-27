#!/usr/bin/env bash
# Host proof: build-all filter, mkhash probe isolation, trap restore (#814 #813 #812).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"
# shellcheck source=scripts/lib/validate-matrix.sh
source "${ROOT}/scripts/lib/validate-matrix.sh"
# shellcheck source=scripts/lib/feed-keys.sh
source "${ROOT}/scripts/lib/feed-keys.sh"

fail() {
	echo "feed-sdk-wave15 FAIL: $*" >&2
	exit 1
}

unset OWRT_SDK_TARGET OWRT_SDK_VERSION
SDK="$ROOT/scripts/docker-sdk.sh"
[[ -x "$SDK" ]] || fail "docker-sdk.sh missing"
bash -n "$SDK" || fail "docker-sdk.sh syntax"
bash -n "$ROOT/scripts/wait-feed-pages.sh" || fail "wait-feed-pages.sh syntax"

# Explicit default-valued flags must still filter (#813).
cells="$("$SDK" list-cells --target armsr-armv8 --version snapshot)"
[[ "$cells" == "armsr-armv8 snapshot" ]] || fail "explicit default cell: $cells"
if [[ "$(printf '%s\n' "$cells" | wc -l)" -ne 1 ]]; then
	fail "explicit --target/--version must be one cell"
fi

all="$("$SDK" list-cells)"
all_n="$(printf '%s\n' "$all" | grep -c . || true)"
[[ "$all_n" -gt 1 ]] || fail "unfiltered list-cells must print the matrix (got $all_n)"

x86="$("$SDK" list-cells --target x86-64)"
printf '%s\n' "$x86" | grep -q '^x86-64 ' || fail "filtered target: $x86"
if printf '%s\n' "$x86" | grep -q '^armsr-armv8 '; then
	fail "--target x86-64 must not include armsr"
fi

# An inherited legacy print-cells variable must not turn build-all into a no-op.
tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT
mkdir -p "$tmpd/fakebin"
cat >"$tmpd/fakebin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_CALLS_FILE"
exit 42
EOF
chmod +x "$tmpd/fakebin/docker"
if FWLIVE_SDK_PRINT_CELLS=1 DOCKER_CALLS_FILE="$tmpd/docker.calls" PATH="$tmpd/fakebin:$PATH" \
	"$SDK" build-all --target armsr-armv8 --version snapshot >"$tmpd/build-all.log" 2>&1; then
	fail "inherited print-cells variable must not let build-all succeed without building"
fi
grep -Fq 'pull ghcr.io/openwrt/sdk:armsr-armv8' "$tmpd/docker.calls" \
	|| fail "build-all did not attempt the selected SDK build"

# mkhash probe must not clobber caller SDK_MATRIX_* (#814).
SDK_MATRIX_TARGET=sentinel-target
SDK_MATRIX_VERSION=sentinel-version
SDK_MATRIX_IMAGE=sentinel-image
SDK_MATRIX_VOLUME=sentinel-volume
SDK_MATRIX_OUT_DIR=sentinel-out
# Command substitution isolates resolve side effects.
_="$(feed_publish_probe_mkhash)" || true
[[ "$SDK_MATRIX_TARGET" == sentinel-target ]] || fail "probe leaked TARGET=$SDK_MATRIX_TARGET"
[[ "$SDK_MATRIX_VERSION" == sentinel-version ]] || fail "probe leaked VERSION=$SDK_MATRIX_VERSION"
[[ "$SDK_MATRIX_IMAGE" == sentinel-image ]] || fail "probe leaked IMAGE=$SDK_MATRIX_IMAGE"
[[ "$SDK_MATRIX_VOLUME" == sentinel-volume ]] || fail "probe leaked VOLUME=$SDK_MATRIX_VOLUME"
[[ "$SDK_MATRIX_OUT_DIR" == sentinel-out ]] || fail "probe leaked OUT_DIR=$SDK_MATRIX_OUT_DIR"
grep -Fq 'mkhash="$(feed_publish_probe_mkhash)"' "$ROOT/scripts/lib/feed-publish.sh" \
	|| fail "stage_opkg_host must capture probe via command substitution"

# Caller RETURN trap survives feed_keys normalize (#812).
marker="$tmpd/return-fired"
: >"$tmpd/key"
# One-line usign paste so normalize takes the rewrite path.
printf '%s\n' 'untrusted comment: fwlive test secret RWabcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUV' \
	>"$tmpd/key"
return_count=0
note_return() { return_count=$((return_count + 1)); echo fired >"$marker"; }
trap note_return RETURN
feed_keys_normalize_usign_keyfile "$tmpd/key" || fail "normalize failed"
# Invoking a function fires RETURN once for that function; our note_return
# must still be the trap afterwards.
trap -p RETURN | grep -Fq note_return || fail "caller RETURN trap was clobbered: $(trap -p RETURN)"
trap - RETURN

# Caller EXIT trap survives a successful run_cell restore path (source check).
grep -Fq 'prev_exit="$(trap -p EXIT)"' "$ROOT/scripts/lib/validate-matrix.sh" \
	|| fail "run_cell must save the EXIT trap"
grep -Fq 'eval "$prev_exit"' "$ROOT/scripts/lib/validate-matrix.sh" \
	|| fail "run_cell must restore the EXIT trap"
if grep -Fq 'trap - EXIT' "$ROOT/scripts/lib/validate-matrix.sh"; then
	# Allowed only as the empty-prev fallback.
	grep -Fq 'trap - EXIT' "$ROOT/scripts/lib/validate-matrix.sh"
fi
grep -Fq 'prev_return="$(trap -p RETURN)"' "$ROOT/scripts/lib/feed-publish.sh" \
	|| fail "stage_opkg_host must save the RETURN trap"

echo "feed-sdk-wave15 (#814 #813 #812) passed"
