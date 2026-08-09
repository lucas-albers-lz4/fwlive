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

# Package README links into monorepo docs/ die after the copy; point them at
# the canonical GitHub copies so they survive the cut.
# shellcheck disable=SC2016  # '"$GITHUB_BLOB"' splice is deliberate
sed -i \
    -e 's|\[`\.\./\.\./docs/user/installation\.md`\](\.\./\.\./docs/user/installation\.md)|[installation guide]('"$GITHUB_BLOB"'/docs/user/installation.md)|' \
    -e 's|\[`\.\./\.\./docs/developer/README\.md`\](\.\./\.\./docs/developer/README\.md)|[developer documentation]('"$GITHUB_BLOB"'/docs/developer/README.md)|' \
    "$OUT/README.md"

echo "== 4/5 verify =="
fail=0

src_count=$(git ls-tree -r --name-only "master:$PKG" | wc -l)
out_count=$(find "$OUT" -type f | wc -l)
if [ "$src_count" -ne "$out_count" ]; then
    echo "  FAIL: file count mismatch (source $src_count, out $out_count)" >&2
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

if [ ! -f "$OUT/po/templates/luci-app-fwlive.pot" ]; then
    echo "  FAIL: po/templates/luci-app-fwlive.pot missing" >&2
    fail=1
fi

if grep -rn 'TOPDIR)/feeds/luci' "$OUT/Makefile" >/dev/null 2>&1; then
    echo "  FAIL: feed-path luci.mk include remains in Makefile" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "Upstream cut FAILED — fix the checks above." >&2
    exit 1
fi

echo "  OK: $out_count files match source; Makefile include rewritten;"
echo "  OK: no monorepo-relative docs links; po template present"

echo "== 5/5 next steps =="
echo "  Copy $OUT into a luci fork at luci/applications/luci-app-fwlive/"
echo "  and open the upstream PR. Apache-2.0 in PR body (PKG_LICENSE already set)."
