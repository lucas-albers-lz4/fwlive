#!/usr/bin/env bash
# Host tests for the always-reporting formal-tlc path gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/formal-ci-paths.sh
source "$ROOT/scripts/lib/formal-ci-paths.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

expect_class() {
	local expected="$1" path="$2" actual
	actual="$(formal_ci_classify_path "$path")"
	if [[ "$actual" == "$expected" ]]; then ok "$expected $path"; else bad "$path: expected $expected, got $actual"; fi
}

expect_class relevant formal/wan-log-lock/WanLogRollbackOutcomes.tla
expect_class relevant formal/new-model/NewModel.cfg
expect_class relevant scripts/formal-tlc.sh
expect_class relevant scripts/formal-rollback-trace-replay.sh
expect_class relevant scripts/formal-rollback-trace-project.py
expect_class relevant scripts/lib/formal-ci-paths.sh
expect_class relevant scripts/ci-formal-paths.sh
expect_class relevant scripts/formal-quint.sh
expect_class relevant scripts/formal-quint-replay.js
expect_class relevant tests/formal-ci-paths.test.sh
expect_class relevant tests/formal-quint-replay.test.js
expect_class relevant tests/model-checker-contract.test.js
expect_class relevant tests/fwlive-rollback-trace-capture.sh
expect_class relevant tests/mutate-wan-log-noop-generation.py
expect_class relevant tests/fwlive-hostname-cache.test.js
expect_class relevant tests/fwlive-poll-coordinator.test.js
expect_class relevant tests/fwlive-view-poll-guard.test.js
expect_class relevant tests/fwlive-adaptive-cap.test.sh
expect_class relevant tests/fwlive-logging-lock.test.sh
expect_class relevant .github/workflows/formal-tlc.yml
expect_class relevant .github/workflows/formal-quint.yml
expect_class relevant package.json
expect_class relevant package-lock.json
expect_class relevant openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-logging.sh
expect_class relevant openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-adaptive-cap.sh
expect_class relevant openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js
expect_class relevant openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/hostname.js
expect_class relevant openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/poll-coordinator.js
expect_class unrelated docs/developer/security-review.md
expect_class unrelated docs/user/installation.md
expect_class unrelated tests/fwlive-parser.test.js
expect_class unrelated scripts/embed-fwlive-css.js
expect_class unclassified .github/workflows/fwlive-test.yml
expect_class unclassified openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/new-module.js

ZERO="0000000000000000000000000000000000000000"
expect_decision() {
	local expected="$1" base="$2" head="$3" output
	output="$(FORMAL_CI_BASE_SHA="$base" FORMAL_CI_HEAD_SHA="$head" formal_ci_decide)"
	if [[ "$output" == "run_formal=$expected" ]]; then ok "decision $expected"; else bad "expected run_formal=$expected, got: $output"; fi
}

expect_decision true "" HEAD
expect_decision true "$ZERO" HEAD
expect_decision true aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ""

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
git -C "$WORKDIR" init -q
git -C "$WORKDIR" config user.email test@example.com
git -C "$WORKDIR" config user.name test
git -C "$WORKDIR" config commit.gpgsign false

mkdir -p "$WORKDIR/docs" "$WORKDIR/tests" "$WORKDIR/formal/wan-log-lock"
printf 'a\n' >"$WORKDIR/docs/note.md"
printf 'old\n' >"$WORKDIR/tests/unrelated.test.sh"
printf 'model\n' >"$WORKDIR/formal/wan-log-lock/Model.tla"
git -C "$WORKDIR" add .
git -C "$WORKDIR" commit -q -m base
base="$(git -C "$WORKDIR" rev-parse HEAD)"

printf 'b\n' >"$WORKDIR/docs/note.md"
git -C "$WORKDIR" add docs/note.md
git -C "$WORKDIR" commit -q -m docs-only
head_docs="$(git -C "$WORKDIR" rev-parse HEAD)"
out="$(cd "$WORKDIR" && FORMAL_CI_BASE_SHA="$base" FORMAL_CI_HEAD_SHA="$head_docs" formal_ci_decide)"
if [[ "$out" == 'run_formal=false' ]]; then ok 'known unrelated diff skips'; else bad "docs-only diff: $out"; fi
out="$(cd "$WORKDIR" && FORMAL_CI_BASE_SHA="$head_docs" FORMAL_CI_HEAD_SHA="$head_docs" formal_ci_decide)"
if [[ "$out" == 'run_formal=true' ]]; then ok 'empty diff fails closed'; else bad "empty diff: $out"; fi

printf 'new\n' >"$WORKDIR/formal/wan-log-lock/NewModel.cfg"
git -C "$WORKDIR" add formal/wan-log-lock/NewModel.cfg
git -C "$WORKDIR" commit -q -m add-model
head_new="$(git -C "$WORKDIR" rev-parse HEAD)"
out="$(cd "$WORKDIR" && FORMAL_CI_BASE_SHA="$head_docs" FORMAL_CI_HEAD_SHA="$head_new" formal_ci_decide)"
if [[ "$out" == 'run_formal=true' ]]; then ok 'new relevant file runs'; else bad "new relevant file: $out"; fi

git -C "$WORKDIR" rm -q formal/wan-log-lock/NewModel.cfg
git -C "$WORKDIR" commit -q -m delete-model
head_deleted="$(git -C "$WORKDIR" rev-parse HEAD)"
out="$(cd "$WORKDIR" && FORMAL_CI_BASE_SHA="$head_new" FORMAL_CI_HEAD_SHA="$head_deleted" formal_ci_decide)"
if [[ "$out" == 'run_formal=true' ]]; then ok 'deleted relevant file runs'; else bad "deleted relevant file: $out"; fi

mkdir -p "$WORKDIR/openwrt-feed/luci-app-fwlive"
printf 'future\n' >"$WORKDIR/openwrt-feed/luci-app-fwlive/unknown-model-source.js"
git -C "$WORKDIR" add openwrt-feed/luci-app-fwlive/unknown-model-source.js
git -C "$WORKDIR" commit -q -m add-unclassified-source
head_unknown="$(git -C "$WORKDIR" rev-parse HEAD)"
out="$(cd "$WORKDIR" && FORMAL_CI_BASE_SHA="$head_deleted" FORMAL_CI_HEAD_SHA="$head_unknown" formal_ci_decide)"
if [[ "$out" == 'run_formal=true' ]]; then ok 'unclassified diff runs'; else bad "unclassified path: $out"; fi

mkdir -p "$WORKDIR/docs"
git -C "$WORKDIR" mv formal/wan-log-lock/Model.tla docs/Model.tla
git -C "$WORKDIR" commit -q -m move-out-of-formal
head_move="$(git -C "$WORKDIR" rev-parse HEAD)"
out="$(cd "$WORKDIR" && FORMAL_CI_BASE_SHA="$head_new" FORMAL_CI_HEAD_SHA="$head_move" formal_ci_decide)"
if [[ "$out" == 'run_formal=true' ]]; then ok 'move out of relevant path runs'; else bad "move out of relevant path: $out"; fi

missing="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
out="$(cd "$WORKDIR" && FORMAL_CI_BASE_SHA="$missing" FORMAL_CI_HEAD_SHA="$head_new" formal_ci_decide)"
if [[ "$out" == 'run_formal=true' ]]; then ok 'unfetchable base fails closed'; else bad "unfetchable base: $out"; fi

if [[ "$fail" -ne 0 ]]; then
	echo 'formal-ci-paths test FAILED' >&2
	exit 1
fi
echo 'formal-ci-paths test passed'
