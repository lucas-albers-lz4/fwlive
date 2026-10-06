#!/usr/bin/env bash
# Phase 2 (issue #273): upstream-cut invariants + .pot msgid parity.
# Runs scripts/upstream-cut.sh to a temp dir and pins the luci-shaped output.
# Gap 5 needs i18n-scan.pl (openwrt/luci build tree). Normal CI may skip the
# parity half when its prerequisites are absent. Release/upstream sign-off can
# set FWLIVE_I18N_REQUIRE_SCAN=1 to fail closed instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POT="$ROOT/openwrt-feed/luci-app-fwlive/po/templates/luci-app-fwlive.pot"
I18N_REQUIRE_SCAN="${FWLIVE_I18N_REQUIRE_SCAN:-0}"

die() { echo "fwlive-upstream-cut test FAIL: $*" >&2; exit 1; }
ok() { echo "fwlive-upstream-cut test OK: $*"; }
skip_parity() {
	local reason="$1"
	if [[ "$I18N_REQUIRE_SCAN" == 1 ]]; then
		die "msgid parity required but unavailable: $reason"
	fi
	echo "SKIP: msgid parity $reason"
	echo "SUMMARY: upstream-cut structure checks passed; fresh msgid parity SKIPPED"
	echo "fwlive-upstream-cut tests passed with explicit SKIP"
	exit 0
}

[[ "$I18N_REQUIRE_SCAN" == 0 || "$I18N_REQUIRE_SCAN" == 1 ]] \
	|| die "FWLIVE_I18N_REQUIRE_SCAN must be 0 or 1"

CUT_WORK=$(mktemp -d)
PROMOTE_REPO=""
PKG=openwrt-feed/luci-app-fwlive
DIRTY_PROBE="$ROOT/$PKG/.upstream-cut-dirty-probe-$$"
# Preserve a pre-existing regenerable split ref; only delete if we created it.
SAVED_UPSTREAM_CUT_SHA=
if git -C "$ROOT" rev-parse --verify refs/heads/upstream/luci-app-fwlive >/dev/null 2>&1; then
	SAVED_UPSTREAM_CUT_SHA=$(git -C "$ROOT" rev-parse refs/heads/upstream/luci-app-fwlive)
fi
_restore_upstream_cut_ref() {
	rm -f "$DIRTY_PROBE"
	rm -rf "$CUT_WORK" ${PROMOTE_REPO:+"$PROMOTE_REPO"}
	if [ -n "${SAVED_UPSTREAM_CUT_SHA:-}" ]; then
		git -C "$ROOT" update-ref refs/heads/upstream/luci-app-fwlive "$SAVED_UPSTREAM_CUT_SHA" >/dev/null 2>&1 || true
	else
		git -C "$ROOT" branch -D upstream/luci-app-fwlive >/dev/null 2>&1 || true
	fi
}
trap _restore_upstream_cut_ref EXIT

echo probe >"$DIRTY_PROBE"
if "$ROOT/scripts/upstream-cut.sh" "$CUT_WORK/dirty" >/dev/null 2>"$CUT_WORK/dirty.err"; then
	die "dirty package tree must refuse the cut"
fi
rm -f "$DIRTY_PROBE"
grep -q 'uncommitted changes' "$CUT_WORK/dirty.err" \
	|| die "dirty refuse missing ($(cat "$CUT_WORK/dirty.err"))"
ok "dirty package tree refuses the cut"

if "$ROOT/scripts/upstream-cut.sh" "$CUT_WORK/a" "$CUT_WORK/b" >/dev/null 2>"$CUT_WORK/extra.err"; then
	die "extra positional must fail"
fi
grep -q 'extra positional' "$CUT_WORK/extra.err" \
	|| die "extra positional message ($(cat "$CUT_WORK/extra.err"))"
ok "second outdir is rejected"

PROMOTE_REPO="$(mktemp -d)"
git -C "$PROMOTE_REPO" init -q -b main
git -C "$PROMOTE_REPO" config user.email 'fwlive-test@example.com'
git -C "$PROMOTE_REPO" config user.name 'fwlive-test'
git -C "$PROMOTE_REPO" commit -q --allow-empty -m init
git -C "$PROMOTE_REPO" branch split-temp
git -C "$PROMOTE_REPO" branch canonical-name
git -C "$PROMOTE_REPO" commit -q --allow-empty -m split
# split-temp stays at init; move only the current main tip, then point split-temp at it.
git -C "$PROMOTE_REPO" branch -f split-temp HEAD
promote_fn="$(awk '/^upstream_cut_promote_canonical\(\)/,/^}/' "$ROOT/scripts/upstream-cut.sh")"

