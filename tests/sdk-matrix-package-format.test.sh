#!/usr/bin/env bash
# Guard the SDK-version → package-manager mapping used by package gates.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/sdk-matrix.sh"

test "$(sdk_matrix_package_format 24.10)" = ipk
test "$(sdk_matrix_package_format 24.10.8)" = ipk
test "$(sdk_matrix_package_format 25.12)" = apk
test "$(sdk_matrix_package_format 25.12.5)" = apk
test "$(sdk_matrix_package_format snapshot)" = apk

if sdk_matrix_package_format unsupported >/dev/null 2>&1; then
	echo "unsupported SDK version unexpectedly has a package format" >&2
	exit 1
fi

echo "sdk matrix package format test passed"
