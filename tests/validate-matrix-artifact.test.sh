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

# Explicit --skip-build retains the helper's documented artifact discovery path.
validate_matrix_install_ipk 24.10.8 x86
[[ "$(wc -l <"$FWLIVE_INSTALL_LOG.args")" -eq 1 ]] \
	|| { echo 'skip-build unexpectedly received a build artifact path' >&2; exit 1; }
echo 'validate-matrix exact build artifact test passed'