(
	cd "$PROMOTE_REPO"
	# shellcheck disable=SC1090
	eval "$promote_fn"
	git checkout -q canonical-name
	CANONICAL_SPLIT_BRANCH=canonical-name
	SPLIT_BRANCH=split-temp
	KEEP_SPLIT_BRANCH=0
	canon_before="$(git rev-parse canonical-name)"
	if upstream_cut_promote_canonical; then
		die "checked-out canonical must refuse replace"
	fi
	[[ "$KEEP_SPLIT_BRANCH" == 1 ]] || die "checked-out replace must keep the temp branch"
	git rev-parse --verify split-temp >/dev/null
	[[ "$(git rev-parse canonical-name)" == "$canon_before" ]] \
		|| die "checked-out replace moved the canonical ref"
)
ok "checked-out canonical keeps the verified split"

(
	cd "$PROMOTE_REPO"
	git checkout -q main
	# shellcheck disable=SC1090
	eval "$promote_fn"
	git() {
		if [[ "$1" == branch && "$2" == -f ]]; then
			return 1
		fi
		command git "$@"
	}
	CANONICAL_SPLIT_BRANCH=canonical-name
	SPLIT_BRANCH=split-temp
	KEEP_SPLIT_BRANCH=0
	canon_before="$(git rev-parse canonical-name)"
	if upstream_cut_promote_canonical; then
		die "failed canonical update must refuse replace"
	fi
	[[ "$KEEP_SPLIT_BRANCH" == 1 ]] || die "failed update must keep the temp branch"
	git rev-parse --verify split-temp >/dev/null
	[[ "$(git rev-parse canonical-name)" == "$canon_before" ]] \
		|| die "failed update moved the canonical ref"
)
ok "rename failure keeps the verified split"

(
	cd "$PROMOTE_REPO"
	git checkout -q main
	# shellcheck disable=SC1090
	eval "$promote_fn"
	CANONICAL_SPLIT_BRANCH=canonical-name
	SPLIT_BRANCH=split-temp
	KEEP_SPLIT_BRANCH=0
	want="$(git rev-parse split-temp)"
	upstream_cut_promote_canonical
	[[ "$(git rev-parse canonical-name)" == "$want" ]] || die "replace did not move canonical"
	if git rev-parse --verify split-temp >/dev/null 2>&1; then
		die "replace left the temp branch"
	fi
	[[ "$SPLIT_BRANCH" == canonical-name && "$KEEP_SPLIT_BRANCH" == 1 ]] \
		|| die "replace must keep the canonical name"
)
ok "--replace force-updates canonical before deleting the temp branch"

# The two cut verifiers must fail closed, not merely pass on a good tree: a
# monorepo-shaped ref, an out-of-range line, a referenced-file line-count
# change, or a README row naming a dropped file are the regressions they exist
# for. Extract them the way the promote helper above is exercised.
pot_fn="$(awk '/^upstream_cut_verify_pot_refs\(\)/,/^}/' "$ROOT/scripts/upstream-cut.sh")"
row_fn="$(awk '/^upstream_cut_verify_readme_rows\(\)/,/^}/' "$ROOT/scripts/upstream-cut.sh")"
artifact_fn="$(awk '/^upstream_cut_verify_artifacts\(\)/,/^}/' "$ROOT/scripts/upstream-cut.sh")"
symlink_fn="$(awk '/^upstream_cut_verify_no_symlinks\(\)/,/^}/' "$ROOT/scripts/upstream-cut.sh")"
[[ -n "$pot_fn" && -n "$row_fn" && -n "$artifact_fn" ]] \
	|| die "cut verifier functions not found in upstream-cut.sh"
[[ -n "$symlink_fn" ]] || die "cut symlink verifier not found in upstream-cut.sh"
# shellcheck disable=SC1090
eval "$pot_fn"
# shellcheck disable=SC1090
eval "$row_fn"
# shellcheck disable=SC1090
eval "$artifact_fn"
# shellcheck disable=SC1090
eval "$symlink_fn"

FX="$CUT_WORK/verifier-fx"
REL=htdocs/luci-static/resources/fwlive
mkdir -p "$FX/out/po/templates" "$FX/out/$REL" "$FX/pkg/$REL"
printf 'one\ntwo\nthree\n' >"$FX/out/$REL/log.js"
cp "$FX/out/$REL/log.js" "$FX/pkg/$REL/log.js"
touch "$FX/out/Makefile"
mkdir -p "$FX/out/root/usr/share/luci/menu.d" "$FX/out/root/usr/share/rpcd/acl.d"
printf '{}\n' >"$FX/out/root/usr/share/luci/menu.d/fwlive.json"
printf '{}\n' >"$FX/out/root/usr/share/rpcd/acl.d/fwlive.json"
fixture_pot() {
	{
		printf '#: %s\n' "$1"
		printf 'msgid "one"\nmsgstr ""\n'
	} >"$FX/out/po/templates/luci-app-fwlive.pot"
}

fixture_pot "applications/luci-app-fwlive/$REL/log.js:2"
upstream_cut_verify_pot_refs "$FX/out" "$FX/pkg" >/dev/null 2>&1 \
	|| die "pot ref verifier rejected a valid ref"
fixture_pot "applications/luci-app-fwlive/$REL/log.js:9"
upstream_cut_verify_pot_refs "$FX/out" "$FX/pkg" >/dev/null 2>&1 \
	&& die "pot ref verifier accepted an out-of-range line"
