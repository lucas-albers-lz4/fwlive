#!/usr/bin/env bash
# Upstream cut: produce a clean, PR-ready luci-app-fwlive tree for openwrt/luci
# from the monorepo's openwrt-feed/ source of truth.
#
# Method: git subtree split (real files, package-only linear history, no
# gitlinks) -> export -> rewrite monorepo-relative references -> verify.
#
# Why subtree and not a submodule: a submodule is a gitlink (a commit pointer
# into a separate repo). openwrt/luci's PR process and build system resolve
# plain files only; a gitlink carries no Makefile/htdocs/root content and an
# external fetch mid-build is unwanted. subtree split materializes the package
# as real files with clean history, regenerable on demand.
#
# Usage: ./scripts/upstream-cut.sh [outdir]
#   outdir defaults to out/upstream/luci-app-fwlive/
#   Split branch is (re)created as upstream/luci-app-fwlive
#
# After the cut: copy out/upstream/luci-app-fwlive/ into a luci fork at
# luci/applications/luci-app-fwlive/ and open the PR there. See
# docs/github-publish-checklist.md -> "Upstream cut into openwrt/luci".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PKG=openwrt-feed/luci-app-fwlive
OUT="${1:-out/upstream/luci-app-fwlive}"
SPLIT_BRANCH="upstream/luci-app-fwlive"
GITHUB_BLOB="https://github.com/lucas-albers-lz4/fwlive/blob/master"
# Locale dirs kept in the feed for the binary release; first luci PR ships .pot only.
DROP_PO_LANGS=(de ru zh_Hans)
# Source for embed-fwlive-css.js; view loads css.js (styleText), not this asset.
DROP_CSS=1

# The split branch is regenerable by definition — force-recreate each run.
git branch -D "$SPLIT_BRANCH" >/dev/null 2>&1 || true

echo "== 1/5 git subtree split ($PKG -> $SPLIT_BRANCH) =="
git subtree split --prefix="$PKG" --branch="$SPLIT_BRANCH" >/dev/null

# A PR-able package must be plain files. Any gitlink means a submodule leaked
# into the tree and upstream cannot build it.
if git ls-tree -r "$SPLIT_BRANCH" | grep -q " commit "; then
	echo "ERROR: split tree contains gitlinks (submodules) — not PR-able upstream" >&2
	exit 1
fi

echo "== 2/5 export tree to $OUT =="
rm -rf "$OUT"
mkdir -p "$OUT"
git archive "$SPLIT_BRANCH" | tar -x -C "$OUT"

echo "== 3/5 rewrite monorepo-relative references =="
# LuCI applications live at luci/applications/<app>/; their Makefiles include
# the shared luci.mk two levels up.
# shellcheck disable=SC2016  # $TOPDIR must stay literal for sed
sed -i 's|include $(TOPDIR)/feeds/luci/luci.mk|include ../../luci.mk|' \
	"$OUT/Makefile"

# Drop the monorepo feed-wiring header comment — it references files that do
# not exist in the luci tree (openwrt-feed/README.md, feeds.conf.example).
# Keep the SPDX line; real luci apps start clean from there.
sed -i '/^# Wire feed first/,/^$/d' "$OUT/Makefile"

# SOURCE_DATE_EPOCH is already exported by OpenWrt toplevel.mk; the block is
# a no-op in luci and the comment cites docker-sdk.sh (monorepo-only) (#224).
sed -i '/^# Reproducible build: honor SOURCE_DATE_EPOCH/,/^endif$/d' "$OUT/Makefile"
# The delete leaves a double blank before PKG_LICENSE; squeeze to one (#246).
sed -i '/^PKG_RELEASE:=/{n;/^$/{n;/^$/d;};}' "$OUT/Makefile"

# First luci PR: .pot only. Empty locale dirs still make luci.mk emit empty
# luci-i18n-* packages — remove the directories entirely.
for lang in "${DROP_PO_LANGS[@]}"; do
	rm -rf "$OUT/po/$lang"
done

if [ "$DROP_CSS" -eq 1 ]; then
	rm -f "$OUT/htdocs/luci-static/resources/fwlive/fwlive.css"
fi

