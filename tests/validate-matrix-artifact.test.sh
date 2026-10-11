#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Use the real matrix helpers but redirect their root to an isolated fixture.
# shellcheck source=../scripts/lib/validate-matrix.sh
source "$ROOT/scripts/lib/validate-matrix.sh"
MATRIX_ROOT="$TMP/root"
validate_matrix_root() { printf '%s' "$MATRIX_ROOT"; }
sdk_matrix_root() { printf '%s' "$MATRIX_ROOT"; }
mkdir -p "$MATRIX_ROOT/scripts" "$MATRIX_ROOT/out/x86_64/24.10.8/fwlive"

cat >"$MATRIX_ROOT/scripts/docker-sdk.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target=
version=
while [[ $# -gt 0 ]]; do
	case "$1" in
		--target) target="$2"; shift 2 ;;
		--version) version="$2"; shift 2 ;;
		*) shift ;;
	esac
done
case "$target" in
	armsr-armv8) arch=aarch64_generic ;;
	x86-64) arch=x86_64 ;;
	*) exit 2 ;;
esac
case "$version" in
	24.10) label=24.10.8 ;;
	*) label="$version" ;;
esac
dest="$FWLIVE_MATRIX_ROOT/out/$arch/$label/fwlive"
mkdir -p "$dest"
printf 'fresh artifact from %s/%s\n' "$target" "$version" \
	>"$dest/luci-app-fwlive_0.1.49-r1_all.ipk"
EOF

cat >"$MATRIX_ROOT/scripts/qemu-install-fwlive.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'arch=%s version=%s\n' "${OWRT_FWLIVE_ARCH:-}" "${OWRT_FWLIVE_VERSION:-}" \
	>"$FWLIVE_INSTALL_LOG.env"
printf '%s\n' "$@" >"$FWLIVE_INSTALL_LOG.args"
EOF
chmod +x "$MATRIX_ROOT/scripts/docker-sdk.sh" "$MATRIX_ROOT/scripts/qemu-install-fwlive.sh"

# A stale guest-architecture artifact is present before the SDK build.
printf 'stale x86 artifact\n' \
	>"$MATRIX_ROOT/out/x86_64/24.10.8/fwlive/luci-app-fwlive_0.1.48-r1_all.ipk"
export FWLIVE_MATRIX_ROOT="$MATRIX_ROOT"
export FWLIVE_INSTALL_LOG="$TMP/install"

validate_matrix_sdk_build armsr-armv8 24.10
expected="$MATRIX_ROOT/out/aarch64_generic/24.10.8/fwlive/luci-app-fwlive_0.1.49-r1_all.ipk"
[[ "$VALIDATE_MATRIX_BUILT_ARTIFACT" == "$expected" ]] \
	|| { echo "wrong build artifact: $VALIDATE_MATRIX_BUILT_ARTIFACT" >&2; exit 1; }
validate_matrix_install_ipk 24.10.8 x86 "$VALIDATE_MATRIX_BUILT_ARTIFACT"
grep -Fqx -- '--artifact-only' "$FWLIVE_INSTALL_LOG.args"
grep -Fqx -- "$expected" "$FWLIVE_INSTALL_LOG.args"
grep -Fq "version=24.10.8" "$FWLIVE_INSTALL_LOG.env"
if grep -Fq '/out/x86_64/' "$FWLIVE_INSTALL_LOG.args"; then
	echo 'validation installed a stale x86 artifact instead of the build output' >&2
	exit 1
fi

# --skip-build still selects exactly one artifact from the requested SDK cell.
mkdir -p "$MATRIX_ROOT/lab"
printf 'fixture image\n' >"$MATRIX_ROOT/lab/image.img"
validate_matrix_image_path() { printf '%s' "$MATRIX_ROOT/lab/image.img"; }
qemu_lab_require_ss() { return 0; }
validate_matrix_prepare_image() { :; }
validate_matrix_start_qemu() { :; }
validate_matrix_wait_ssh() { :; }
validate_matrix_smoke() { :; }
validate_matrix_stop_qemu() { :; }
validate_matrix_install_ipk() { printf '%s' "${3:-}" >"$MATRIX_ROOT/installed-artifact"; }
validate_matrix_run_cell 24.10 x86 armsr-armv8 1
[[ "$(<"$MATRIX_ROOT/installed-artifact")" == "$expected" ]] \
	|| { echo 'skip-build did not install the exact SDK-cell artifact' >&2; exit 1; }