fixture_pot "openwrt-feed/luci-app-fwlive/$REL/log.js:2"
upstream_cut_verify_pot_refs "$FX/out" "$FX/pkg" >/dev/null 2>&1 \
	&& die "pot ref verifier accepted a monorepo-shaped ref"
fixture_pot "applications/luci-app-fwlive/$REL/missing.js:1"
upstream_cut_verify_pot_refs "$FX/out" "$FX/pkg" >/dev/null 2>&1 \
	&& die "pot ref verifier accepted an unresolvable ref"
printf 'one\ntwo\nthree\nfour\n' >"$FX/pkg/$REL/log.js"
fixture_pot "applications/luci-app-fwlive/$REL/log.js:2"
upstream_cut_verify_pot_refs "$FX/out" "$FX/pkg" >/dev/null 2>&1 \
	&& die "pot ref verifier accepted a referenced-file line-count change"
ok "pot ref verifier fails closed"

printf '| Path | Role |\n| --- | --- |\n| %s%s/log.js%s | shipped |\n| `root/usr/share/luci/menu.d/*.json` | menu glob |\n| `root/usr/share/rpcd/acl.d/*.json` | ACL glob |\n' '`' "$REL" '`' >"$FX/out/README.md"
upstream_cut_verify_readme_rows "$FX/out" >/dev/null 2>&1 \
	|| die "README row verifier rejected shipped paths or known globs"
printf '| %s%s/fwlive.css%s | dropped |\n' '`' "$REL" '`' >>"$FX/out/README.md"
upstream_cut_verify_readme_rows "$FX/out" >/dev/null 2>&1 \
	&& die "README row verifier accepted a dangling row"
printf '   Path | Role |\n   --- | --- |\n   `missing-indented-file` | dangling |\n' \
	>"$FX/out/README.md"
upstream_cut_verify_readme_rows "$FX/out" >"$FX/indented-readme.err" 2>&1 \
	&& die "README row verifier ignored an indented dangling row"
grep -q 'names a path the cut does not ship' "$FX/indented-readme.err" \
	|| die "indented dangling README failure did not report the missing path"
: >"$FX/out/README.md"
upstream_cut_verify_readme_rows "$FX/out" >"$FX/empty-readme.err" 2>&1 \
	&& die "README row verifier accepted an empty README"
grep -q 'no parsed path rows' "$FX/empty-readme.err" \
	|| die "empty README failure did not explain the missing parsed rows"
printf '| Path | Role |\n| --- | --- |\n| Makefile | shipped |\n' >"$FX/out/README.md"
upstream_cut_verify_readme_rows "$FX/out" >"$FX/unparseable-readme.err" 2>&1 \
	&& die "README row verifier accepted an unparseable path table"
grep -q 'no parsed path rows' "$FX/unparseable-readme.err" \
	|| die "unparseable README failure did not explain the missing parsed rows"
printf '| Path | Role |\n| --- | --- |\n| `Makefile` | shipped |\n| `Makefile` (generated) | note |\n' \
	>"$FX/out/README.md"
upstream_cut_verify_readme_rows "$FX/out" >"$FX/mixed-readme.err" 2>&1 \
	&& die "README row verifier ignored an unsupported row beside a valid path"
grep -q 'unsupported row' "$FX/mixed-readme.err" \
	|| die "mixed README failure did not identify the unsupported row"
printf 'outside target\n' >"$FX/outside-existing"
printf '   Path | Role |\n   --- | --- |\n   `Makefile` | shipped |\n   `../outside-existing` | outside |\n' \
	>"$FX/out/README.md"
upstream_cut_verify_readme_rows "$FX/out" >"$FX/outside-readme.err" 2>&1 \
	&& die "README row verifier accepted an existing target outside the artifact"
grep -q 'resolves outside the cut artifact' "$FX/outside-readme.err" \
	|| die "outside README failure did not report the resolved escape"
printf '| Path | Role |\n| --- | --- |\n| `./%s/log.js` | shipped |\n' "$REL" \
	>"$FX/out/README.md"
upstream_cut_verify_readme_rows "$FX/out" >/dev/null 2>&1 \
	|| die "README row verifier rejected an in-artifact ./ path"
printf '| Path | Role |\n| --- | --- |\n| `root/usr/share/luci/menu.d/*.json` | menu glob |\n' \
	>"$FX/out/README.md"
ln -s "$FX/outside-existing" "$FX/out/root/usr/share/luci/menu.d/escape.json"
upstream_cut_verify_readme_rows "$FX/out" >"$FX/glob-outside.err" 2>&1 \
	&& die "README row verifier accepted a glob matching an outside symlink"
grep -q 'resolves outside the cut artifact' "$FX/glob-outside.err" \
	|| die "outside glob failure did not report the resolved escape"
rm "$FX/out/root/usr/share/luci/menu.d/escape.json"
ok "README row verifier rejects dangling, unsupported, and outside paths"

