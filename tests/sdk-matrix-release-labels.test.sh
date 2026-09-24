#!/usr/bin/env bash
# Guard release-cell patch labels used by publish cache-dir pre-create (#519).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/sdk-matrix.sh"

mapfile -t labels < <(sdk_matrix_release_version_labels | sort)
test "${#labels[@]}" -eq 3
test "${labels[0]}" = 23.05.5
test "${labels[1]}" = 24.10.8
test "${labels[2]}" = 25.12.5

for label in "${labels[@]}"; do
	if [[ "$label" == snapshot ]]; then
		echo "snapshot must not appear in release version labels" >&2
		exit 1
	fi
done

test "$(sdk_matrix_version_label 23.05)" = 23.05.5
test "$(sdk_matrix_version_label 24.10)" = 24.10.8
test "$(sdk_matrix_version_label 25.12)" = 25.12.5

# Known labels and patch forms must still pass (#637).
for ver in snapshot latest SNAPSHOT 25.12 24.10 23.05 25.12.5 24.10.8 23.05.5; do
	if ! sdk_matrix_validate_version "$ver" >/dev/null 2>&1; then
		echo "known version unexpectedly rejected: $ver" >&2
		exit 1
	fi
done

# Unknown versions must fail immediately with the usage hint (#637).
# These currently pass on master because validate compared $1 to patch($1).
for ver in foo 99.99; do
	err=""
	if err="$(sdk_matrix_validate_version "$ver" 2>&1)"; then
		echo "unknown version unexpectedly accepted: $ver" >&2
		exit 1
	fi
	case "$err" in
		*"invalid --version ${ver}"*"choose: ${SDK_MATRIX_VERSIONS[*]}"*) ;;
		*)
			echo "unknown version missing usage hint: $ver ($err)" >&2
			exit 1
			;;
	esac
done

echo "sdk matrix release version labels test passed"