printf 'stale artifact\n' >"$MATRIX_ROOT/out/aarch64_generic/24.10.8/fwlive/luci-app-fwlive_0.1.48-r1_all.ipk"
if ( validate_matrix_select_cell_artifact armsr-armv8 24.10 ) >/dev/null 2>"$TMP/multiple.err"; then
	echo 'artifact selector accepted multiple packages in a matrix cell' >&2
	exit 1
fi
rm -f "$MATRIX_ROOT/out/aarch64_generic/24.10.8/fwlive/luci-app-fwlive_0.1.48-r1_all.ipk"

mkdir -p "$MATRIX_ROOT/out/aarch64_generic/25.12.5/fwlive"
apk="$MATRIX_ROOT/out/aarch64_generic/25.12.5/fwlive/luci-app-fwlive-0.1.49-r1.apk"
printf 'apk artifact\n' >"$apk"
[[ "$(validate_matrix_select_cell_artifact armsr-armv8 25.12)" == "$apk" ]] \
	|| { echo 'artifact selector failed to select the APK cell artifact' >&2; exit 1; }
rm -f "$expected"
if ( validate_matrix_select_cell_artifact armsr-armv8 24.10 ) >/dev/null 2>"$TMP/missing.err"; then
	echo 'artifact selector accepted a missing package' >&2
	exit 1
fi

# Exercise the production sdk_matrix_make cleanup path with artifacts stale
# in the same builder architecture/cell, before the simulated compile starts.
sdk_matrix_resolve x86-64 24.10
BUILDER_ROOT="$TMP/builder"
builder_pkg="$BUILDER_ROOT/bin/packages/$SDK_MATRIX_PACKAGE_ARCH"
mkdir -p "$builder_pkg/fwlive"
printf stale >"$builder_pkg/luci-app-fwlive_0.1.48_all.ipk"
printf stale >"$builder_pkg/fwlive/luci-app-fwlive-0.1.48-r1.apk"
printf stale >"$builder_pkg/fwlive/luci-app-fwlive_0.1.48-r1.apk"
printf keep >"$builder_pkg/fwlive/unrelated_1.0_all.ipk"
sdk_matrix_feeds_ready() { return 0; }
sdk_matrix_clean_package() { return 0; }
sdk_matrix_cache_dirs() {
	SDK_MATRIX_DL_CACHE="$TMP/dl"
	SDK_MATRIX_FEEDS_CACHE="$TMP/feeds"
}
BUILD_STARTED_FILE="$TMP/build-started"
docker() {
	[[ "$1 $2 $3 $4" == 'compose run --rm sdk' ]] \
		|| { echo "unexpected docker invocation: $*" >&2; return 1; }
	case "${7:-}" in
		*'for dir in'*'/builder/bin/packages/'*)
			cleanup_script="${7//\/builder/$BUILDER_ROOT}"
			bash -ec "$cleanup_script" "${8:-}" "${9:-}"
			;;
		*'make package/luci-app-fwlive/compile'*)
			for dir in "$builder_pkg" "$builder_pkg/fwlive"; do
				if compgen -G "$dir/luci-app-fwlive_*.ipk" >/dev/null \
					|| compgen -G "$dir/luci-app-fwlive_*.apk" >/dev/null \
					|| compgen -G "$dir/luci-app-fwlive-*.apk" >/dev/null; then
					echo "stale fwlive package reached compile: $dir" >&2
					return 1
				fi
			done
			: >"$BUILD_STARTED_FILE"
			;;
		*) echo "unexpected SDK command: ${7:-}" >&2; return 1 ;;
	esac
}
sdk_matrix_make -j1
[[ -f "$BUILD_STARTED_FILE" ]] || { echo 'sdk_matrix_make did not reach compile' >&2; exit 1; }
[[ -f "$builder_pkg/fwlive/unrelated_1.0_all.ipk" ]] \
	|| { echo 'SDK cleanup removed an unrelated package' >&2; exit 1; }

echo 'validate-matrix exact artifact selection tests passed'