# The artifact scan deliberately accepts unrelated URLs/paths and real hex
# colors, while rejecting actual monorepo/tracker leakage anywhere in the tree.
cat >"$FX/out/README.md" <<'EOF'
| Path | Role |
| --- | --- |
| `root/usr/libexec/fwlive-helper.sh` | shipped helper |

See https://openwrt.org/docs/guide-user/base-system/system_configuration,
https://example.org/scripts/gen-all.sh, and https://example.org/manual/#1.
A generic `core/dns` path is not a monorepo source reference. The inline token
`#1` is literal documentation code. This generic URL path is also valid:
https://example.org/openwrt-feed/luci-app-fwlive/Makefile.
https://example.org/lab/runbook and https://example.org/CHANGELOG.md are URLs.
```text
#1
```
EOF
mkdir -p "$FX/out/po/templates" "$FX/out/root/usr/share/fwlive" \
	"$FX/out/root/usr/libexec"
printf '/* palette: #abc #1234 #abcdef #123456 #12345678 */\n' >"$FX/out/root/usr/share/fwlive/colors.css"
printf '# Ordinary helper comment; /etc/fwlive and root/usr paths are valid.\n' \
	>"$FX/out/root/usr/libexec/fwlive-helper.sh"
upstream_cut_verify_artifacts "$FX/out" >"$FX/artifact-safe.out" 2>&1 \
	|| die "artifact scanner rejected legitimate URLs, paths, or hex colors: $(cat "$FX/artifact-safe.out")"
printf '# Internal follow-up: issue #1180.\n' \
	>"$FX/out/root/usr/libexec/unscanned-helper.sh"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/tracker-leak.err" 2>&1; then
	die "artifact scanner missed tracker leakage outside the former five scanned files"
fi
grep -q 'numeric tracker reference #1180' "$FX/tracker-leak.err" \
	|| die "tree-wide tracker rejection was not reported"
rm "$FX/out/root/usr/libexec/unscanned-helper.sh"
printf '// Do not edit this helper note.\n' \
	>"$FX/out/root/usr/libexec/unscanned-note.txt"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/do-not-edit-comment.err" 2>&1; then
	die "artifact scanner missed a generic do-not-edit comment outside the former five files"
fi
grep -q 'do-not-edit instruction' "$FX/do-not-edit-comment.err" \
	|| die "generic do-not-edit rejection was not reported"
rm "$FX/out/root/usr/libexec/unscanned-note.txt"
printf '/* GENERATED — do not edit. Edit fwlive.css and run: node scripts/embed-fwlive-css.js */\n' \
	>"$FX/out/root/usr/share/fwlive/generated.css"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/generated-css.err" 2>&1; then
	die "artifact scanner missed a Generated — do not edit CSS header"
fi
grep -q 'do-not-edit instruction' "$FX/generated-css.err" \
	|| die "generated CSS do-not-edit rejection was not reported"
rm "$FX/out/root/usr/share/fwlive/generated.css"
printf 'Generated from openwrt-feed/luci-app-fwlive/core/fwlive-log.js\n' \
	>"$FX/out/po/templates/unscanned-note.txt"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/monorepo-leak.err" 2>&1; then
	die "artifact scanner missed monorepo path leakage outside the former five scanned files"
fi
grep -q 'monorepo path' "$FX/monorepo-leak.err" \
	|| die "tree-wide monorepo path rejection was not reported"
rm "$FX/out/po/templates/unscanned-note.txt"
# Regression matrix pins the original leakage signatures, including relative
# prefixes and punctuation immediately after a path/token.
for leak in \
	'GENERATED FILE — do not edit.' \
	'Generated — do not edit. Edit fwlive.css instead.' \
	'Do not edit this generic generated note.' \
	'core/fwlive-log.js,' \
	'./core/fwlive-log.js)' \
	'../core/fwlive-log.js.' \
	'openwrt-feed/luci-app-fwlive/Makefile,' \
	'./openwrt-feed/luci-app-fwlive/README.md).' \
	'../openwrt-feed/luci-app-fwlive/Makefile;' \
	'./scripts/gen-all.sh,' \
	'scripts/local-helper.sh' \
	'lab/runbook.md' \
	'docs/internal.md' \
	'CHANGELOG.md' \
	'../docs/fwlive-ui-design-target.md.'; do
	printf 'Reference: %s\n' "$leak" >"$FX/out/rejection-matrix.txt"
	upstream_cut_verify_artifacts "$FX/out" >"$FX/rejection-matrix.err" 2>&1 \
		&& die "artifact scanner accepted known leakage signature: $leak"
done
rm "$FX/out/rejection-matrix.txt"
printf 'const docs = "//example.org/manual/#1180";\nconst more = `\n//example.org/manual/#1180\n`;\n' \
	>"$FX/out/root/usr/libexec/protocol-relative.js"
upstream_cut_verify_artifacts "$FX/out" >"$FX/protocol-relative.out" 2>&1 \
	|| die "artifact scanner treated a protocol-relative JS string as a comment: $(cat "$FX/protocol-relative.out")"