# Package README: GitHub docs links; no core/ citation; list proto.js.
# shellcheck disable=SC2016  # '"$GITHUB_BLOB"' splice is deliberate
sed -i \
	-e 's|\[`\.\./\.\./docs/user/installation\.md`\](\.\./\.\./docs/user/installation\.md)|[installation guide]('"$GITHUB_BLOB"'/docs/user/installation.md)|' \
	-e 's|\[`\.\./\.\./docs/developer/README\.md`\](\.\./\.\./docs/developer/README.md)|[developer documentation]('"$GITHUB_BLOB"'/docs/developer/README.md)|' \
	-e 's|\[Maintenance model\](\.\./\.\./docs/developer/upstream-openwrt\.md#maintenance-model)|[Maintenance model]('"$GITHUB_BLOB"'/docs/developer/upstream-openwrt.md#maintenance-model)|' \
	-e 's|Parser/filter module (mirror of repo `core/fwlive-log.js`)|Parser/filter module (`CLASSIFY_SPEC` + LuCI helpers)|' \
	"$OUT/README.md"

if ! grep -q 'proto\.js' "$OUT/README.md"; then
	sed -i \
		'/resources\/fwlive\/hostname\.js/a\
| `htdocs/luci-static/resources/fwlive/proto.js` | Protocol name/number helpers |' \
		"$OUT/README.md"
fi

# GENERATED / sync comments must not point at monorepo paths absent from luci.
shell_gen="$OUT/root/usr/libexec/fwlive-is-firewall-event.sh"
if [ -f "$shell_gen" ]; then
	sed -i \
		-e 's|^# GENERATED FILE — do not edit. Run: \./scripts/gen-all\.sh$|# Snapshot from the fwlive monorepo (lucas-albers-lz4/fwlive). Do not edit by hand.|' \
		-e 's|^# source: core/fwlive-log\.js CLASSIFY_SPEC$|# CLASSIFY_SPEC parity with htdocs/.../fwlive/log.js — regenerate upstream of this tree.|' \
		"$shell_gen"
fi

css_js="$OUT/htdocs/luci-static/resources/fwlive/css.js"
if [ -f "$css_js" ]; then
	sed -i \
		's|^ \* GENERATED — do not edit\. Edit fwlive\.css and run: node scripts/embed-fwlive-css\.js$| * Snapshot from the fwlive monorepo. Style source is regenerated upstream of this tree.|' \
		"$css_js"
fi

log_js="$OUT/htdocs/luci-static/resources/fwlive/log.js"
if [ -f "$log_js" ]; then
	sed -i \
		-e 's|Shared classify logic mirrors core/fwlive-log\.js CLASSIFY_SPEC — keep in sync|Shared CLASSIFY_SPEC — keep in sync with the fwlive monorepo|' \
		-e 's|(gen-luci-wrapper\.js gates full-spec drift; \./scripts/gen-all\.sh verifies)\.| (regenerate upstream of this tree).|' \
		"$log_js"
fi

constants_js="$OUT/htdocs/luci-static/resources/fwlive/constants.js"
if [ -f "$constants_js" ]; then
	sed -i \
		's|Keep in sync with openwrt-feed/luci-app-fwlive/Makefile PKG_VERSION\.|Keep in sync with Makefile PKG_VERSION.|' \
		"$constants_js"
fi

echo "== 4/5 verify =="
fail=0

