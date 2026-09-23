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

echo "sdk matrix release version labels test passed"