rm "$FX/out/root/usr/libexec/protocol-relative.js"
printf '//#7655\n' >"$FX/out/root/usr/libexec/protocol-relative-tracker.js"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/protocol-relative-tracker.err" 2>&1; then
	die "artifact scanner treated a bare //# tracker as a URL fragment"
fi
grep -q 'numeric tracker reference #7655' "$FX/protocol-relative-tracker.err" \
	|| die "protocol-relative tracker rejection was not reported"
rm "$FX/out/root/usr/libexec/protocol-relative-tracker.js"
printf '/*\n#7654\ncontinuation without an asterisk\n*/\n' \
	>"$FX/out/root/usr/libexec/multiline-comment.js"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/multiline-comment.err" 2>&1; then
	die "artifact scanner missed a tracker in a multiline JS block comment"
fi
grep -q 'numeric tracker reference #7654' "$FX/multiline-comment.err" \
	|| die "multiline JS block-comment rejection was not reported"
rm "$FX/out/root/usr/libexec/multiline-comment.js"
# Inline comments are comments too; numeric-looking CSS colors are exempt only
# in CSS, never in Markdown or shell comment contexts.
printf 'const marker = true; // #4321\n' >"$FX/out/root/usr/libexec/inline-comment.js"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/inline-js.err" 2>&1; then
	die "artifact scanner missed inline JS tracker comment"
fi
grep -q 'numeric tracker reference #4321' "$FX/inline-js.err" \
	|| die "inline JS tracker rejection was not reported"
printf 'run_helper # #5432\n' >"$FX/out/root/usr/libexec/inline-comment.sh"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/inline-shell.err" 2>&1; then
	die "artifact scanner missed inline shell tracker comment"
fi
grep -q 'numeric tracker reference #5432' "$FX/inline-shell.err" \
	|| die "inline shell tracker rejection was not reported"
printf '<!-- #123456 -->\n' >"$FX/out/numeric-tracker.md"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/numeric-md.err" 2>&1; then
	die "artifact scanner treated a Markdown numeric tracker as a CSS color"
fi
grep -q 'numeric tracker reference #123456' "$FX/numeric-md.err" \
	|| die "six-digit Markdown tracker rejection was not reported"
rm "$FX/out/numeric-tracker.md"
printf '# #12345678\n' >"$FX/out/root/usr/libexec/numeric-tracker.sh"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/numeric-shell.err" 2>&1; then
	die "artifact scanner treated a shell numeric tracker as a CSS color"
fi
grep -q 'numeric tracker reference #12345678' "$FX/numeric-shell.err" \
	|| die "eight-digit shell tracker rejection was not reported"
rm "$FX/out/root/usr/libexec/inline-comment.js" \
	"$FX/out/root/usr/libexec/inline-comment.sh" \
	"$FX/out/root/usr/libexec/numeric-tracker.sh"
printf 'const issue = "#7655";\n' >"$FX/out/root/usr/libexec/executable-tracker.js"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/executable-tracker.err" 2>&1; then
	die "artifact scanner missed a bare tracker reference in executable source"
fi
grep -q 'numeric tracker reference #7655' "$FX/executable-tracker.err" \
	|| die "executable-source tracker rejection was not reported"
rm "$FX/out/root/usr/libexec/executable-tracker.js"
printf '%s\n' '/home/build/fwlive/openwrt-feed/luci-app-fwlive/README.md' \
	>"$FX/out/absolute-monorepo-path.txt"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/absolute-monorepo-path.err" 2>&1; then
	die "artifact scanner missed an absolute monorepo path"
fi
grep -q 'monorepo path' "$FX/absolute-monorepo-path.err" \
	|| die "absolute monorepo path rejection was not reported"
rm "$FX/out/absolute-monorepo-path.txt"
printf '%s\n' 'file:///home/build/fwlive/openwrt-feed/luci-app-fwlive/README.md' \
	>"$FX/out/file-uri-monorepo-path.txt"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/file-uri-monorepo-path.err" 2>&1; then
	die "artifact scanner treated a file URI as an allowed web URL"
fi
grep -q 'monorepo path' "$FX/file-uri-monorepo-path.err" \
	|| die "file URI monorepo path rejection was not reported"
rm "$FX/out/file-uri-monorepo-path.txt"
printf '%s\n' 'cache/docs/developer/architecture.md' >"$FX/out/nested-monorepo-path.txt"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/nested-monorepo-path.err" 2>&1; then
	die "artifact scanner missed a nested monorepo path"
fi
grep -q 'monorepo path' "$FX/nested-monorepo-path.err" \
	|| die "nested monorepo path rejection was not reported"
rm "$FX/out/nested-monorepo-path.txt"
# A malicious archive symlink must be rejected before rewrite/scanning reads
# its external target, and diagnostics must name only the artifact path.
printf 'DO NOT LEAK THIS EXTERNAL TARGET CONTENT\n' >"$FX/outside-secret"
ln -s "$FX/outside-secret" "$FX/out/root/usr/libexec/external-link"
if upstream_cut_verify_no_symlinks "$FX/out" >"$FX/symlink-guard.err" 2>&1; then
	die "pre-rewrite guard accepted a package-controlled symlink"
