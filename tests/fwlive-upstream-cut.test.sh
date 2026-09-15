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
# Preserve a pre-existing regenerable split ref; only delete if we created it.
SAVED_UPSTREAM_CUT_SHA=
if git -C "$ROOT" rev-parse --verify refs/heads/upstream/luci-app-fwlive >/dev/null 2>&1; then
	SAVED_UPSTREAM_CUT_SHA=$(git -C "$ROOT" rev-parse refs/heads/upstream/luci-app-fwlive)
fi
_restore_upstream_cut_ref() {
	rm -rf "$CUT_WORK"
	if [ -n "${SAVED_UPSTREAM_CUT_SHA:-}" ]; then
		git -C "$ROOT" update-ref refs/heads/upstream/luci-app-fwlive "$SAVED_UPSTREAM_CUT_SHA" >/dev/null 2>&1 || true
	else
		git -C "$ROOT" branch -D upstream/luci-app-fwlive >/dev/null 2>&1 || true
	fi
}
trap _restore_upstream_cut_ref EXIT

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

# Tracker ids in comments auto-link to the luci issue tracker (openwrt/luci#8992).
python3 - "$CUT_WORK/cut" <<'PY' || die "cut comments still contain tracker ids or GitHub org"
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
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
        if 'lucas-albers' in line:
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
ok "cut comments have no tracker ids or GitHub org"

[ -f "$CUT_WORK/cut/po/templates/luci-app-fwlive.pot" ] \
	|| die "po/templates/luci-app-fwlive.pot missing from cut"
for lang in de ru zh_Hans; do
	[ ! -e "$CUT_WORK/cut/po/$lang" ] || die "locale dir po/$lang still present"
done
ok "cut ships .pot only (template present, locale dirs dropped)"

# The cut keeps the checked-in .pot byte-identical (monorepo paths); the fresh
# luci-tree .pot comes from i18n-scan.pl in Gap 5. Pin repo-relative refs.
if grep -E '^#: /' "$CUT_WORK/cut/po/templates/luci-app-fwlive.pot" >/dev/null; then
	die "absolute #: refs in cut .pot"
fi
ok "cut .pot has repo-relative #: refs"

# Gap 5: fresh-scan msgid parity. Scanner source: env override, PATH, else skip.
SCAN="${FWLIVE_I18N_SCAN:-}"
if [ -z "$SCAN" ] && command -v i18n-scan.pl >/dev/null 2>&1; then
	SCAN=$(command -v i18n-scan.pl)
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

echo "fwlive-upstream-cut tests passed"