src_count=$(git ls-tree -r --name-only "HEAD:$PKG" | wc -l)
drop_count=${#DROP_PO_LANGS[@]}
if [ "$DROP_CSS" -eq 1 ]; then
	drop_count=$((drop_count + 1))
fi
expected=$((src_count - drop_count))
out_count=$(find "$OUT" -type f | wc -l)
if [ "$out_count" -ne "$expected" ]; then
	echo "  FAIL: file count mismatch (source $src_count - $drop_count drops = $expected, out $out_count)" >&2
	fail=1
fi

for lang in "${DROP_PO_LANGS[@]}"; do
	if [ -e "$OUT/po/$lang" ]; then
		echo "  FAIL: po/$lang still present (first luci PR is .pot only)" >&2
		fail=1
	fi
done

if [ "$DROP_CSS" -eq 1 ] && [ -f "$OUT/htdocs/luci-static/resources/fwlive/fwlive.css" ]; then
	echo "  FAIL: fwlive.css still present (view loads css.js)" >&2
	fail=1
fi

if ! grep -q '^include ../../luci.mk' "$OUT/Makefile"; then
	echo "  FAIL: Makefile include not rewritten to ../../luci.mk" >&2
	fail=1
fi

if grep -rn '\.\./\.\./docs' "$OUT/README.md" >/dev/null 2>&1; then
	echo "  FAIL: monorepo-relative docs links remain in README.md" >&2
	fail=1
fi

if grep -q 'core/fwlive-log' "$OUT/README.md" >/dev/null 2>&1; then
	echo "  FAIL: README still cites core/fwlive-log.js" >&2
	fail=1
fi

if ! grep -q 'proto\.js' "$OUT/README.md"; then
	echo "  FAIL: README missing proto.js row" >&2
	fail=1
fi

if [ ! -f "$OUT/po/templates/luci-app-fwlive.pot" ]; then
	echo "  FAIL: po/templates/luci-app-fwlive.pot missing" >&2
	fail=1
fi

if grep -rn 'TOPDIR)/feeds/luci' "$OUT/Makefile" >/dev/null 2>&1; then
	echo "  FAIL: feed-path luci.mk include remains in Makefile" >&2
	fail=1
fi

if grep -qE 'openwrt-feed/|\./scripts/gen-all|core/fwlive-log|embed-fwlive-css' \
	"$OUT/htdocs/luci-static/resources/fwlive/constants.js" \
	"$OUT/htdocs/luci-static/resources/fwlive/css.js" \
	"$OUT/htdocs/luci-static/resources/fwlive/log.js" \
	"$OUT/root/usr/libexec/fwlive-is-firewall-event.sh" 2>/dev/null; then
	echo "  FAIL: monorepo-only paths remain in cut comments" >&2
	fail=1
fi

if ! grep -q 'PKG_VERSION:=' "$OUT/Makefile"; then
	echo "  FAIL: PKG_VERSION missing (keep lockstep with APP_VERSION)" >&2
	fail=1
fi

if grep -q 'SOURCE_DATE_EPOCH' "$OUT/Makefile"; then
	echo "  FAIL: SOURCE_DATE_EPOCH block remains in luci-shaped Makefile" >&2
	fail=1
fi

if grep -q 'docker-sdk' "$OUT/Makefile"; then
	echo "  FAIL: docker-sdk.sh reference remains in luci-shaped Makefile" >&2
	fail=1
fi

# No double blank before PKG_LICENSE (residue from dropping SOURCE_DATE_EPOCH) (#246).
# Note: awk still runs END after `exit` from the main body, so use a found flag.
if awk '
	$0 ~ /^PKG_RELEASE:=/ { blanks = 0; watching = 1; next }
	watching {
		if ($0 == "") { blanks++; next }
		if (blanks >= 2 && $0 ~ /^PKG_LICENSE:=/) { found = 1; exit }
		watching = 0
	}
	END { exit(found ? 0 : 1) }
' "$OUT/Makefile"; then
	echo "  FAIL: double blank before PKG_LICENSE in luci-shaped Makefile" >&2
	fail=1
fi

cut_pkg=$(sed -n 's/^PKG_VERSION:=//p' "$OUT/Makefile" | head -1)
cut_app=$(sed -n "s/.*APP_VERSION: '\\([^']*\\)'.*/\\1/p" \
	"$OUT/htdocs/luci-static/resources/fwlive/constants.js" | head -1)
if [ -z "$cut_pkg" ] || [ "$cut_pkg" != "$cut_app" ]; then
	echo "  FAIL: PKG_VERSION ($cut_pkg) != APP_VERSION ($cut_app)" >&2
	fail=1
fi

if [ "$fail" -ne 0 ]; then
	echo "Upstream cut FAILED — fix the checks above." >&2
	exit 1
fi

echo "  OK: $out_count files (source $src_count minus $drop_count); Makefile include rewritten;"
echo "  OK: no monorepo-relative docs links; po template present; locale dirs dropped"

echo "== 5/5 next steps =="
echo "  Copy $OUT into a luci fork at luci/applications/luci-app-fwlive/"
echo "  Run luci ./build/i18n-scan.pl on that tree for a fresh .pot, then open the PR."
echo "  Apache-2.0 in PR body (PKG_LICENSE already set)."