fi
grep -q 'external-link' "$FX/symlink-guard.err" \
	|| die "symlink guard did not identify the artifact path"
if upstream_cut_verify_artifacts "$FX/out" >"$FX/symlink-scan.err" 2>&1; then
	die "artifact scanner accepted a symlink"
fi
grep -q 'symlink is not supported' "$FX/symlink-scan.err" \
	|| die "artifact scanner did not report the rejected symlink"
if grep -q 'DO NOT LEAK THIS EXTERNAL TARGET CONTENT' "$FX/symlink-guard.err" "$FX/symlink-scan.err"; then
	die "symlink diagnostics exposed external target content"
fi
rm "$FX/out/root/usr/libexec/external-link" "$FX/outside-secret"
printf '%s\n' \
	'https://example.org/openwrt-feed/releases/README.md' \
	'https://example.org/../core/fwlive-log.js is an example URL.' \
	>"$FX/out/legitimate-url.txt"
upstream_cut_verify_artifacts "$FX/out" >"$FX/artifact-safe.out" 2>&1 \
	|| die "artifact scanner rejected a legitimate URL after the rejection matrix: $(cat "$FX/artifact-safe.out")"
rm "$FX/out/legitimate-url.txt"
ok "artifact scanner rejects path/comment leakage and keeps URL/CSS exceptions scoped"

# Gap 4: the cut must stay luci-shaped. Time it for the wave record.
# Keep stderr so named invariant failures from the cut script reach CI.
_start=$(date +%s)
# The guard was exercised above. Allow dirty solely for the smoke cut so this
# suite also runs when another local edit is in progress; archive still cuts HEAD.
"$ROOT/scripts/upstream-cut.sh" --allow-dirty "$CUT_WORK/cut" >/dev/null \
	|| die "upstream-cut.sh failed"
_end=$(date +%s)
echo "fwlive-upstream-cut test INFO: cut wall time $((_end - _start))s"

[ -f "$CUT_WORK/cut/Makefile" ] || die "cut Makefile missing"
grep -q '^include ../../luci.mk' "$CUT_WORK/cut/Makefile" \
	|| die "Makefile include not rewritten to ../../luci.mk"
! grep -q 'SOURCE_DATE_EPOCH' "$CUT_WORK/cut/Makefile" \
	|| die "SOURCE_DATE_EPOCH block remains in luci-shaped Makefile"
! grep -q 'docker-sdk' "$CUT_WORK/cut/Makefile" \
	|| die "docker-sdk reference remains in luci-shaped Makefile"
ok "cut Makefile is luci-shaped (include, no SOURCE_DATE_EPOCH, no docker-sdk)"

if git -C "$ROOT" ls-files --error-unmatch \
	openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.awk \
	>/dev/null 2>&1; then
	[ -f "$CUT_WORK/cut/root/usr/libexec/fwlive-is-firewall-event.awk" ] \
		|| die "cut classifier awk asset missing"
	! grep -qE 'core/fwlive-log|\./scripts/gen-all' \
		"$CUT_WORK/cut/root/usr/libexec/fwlive-is-firewall-event.sh" \
		"$CUT_WORK/cut/root/usr/libexec/fwlive-is-firewall-event.awk" \
		|| die "monorepo-only classifier paths remain in cut"
	ok "cut includes standalone classifier awk asset"
else
	ok "cut awk-asset assertion deferred until new generated file is tracked"
fi

! grep -q 'lucas-albers-lz4/fwlive' "$CUT_WORK/cut/README.md" \
	|| die "cut README still cites the out-of-tree GitHub repo"
! grep -qE '^## (Maintenance|Documentation)$' "$CUT_WORK/cut/README.md" \
	|| die "cut README still has Maintenance or Documentation sections"
! grep -q '\.\./\.\./docs' "$CUT_WORK/cut/README.md" \
	|| die "monorepo-relative docs links remain in cut README"
grep -q '^## Dependencies$' "$CUT_WORK/cut/README.md" \
	|| die "cut README lost the Dependencies section"
ok "cut README is layout/deps only, no out-of-tree GitHub links"

# The cut drops fwlive.css (DROP_CSS=1), so its row must go too, and the view
# header must not point at a monorepo-only design doc. Both classes are covered
# by the cut's own grep; pin them here so a regression names the test.
! grep -q 'fwlive\.css' "$CUT_WORK/cut/README.md" \
	|| die "cut README still documents the dropped fwlive.css asset"
grep -q '^ \* for OpenWrt (Apache-2\.0)\.$' \
	"$CUT_WORK/cut/htdocs/luci-static/resources/view/status/fwlive.js" \
	|| die "cut view header still points at the monorepo design doc"
