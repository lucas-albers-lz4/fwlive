#!/usr/bin/env bash
# Guard: publish/verify release-line loops match sdk-matrix keys (#745).
# Does not centralize the lists; a mismatch fails CI so a line add/drop is noticed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/sdk-matrix.sh"

# Non-snapshot cells are the publish/verify release lines (23.05 24.10 25.12).
expected=""
for v in "${SDK_MATRIX_VERSIONS[@]}"; do
	case "$v" in
		snapshot | SNAPSHOT | latest | '') continue ;;
	esac
	expected+="${v}"$'\n'
done
expected="$(printf '%s' "$expected" | LC_ALL=C sort -u)"
test -n "$expected"

# Keys of sdk_matrix_release_version_labels must be the same set.
from_labels="$(
	sdk_matrix_release_version_labels |
		sed -E 's/^([0-9]+\.[0-9]+)\.[0-9]+$/\1/' |
		LC_ALL=C sort -u
)"
if [[ "$from_labels" != "$expected" ]]; then
	echo "FAIL: sdk_matrix_release_version_labels keys [${from_labels//$'\n'/ }] != SDK_MATRIX_VERSIONS [${expected//$'\n'/ }]" >&2
	exit 1
fi

# Non-comment OpenWrt line tokens (NN.NN, not patch NN.NN.N).
extract_release_lines() {
	local file="$1"
	sed -E '/^[[:space:]]*#/d; s/[[:space:]]+#.*//' "$file" |
		tr -c '0-9.\n' '\n' |
		grep -E '^2[0-9]\.[0-9]{2}$' |
		LC_ALL=C sort -u || true
}

assert_file_matches_matrix() {
	local file="$1" got
	got="$(extract_release_lines "$file")"
	if [[ "$got" != "$expected" ]]; then
		echo "FAIL: $file release lines [${got//$'\n'/ }] != matrix [${expected//$'\n'/ }]" >&2
		exit 1
	fi
}

assert_file_matches_matrix "$ROOT/scripts/lib/feed-publish.sh"
assert_file_matches_matrix "$ROOT/scripts/publish-packages.sh"
assert_file_matches_matrix "$ROOT/scripts/verify-reproducible-build.sh"
assert_file_matches_matrix "$ROOT/scripts/wait-feed-pages.sh"
# Workflows duplicate the same loops; read-only check, no workflow rewrite.
assert_file_matches_matrix "$ROOT/.github/workflows/publish-packages.yml"
assert_file_matches_matrix "$ROOT/.github/workflows/fwlive-test.yml"

echo "sdk matrix release-line parity test passed"
