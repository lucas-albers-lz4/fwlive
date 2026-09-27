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

extra="$(feed_publish_assert_staging_clearable "feed-staging-extra" 0)"
[[ "$extra" == "${root_phys}/feed-staging-extra" ]] || fail "feed-staging-* (got '$extra')"

assert_refused "${ROOT}/scripts"
assert_refused "${ROOT}/scripts" 1
assert_refused scripts
ln -s "${ROOT}/scripts" "${linkdir}/scriptslink"
assert_refused "${linkdir}/scriptslink" 0
assert_refused "${linkdir}/scriptslink" 1

fixture="$(mktemp -d)"
refuse_parent=""
trap 'rm -rf "$outside" "$runner_tmp" "$linkdir" "$fixture" ${refuse_parent:+"$refuse_parent"}' EXIT
mkdir -p "${fixture}/out/cell" "${fixture}/scripts"
FEED_PUBLISH_ROOT="$fixture"
export FEED_PUBLISH_ROOT
fixture_phys="$(cd "$fixture" && pwd -P)"
out_ok="$(feed_publish_assert_staging_clearable "${fixture}/out/cell" 0)"
[[ "$out_ok" == "${fixture_phys}/out/cell" ]] || fail "out/ staging (got '$out_ok')"
assert_refused "${fixture}/out"
assert_refused "${fixture}/scripts"
assert_refused "${fixture}/scripts" 1
unset FEED_PUBLISH_ROOT

refuse_parent="$(mktemp -d)"
refuse_target="${refuse_parent}/not-created"
if "${ROOT}/scripts/publish-packages.sh" "$refuse_target" >/dev/null 2>"${refuse_parent}/err"; then
	fail "outside staging without --allow-outside should fail"
fi
[[ ! -e "$refuse_target" ]] || fail "refused staging path was created"
if "${ROOT}/scripts/publish-packages.sh" feed-staging other >/dev/null 2>"${refuse_parent}/extra.err"; then
	fail "extra positional should fail"
fi
grep -q "extra positional" "${refuse_parent}/extra.err" || fail "extra positional message"

ipkg_err="${refuse_parent}/ipkg.err"
if feed_publish_ipkg_index_script '24.10.99' >/dev/null 2>"$ipkg_err"; then
	fail "unknown ipkg label should fail"
fi
grep -q "unmapped ipkg index label" "$ipkg_err" || fail "unknown ipkg label message"
ipkg_fn="$(awk '/^feed_publish_ipkg_index_script\(\)/,/^}/' "${ROOT}/scripts/lib/feed-publish.sh")"
while IFS= read -r label; do
	[[ -n "$label" ]] || continue
	grep -q "${label})" <<<"$ipkg_fn" || fail "ipkg pin missing explicit row for ${label}"
done < <(sdk_matrix_release_version_labels)
if grep -Eq '^[[:space:]]*\*\)[[:space:]]*sha=' <<<"$ipkg_fn"; then
	fail "ipkg index still has a silent default pin"
fi

echo "feed publish staging allowlist test passed"