if grep -rqE 'embed-fwlive-css|in the fwlive repo|fwlive-ui-design-target|multi-model audit|issue [A-Z]{1,3}-[0-9]+' \
	"$CUT_WORK/cut"; then
	die "cut ships out-of-tree or internal references"
fi
ok "cut ships no dropped-file row, design-doc pointer, or internal tracker ref"

check_comment_policy() {
	local root="$1"
	local reject_repo="$2"
	python3 - "$root" "$reject_repo" <<'PY'
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
reject_repo = sys.argv[2] == '1'
# Keep \d{2,}: single-digit #N prose references are intentionally outside
# this gate, avoiding false positives such as "option #1".
pat = re.compile(r'(?i)(?:issue\s+|Grok\s+)?#\d{2,}')
hits = []
for path in root.rglob('*'):
    if not path.is_file() or path.suffix == '.pot':
        continue
    text = path.read_text(encoding='utf-8')
    for i, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        if not (stripped.startswith('#') or stripped.startswith('//')
                or stripped.startswith('/*') or stripped.startswith('* ')):
            continue
        if reject_repo and 'lucas-albers' in line:
            hits.append('%s:%d: %s' % (path.relative_to(root), i, line.strip()[:120]))
            continue
        for m in pat.finditer(line):
            raw = m.group(0)
            if (path.suffix.lower() == '.css'
                    and re.fullmatch(r'#[0-9a-fA-F]{3,4}|#[0-9a-fA-F]{6}|#[0-9a-fA-F]{8}', raw)):
                continue
            hits.append('%s:%d: %s' % (path.relative_to(root), i, line.strip()[:120]))
if hits:
    print('\n'.join(hits[:20]))
    sys.exit(1)
PY
}

POLICY_FIXTURE="$CUT_WORK/comment-policy"
mkdir -p "$POLICY_FIXTURE"
printf '/* palette: #333333, */\n' >"$POLICY_FIXTURE/color.css"
check_comment_policy "$POLICY_FIXTURE" 0 \
	|| die "comment policy rejected a CSS color followed by punctuation"
printf '/* issue #123456 */\n' >"$POLICY_FIXTURE/tracker.css"
if check_comment_policy "$POLICY_FIXTURE" 0 >/dev/null; then
	die "comment policy accepted an explicit tracker reference that looks like a CSS color"
fi
ok "comment policy handles CSS punctuation without exempting tracker context"

# Keep the feed source and luci-shaped cut in the same comment shape. Tests,
# changelog, and repo docs keep tracker ids because they are outside the feed.
check_comment_policy "$ROOT/openwrt-feed" 0 \
    || die "feed comments contain tracker ids"
ok "feed comments have no tracker ids"

# Tracker ids in comments auto-link to the luci issue tracker (openwrt/luci#8992).
check_comment_policy "$CUT_WORK/cut" 1 \
    || die "cut comments still contain tracker ids or GitHub org"
ok "cut comments have no tracker ids or GitHub org"

if grep -rqE '[Dd]o not edit|regenerate(d)? upstream of this tree|Snapshot from the fwlive monorepo' \
	"$CUT_WORK/cut"; then
	die "cut headers still name the fwlive repo or tell maintainers not to edit"
fi
grep -q '^# Generated classifier snapshot\.$' \
	"$CUT_WORK/cut/root/usr/libexec/fwlive-is-firewall-event.sh" \
	|| die "cut classifier header is not a generated-snapshot label"
grep -q '^# Generated classifier snapshot\.$' \
	"$CUT_WORK/cut/root/usr/libexec/fwlive-is-firewall-event.awk" \
	|| die "cut awk classifier header is not a generated-snapshot label"
grep -q '^ \* Generated stylesheet snapshot\.$' \
	"$CUT_WORK/cut/htdocs/luci-static/resources/fwlive/css.js" \
	|| die "cut stylesheet header is not a generated-snapshot label"
grep -q '^ \* Shared CLASSIFY_SPEC\.$' \
	"$CUT_WORK/cut/htdocs/luci-static/resources/fwlive/log.js" \
	|| die "cut log module header is not a shared-spec label"
ok "cut generated headers are labels only"

[ -f "$CUT_WORK/cut/po/templates/luci-app-fwlive.pot" ] \
	|| die "po/templates/luci-app-fwlive.pot missing from cut"
for lang in de ru zh_Hans; do
	[ ! -e "$CUT_WORK/cut/po/$lang" ] || die "locale dir po/$lang still present"
done
ok "cut ships .pot only (template present, locale dirs dropped)"

# The cut re-shapes the .pot: the PR ships this file, so its refs must resolve
# in a luci tree (applications/luci-app-fwlive/...), not only in this monorepo.
# Line numbers come from the monorepo template, so a rewrite that shifts a
# referenced file invalidates them silently; the cut verifier asserts the
# counts and the shape below pins the result.
POT_CUT="$CUT_WORK/cut/po/templates/luci-app-fwlive.pot"
if grep -E '^#: /' "$POT_CUT" >/dev/null; then
	die "absolute #: refs in cut .pot"
