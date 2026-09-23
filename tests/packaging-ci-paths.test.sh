#!/usr/bin/env bash
# Host tests for the test-ipk-payload path gate (#557).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/packaging-ci-paths.sh
source "$ROOT/scripts/lib/packaging-ci-paths.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

expect_match() {
	local path="$1"
	if packaging_ci_path_matches "$path"; then
		ok "match $path"
	else
		bad "expected match: $path"
	fi
}

expect_skip() {
	local path="$1"
	if packaging_ci_path_matches "$path"; then
		bad "expected skip: $path"
	else
		ok "skip $path"
	fi
}

expect_match openwrt-feed/luci-app-fwlive/Makefile
expect_match scripts/feeds.lock/24.10.8/feeds.conf
expect_match scripts/lib/feeds-lock.sh
expect_match scripts/lib/sdk-matrix.sh
expect_match scripts/lib/packaging-ci-paths.sh
expect_match scripts/docker-sdk.sh
expect_match scripts/ci-packaging-paths.sh
expect_match docker-compose.yml
expect_match tests/fwlive-package-payload.test.sh
expect_match tests/fwlive-package-lifecycle.test.sh
expect_match tests/fwlive-package-payload-apk-host.test.sh
expect_match .github/workflows/fwlive-test.yml
expect_match ./openwrt-feed/root/usr/libexec/rpcd/fwlive

expect_skip docs/developer/security-review.md
expect_skip tests/fwlive-ipk-payload.test.sh
expect_skip scripts/lib/feed-keys.sh
expect_skip .github/workflows/publish-packages.yml
expect_skip README.md

job_block="$(awk '
	/^  test-ipk-payload:/ { p=1; print; next }
	/^  [A-Za-z0-9_-]+:/ { if (p) exit }
	p { print }
' "$ROOT/.github/workflows/fwlive-test.yml")"
if printf '%s\n' "$job_block" | grep -qE '^    if:'; then
	bad "test-ipk-payload job must not have an if: (required check)"
else
	ok "test-ipk-payload job is unconditional"
fi
if printf '%s\n' "$job_block" | grep -c 'steps.packaging.outputs.run_matrix != .false.' | grep -qx 2; then
	ok "SDK build and inspect steps are gated"
else
	bad "expected both SDK steps to gate on packaging.outputs.run_matrix"
fi

if packaging_ci_sha_usable ""; then
	bad "empty SHA must be unusable"
else
	ok "empty SHA is unusable"
fi
if packaging_ci_sha_usable "0000000000000000000000000000000000000000"; then
	bad "all-zero SHA must be unusable"
else
	ok "all-zero SHA is unusable"
fi
if packaging_ci_sha_usable "abc"; then
	bad "short SHA must be unusable"
else
	ok "short SHA is unusable"
fi
if packaging_ci_sha_usable "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; then
	ok "40-hex SHA is usable"
else
	bad "40-hex SHA should be usable"
fi

ZERO="0000000000000000000000000000000000000000"
out="$(PACKAGING_CI_BASE_SHA="" PACKAGING_CI_HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" packaging_ci_decide)"
if [[ "$out" == "run_matrix=true" ]]; then
	ok "empty base SHA fail-closed runs matrix"
else
	bad "empty base SHA: got $out"
fi

out="$(PACKAGING_CI_BASE_SHA="$ZERO" PACKAGING_CI_HEAD_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" packaging_ci_decide)"
if [[ "$out" == "run_matrix=true" ]]; then
	ok "all-zero base SHA fail-closed runs matrix"
else
	bad "all-zero base SHA: got $out"
fi

out="$(PACKAGING_CI_BASE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" PACKAGING_CI_HEAD_SHA="" packaging_ci_decide)"
if [[ "$out" == "run_matrix=true" ]]; then
	ok "empty head SHA fail-closed runs matrix"
else
	bad "empty head SHA: got $out"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

git -C "$WORKDIR" init -q
git -C "$WORKDIR" config user.email test@example.com
git -C "$WORKDIR" config user.name test
git -C "$WORKDIR" config commit.gpgsign false

mkdir -p "$WORKDIR/docs"
printf 'a\n' >"$WORKDIR/docs/note.md"
git -C "$WORKDIR" add docs/note.md
git -C "$WORKDIR" commit -q -m base
base="$(git -C "$WORKDIR" rev-parse HEAD)"

printf 'b\n' >"$WORKDIR/docs/note.md"
git -C "$WORKDIR" add docs/note.md
git -C "$WORKDIR" commit -q -m docs-only
head_docs="$(git -C "$WORKDIR" rev-parse HEAD)"

out="$(
	cd "$WORKDIR"
	PACKAGING_CI_BASE_SHA="$base" PACKAGING_CI_HEAD_SHA="$head_docs" packaging_ci_decide
)"
if [[ "$out" == "run_matrix=false" ]]; then
	ok "docs-only diff skips matrix"
else
	bad "docs-only diff: got $out"
fi

mkdir -p "$WORKDIR/openwrt-feed"
printf 'pkg\n' >"$WORKDIR/openwrt-feed/Makefile"
git -C "$WORKDIR" add openwrt-feed/Makefile
git -C "$WORKDIR" commit -q -m packaging
head_pkg="$(git -C "$WORKDIR" rev-parse HEAD)"

out="$(
	cd "$WORKDIR"
	PACKAGING_CI_BASE_SHA="$head_docs" PACKAGING_CI_HEAD_SHA="$head_pkg" packaging_ci_decide
)"
if [[ "$out" == "run_matrix=true" ]]; then
	ok "openwrt-feed diff runs matrix"
else
	bad "openwrt-feed diff: got $out"
fi

mkdir -p "$WORKDIR/docs"
git -C "$WORKDIR" mv openwrt-feed/Makefile docs/Makefile
git -C "$WORKDIR" commit -q -m move-out
head_move="$(git -C "$WORKDIR" rev-parse HEAD)"
out="$(
	cd "$WORKDIR"
	PACKAGING_CI_BASE_SHA="$head_pkg" PACKAGING_CI_HEAD_SHA="$head_move" packaging_ci_decide
)"
if [[ "$out" == "run_matrix=true" ]]; then
	ok "rename out of openwrt-feed still runs matrix"
else
	bad "rename out of openwrt-feed: got $out"
fi

mkdir -p "$WORKDIR/openwrt-feed"
printf 'space\n' >"$WORKDIR/openwrt-feed/weird name.sh"
git -C "$WORKDIR" add "openwrt-feed/weird name.sh"
git -C "$WORKDIR" commit -q -m spaced-name
head_space="$(git -C "$WORKDIR" rev-parse HEAD)"
out="$(
	cd "$WORKDIR"
	PACKAGING_CI_BASE_SHA="$head_move" PACKAGING_CI_HEAD_SHA="$head_space" packaging_ci_decide
)"
if [[ "$out" == "run_matrix=true" ]]; then
	ok "packaging path with a space runs matrix"
else
	bad "packaging path with a space: got $out"
fi

missing="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
out="$(
	cd "$WORKDIR"
	PACKAGING_CI_BASE_SHA="$missing" PACKAGING_CI_HEAD_SHA="$head_pkg" packaging_ci_decide
)"
if [[ "$out" == "run_matrix=true" ]]; then
	ok "unfetchable base SHA fail-closed runs matrix"
else
	bad "unfetchable base SHA: got $out"
fi

if [[ "$fail" -ne 0 ]]; then
	echo "packaging-ci-paths test FAILED" >&2
	exit 1
fi
echo "packaging-ci-paths test passed"
