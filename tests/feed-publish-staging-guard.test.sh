#!/usr/bin/env bash
# Guard: publish-packages must not rm -rf /, $HOME, repo root, or outside paths (#766).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/feed-publish.sh
source "${ROOT}/scripts/lib/feed-publish.sh"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

assert_refused() {
	local path="$1" allow="${2:-0}"
	if feed_publish_assert_staging_clearable "$path" "$allow" >/dev/null 2>&1; then
		fail "expected refuse for '$path' allow=$allow"
	fi
}

outside="$(mktemp -d)"
runner_tmp="$(mktemp -d)"
linkdir="$(mktemp -d)"
trap 'rm -rf "$outside" "$runner_tmp" "$linkdir"' EXIT

inside="$(feed_publish_assert_staging_clearable "feed-staging" 0)"
root_phys="$(cd "$ROOT" && pwd -P)"
want_inside="${root_phys}/feed-staging"
if [[ -d "${ROOT}/feed-staging" ]]; then
	want_inside="$(cd "${ROOT}/feed-staging" && pwd -P)"
fi
[[ "$inside" == "$want_inside" ]] || fail "in-repo staging (got '$inside')"

assert_refused ""
assert_refused /
assert_refused "$ROOT"
assert_refused / 1
assert_refused "$ROOT" 1
if [[ -n "${HOME:-}" && -d "$HOME" ]]; then
	assert_refused "$HOME"
	assert_refused "$HOME" 1
fi

assert_refused "$outside" 0
allowed="$(feed_publish_assert_staging_clearable "$outside" 1)"
outside_phys="$(cd "$outside" && pwd -P)"
[[ "$allowed" == "$outside_phys" ]] || fail "allow-outside (got '$allowed')"

ln -s / "${linkdir}/rootlink"
assert_refused "${linkdir}/rootlink" 0
assert_refused "${linkdir}/rootlink" 1

RUNNER_TEMP="$runner_tmp"
export RUNNER_TEMP
runner_stage="$(feed_publish_assert_staging_clearable "${RUNNER_TEMP}/stage" 0)"
[[ "$runner_stage" == "$(cd "$runner_tmp" && pwd -P)/stage" ]] ||
	fail "RUNNER_TEMP staging (got '$runner_stage')"

echo "feed publish staging guard test passed"