fi
grep -q '^#: applications/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive\.js:' \
	"$POT_CUT" || die "cut .pot refs are not luci-shaped"
if grep -q 'openwrt-feed/' "$POT_CUT"; then
	die "cut .pot still carries monorepo-shaped refs"
fi
ok "cut .pot #: refs are luci-shaped"

# Referenced files must keep their monorepo line counts, or every ref into them
# points somewhere else (log.js lost a line before this was pinned).
for rel in htdocs/luci-static/resources/fwlive/log.js \
	htdocs/luci-static/resources/view/status/fwlive.js; do
	src="$ROOT/openwrt-feed/luci-app-fwlive/$rel"
	[ "$(wc -l <"$src")" -eq "$(wc -l <"$CUT_WORK/cut/$rel")" ] \
		|| die "cut $rel line count differs from source (.pot refs invalid)"
done
ok "cut keeps .pot-referenced files line-for-line"

# Gap 5: fresh-scan msgid parity. Scanner source: env override, PATH, else skip.
SCAN="${FWLIVE_I18N_SCAN:-}"
if [ -z "$SCAN" ] && command -v i18n-scan.pl >/dev/null 2>&1; then
	SCAN=$(command -v i18n-scan.pl)
fi
# In the usual workspace layout, fwlive and luci are sibling checkouts. Find
# the scanner there without requiring PATH or a user-specific absolute path.
if [ -z "$SCAN" ]; then
	for candidate in "$ROOT"/../*/build/i18n-scan.pl; do
		if [ -f "$candidate" ]; then
			SCAN="$candidate"
			break
		fi
	done
fi
if [ -z "$SCAN" ] || [ ! -f "$SCAN" ]; then
	skip_parity "no i18n-scan.pl; set FWLIVE_I18N_SCAN"
fi
command -v xgettext >/dev/null 2>&1 \
	|| skip_parity "xgettext missing"
command -v python3 >/dev/null 2>&1 \
	|| skip_parity "python3 missing"

mkdir -p "$CUT_WORK/scanwork"
cp -r "$CUT_WORK/cut" "$CUT_WORK/scanwork/luci-app-fwlive"
(cd "$CUT_WORK/scanwork" && perl "$SCAN" luci-app-fwlive > fresh.pot 2>/dev/null) \
	|| die "i18n-scan.pl failed on the cut tree"
python3 - "$CUT_WORK/scanwork/fresh.pot" "$POT" <<'EOF' || die "msgid parity failed"
import re, sys
def msgids(p):
    # Multiline-aware: msgid "" + continuation "..." lines form one entry.
    # Single-line regexes silently drop those and can pass on a mismatch.
    s = open(p, encoding='utf-8', errors='replace').read()
    out = set()
    cur = None
    for line in s.splitlines():
        m = re.match(r'^msgid "(.*)"$', line)
        if m:
            if cur:
                out.add("".join(cur))
            cur = [m.group(1)]
            continue
        m = re.match(r'^"(.*)"$', line)
        if m and cur is not None:
            cur.append(m.group(1))
            continue
        if cur:
            out.add("".join(cur))
            cur = None
    if cur:
        out.add("".join(cur))
    return out - {''}
fresh, checked = msgids(sys.argv[1]), msgids(sys.argv[2])
only_fresh = sorted(fresh - checked)
only_checked = sorted(checked - fresh)
if only_fresh or only_checked:
    print("fresh-only: %s" % only_fresh[:10])
    print("checked-only: %s" % only_checked[:10])
    sys.exit(1)
print("msgid parity: %d/%d" % (len(fresh), len(checked)))
EOF
ok "fresh-scan msgids match the checked-in .pot"

# Same scanner run, refs this time: the cut .pot must already be what a luci
# tree scan emits (applications/... paths, luci-tree line numbers), so the PR
# does not ship a template that disagrees with the tree it lands in.
python3 - "$CUT_WORK/scanwork/fresh.pot" "$POT_CUT" <<'EOF' || die "ref parity failed"
import sys

def refs(p):
    out = set()
    for line in open(p, encoding='utf-8', errors='replace'):
        if not line.startswith('#: '):
            continue
        for tok in line[3:].split():
            path, sep, lineno = tok.rpartition(':')
            if not sep:
                continue
            # The scan runs from its own root; luci-app-fwlive/ is the anchor
            # both sides share, so compare from there.
            parts = path.split('/')
            if 'luci-app-fwlive' in parts:
                path = '/'.join(parts[parts.index('luci-app-fwlive'):])
            out.add('%s:%s' % (path, lineno))
    return out

fresh, cut = refs(sys.argv[1]), refs(sys.argv[2])
if fresh != cut:
    print('fresh-only refs: %s' % sorted(fresh - cut)[:5])
    print('cut-only refs: %s' % sorted(cut - fresh)[:5])
    sys.exit(1)
print('ref parity: %d refs' % len(fresh))
EOF
ok "fresh-scan #: refs match the cut .pot"

echo "fwlive-upstream-cut tests passed"
