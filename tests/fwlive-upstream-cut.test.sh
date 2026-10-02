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
[[ -n "$pot_fn" && -n "$row_fn" ]] || die "cut verifier functions not found in upstream-cut.sh"
# shellcheck disable=SC1090
eval "$pot_fn"
# shellcheck disable=SC1090
eval "$row_fn"

FX="$CUT_WORK/verifier-fx"
REL=htdocs/luci-static/resources/fwlive
mkdir -p "$FX/out/po/templates" "$FX/out/$REL" "$FX/pkg/$REL"
printf 'one\ntwo\nthree\n' >"$FX/out/$REL/log.js"
cp "$FX/out/$REL/log.js" "$FX/pkg/$REL/log.js"
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

printf '| `%s/log.js` | shipped |\n' "$REL" >"$FX/out/README.md"
upstream_cut_verify_readme_rows "$FX/out" >/dev/null 2>&1 \
	|| die "README row verifier rejected a shipped path"
printf '| `%s/fwlive.css` | dropped |\n' "$REL" >>"$FX/out/README.md"
upstream_cut_verify_readme_rows "$FX/out" >/dev/null 2>&1 \
	&& die "README row verifier accepted a dangling row"
ok "README row verifier fails closed"

# Gap 4: the cut must stay luci-shaped. Time it for the wave record.
# Keep stderr so named invariant failures from the cut script reach CI.
_start=$(date +%s)
"$ROOT/scripts/upstream-cut.sh" "$CUT_WORK/cut" >/dev/null || die "upstream-cut.sh failed"
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
            raw = line[m.start():]
            if re.match(r'#[0-9a-fA-F]*[a-fA-F]', raw) or re.match(r'#[0-9a-fA-F]{6}\b', raw):
                continue
            hits.append('%s:%d: %s' % (path.relative_to(root), i, line.strip()[:120]))
if hits:
    print('\n'.join(hits[:20]))
    sys.exit(1)
PY
}

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
