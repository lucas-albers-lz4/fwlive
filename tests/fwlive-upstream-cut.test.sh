#!/usr/bin/env bash
# Phase 2 (issue #273): upstream-cut invariants + .pot msgid parity.
# Runs scripts/upstream-cut.sh to a temp dir and pins the luci-shaped output.
# Gap 5 needs i18n-scan.pl (openwrt/luci build tree); when absent the parity
# half skips — CI has no luci checkout, so the cut invariants are the gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POT="$ROOT/openwrt-feed/luci-app-fwlive/po/templates/luci-app-fwlive.pot"

die() { echo "fwlive-upstream-cut test FAIL: $*" >&2; exit 1; }
ok() { echo "fwlive-upstream-cut test OK: $*"; }

CUT_WORK=$(mktemp -d)
trap 'rm -rf "$CUT_WORK"; git -C "$ROOT" branch -D upstream/luci-app-fwlive >/dev/null 2>&1 || true' EXIT

# Gap 4: the cut must stay luci-shaped. Time it for the wave record.
_start=$(date +%s)
"$ROOT/scripts/upstream-cut.sh" "$CUT_WORK/cut" >/dev/null 2>&1 || die "upstream-cut.sh failed"
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

grep -q 'github.com/lucas-albers-lz4/fwlive/blob/master' "$CUT_WORK/cut/README.md" \
	|| die "README links not rewritten to the blob URL"
! grep -q '\.\./\.\./docs' "$CUT_WORK/cut/README.md" \
	|| die "monorepo-relative docs links remain in cut README"
ok "cut README points at blob URLs, no monorepo-relative links"

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
	ok "msgid parity skipped (no i18n-scan.pl; set FWLIVE_I18N_SCAN)"
	echo "fwlive-upstream-cut tests passed"
	exit 0
fi
command -v xgettext >/dev/null 2>&1 \
	|| { ok "msgid parity skipped (xgettext missing)"; echo "fwlive-upstream-cut tests passed"; exit 0; }
command -v python3 >/dev/null 2>&1 \
	|| { ok "msgid parity skipped (python3 missing)"; echo "fwlive-upstream-cut tests passed"; exit 0; }

mkdir -p "$CUT_WORK/scanwork"
cp -r "$CUT_WORK/cut" "$CUT_WORK/scanwork/luci-app-fwlive"
(cd "$CUT_WORK/scanwork" && perl "$SCAN" luci-app-fwlive > fresh.pot 2>/dev/null) \
	|| die "i18n-scan.pl failed on the cut tree"
python3 - "$CUT_WORK/scanwork/fresh.pot" "$POT" <<'EOF' || die "msgid parity failed"
import re, sys
def msgids(p):
    s = open(p, encoding='utf-8', errors='replace').read()
    return set(re.findall(r'^msgid "(.*)"$', s, re.M)) - {''}
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
