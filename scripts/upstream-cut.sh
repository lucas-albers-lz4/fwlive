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
# Usage: ./scripts/upstream-cut.sh [--replace] [--allow-dirty] [outdir]
#   outdir defaults to out/upstream/luci-app-fwlive/
#   Split lands on a temporary branch; --replace updates upstream/luci-app-fwlive.
#   Uncommitted edits under openwrt-feed/luci-app-fwlive refuse the cut unless
#   --allow-dirty (git archive would omit them).
#
# After the cut: copy out/upstream/luci-app-fwlive/ into a luci fork at
# luci/applications/luci-app-fwlive/ and open the PR there. See
# docs/github-publish-checklist.md -> "Upstream cut into openwrt/luci".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PKG=openwrt-feed/luci-app-fwlive
REPLACE_CANONICAL=0
ALLOW_DIRTY=0
OUT=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--replace) REPLACE_CANONICAL=1; shift ;;
		--allow-dirty) ALLOW_DIRTY=1; shift ;;
		-h | --help)
			sed -n '1,22p' "$0"
			exit 0
			;;
		-*)
			echo "unknown arg: $1" >&2
			exit 1
			;;
		*)
			if [[ -n "$OUT" ]]; then
				echo "upstream-cut: extra positional '${1}' (already have outdir '${OUT}')" >&2
				exit 1
			fi
			OUT="$1"
			shift
			;;
	esac
done
OUT="${OUT:-out/upstream/luci-app-fwlive}"
CANONICAL_SPLIT_BRANCH="upstream/luci-app-fwlive"
SPLIT_BRANCH="${CANONICAL_SPLIT_BRANCH}-cut-$$"
KEEP_SPLIT_BRANCH=0
cleanup_split_branch() {
	if [[ "${KEEP_SPLIT_BRANCH}" == 1 ]]; then
		return 0
	fi
	git branch -D "$SPLIT_BRANCH" >/dev/null 2>&1 || true
}

# Rewrites and scanners must never follow package-controlled symlinks into the
# operator's workspace. Reject them immediately after extraction, before any
# tool can read or modify a target outside the cut tree.
upstream_cut_verify_no_symlinks() {
	local root="$1" path found=0
	while IFS= read -r -d '' path; do
		printf '  FAIL: symlink is not supported in cut artifact: %s\n' "${path#"$root"/}"
		found=1
	done < <(find "$root" -type l -print0)
	return "$found"
}

upstream_cut_rewrite_generated_headers() {
	local out="$1" shell_gen awk_gen css_js
	shell_gen="$out/root/usr/libexec/fwlive-is-firewall-event.sh"
	if [ -f "$shell_gen" ]; then
		sed -i \
			-e 's|^# GENERATED FILE — [Dd][Oo] [Nn][Oo][Tt] [Ee][Dd][Ii][Tt]\. Run: \./scripts/gen-all\.sh$|# Generated classifier snapshot.|' \
			-e 's|^# source: core/fwlive-log\.js CLASSIFY_SPEC$|# CLASSIFY_SPEC parity with htdocs/.../fwlive/log.js.|' \
			"$shell_gen"
	fi

	awk_gen="$out/root/usr/libexec/fwlive-is-firewall-event.awk"
	if [ -f "$awk_gen" ]; then
		sed -i \
			-e 's|^# GENERATED FILE — [Dd][Oo] [Nn][Oo][Tt] [Ee][Dd][Ii][Tt]\. Run: \./scripts/gen-all\.sh$|# Generated classifier snapshot.|' \
			-e 's|^# source: core/fwlive-log\.js CLASSIFY_SPEC$|# CLASSIFY_SPEC parity with htdocs/.../fwlive/log.js.|' \
			"$awk_gen"
	fi

	css_js="$out/htdocs/luci-static/resources/fwlive/css.js"
	if [ -f "$css_js" ]; then
		sed -i \
			's|^ \* GENERATED — [Dd][Oo] [Nn][Oo][Tt] [Ee][Dd][Ii][Tt]\. Edit fwlive\.css and run: node scripts/embed-fwlive-css\.js$| * Generated stylesheet snapshot.|' \
			"$css_js"
	fi
}

trap cleanup_split_branch EXIT
# Locale dirs kept in the feed for the binary release; first luci PR ships .pot only.
DROP_PO_LANGS=(de ru zh_Hans)
# Source for embed-fwlive-css.js; view loads css.js (styleText), not this asset.
DROP_CSS=1

if [[ "$ALLOW_DIRTY" != 1 ]]; then
	dirty="$(git status --porcelain -- "$PKG")"
	if [[ -n "$dirty" ]]; then
		echo "ERROR: uncommitted changes under ${PKG} (git archive would omit them). Commit or pass --allow-dirty." >&2
		printf '%s\n' "$dirty" >&2
		exit 1
	fi
fi

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

upstream_cut_guarded_rewrite() {
	local OUT="$1"
	if ! upstream_cut_verify_no_symlinks "$OUT"; then
		echo "Upstream cut FAILED — remove symlinks from the package tree before rewriting." >&2
		return 1
	fi

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

# Master keeps SOURCE_DATE_EPOCH block (reproducible-build flow exports it);
# only the luci-shaped copy drops it — already exported by OpenWrt toplevel.mk,
# no-op in luci and comment cites monorepo-only docker-sdk.sh (#224).
sed -i '/^# Reproducible build: honor SOURCE_DATE_EPOCH/,/^endif$/d' "$OUT/Makefile"
# The delete leaves a double blank before PKG_LICENSE; squeeze to one (#246).
# Master keeps the block intentionally; only the copy is squeezed.
sed -i '/^PKG_RELEASE:=/{n;/^$/{n;/^$/d;};}' "$OUT/Makefile"

# First luci PR: .pot only. Empty locale dirs still make luci.mk emit empty
# luci-i18n-* packages — remove the directories entirely.
for lang in "${DROP_PO_LANGS[@]}"; do
	rm -rf "$OUT/po/$lang"
done

if [ "$DROP_CSS" -eq 1 ]; then
	rm -f "$OUT/htdocs/luci-static/resources/fwlive/fwlive.css"
	# ...and its README row: the cut ships css.js, not the source asset, and
	# the row names the monorepo-only embed-fwlive-css.js generator.
	sed -i '/htdocs\/luci-static\/resources\/fwlive\/fwlive\.css/d' "$OUT/README.md"
fi

# Package README: luci copy is layout + deps only. Drop Maintenance and
# Documentation (those name an out-of-tree winner or link this GitHub).
# Keep the core/ citation rewrite and proto.js row. Feed README is unchanged.
sed -i \
	-e 's|Parser/filter module (mirror of repo `core/fwlive-log.js`)|Parser/filter module (`CLASSIFY_SPEC` + LuCI helpers)|' \
	"$OUT/README.md"

if ! grep -q 'proto\.js' "$OUT/README.md"; then
	sed -i \
		'/resources\/fwlive\/hostname\.js/a\
| `htdocs/luci-static/resources/fwlive/proto.js` | Protocol name/number helpers |' \
		"$OUT/README.md"
fi

# Maintenance + Documentation are last; they name this GitHub as development
# home. The luci tree should not advertise an out-of-tree winner.
sed -i '/^## Maintenance$/,$d' "$OUT/README.md"

# GENERATED / sync comments: drop monorepo paths, repo names, and do-not-edit
# instructions. Provenance stays in the luci PR body (openwrt/luci#8992).
upstream_cut_rewrite_generated_headers "$OUT"

# Rewrites of a file that the .pot references must not change its line count:
# the #: refs are copied from the monorepo template, whose line numbers were
# generated against the monorepo files. A shifted line silently invalidates
# them; 4/5 asserts the counts stay equal.
log_js="$OUT/htdocs/luci-static/resources/fwlive/log.js"
if [ -f "$log_js" ]; then
	sed -i \
		-e 's|Shared classify logic mirrors core/fwlive-log\.js CLASSIFY_SPEC — keep in sync|Shared CLASSIFY_SPEC.|' \
		-e 's|^ \* (gen-luci-wrapper\.js gates full-spec + regex drift; \./scripts/gen-all\.sh verifies)\.$| * Full-spec and regex drift are verified by the generator test suite.|' \
		-e 's|spec-derived classification regexes (mirror core/fwlive-log\.js)|spec-derived classification regexes|' \
		"$log_js"
fi

# The view header points at a monorepo-only design doc; the luci tree does not
# ship it. Substitution, not deletion — the .pot holds 151 refs into this file.
view_js="$OUT/htdocs/luci-static/resources/view/status/fwlive.js"
if [ -f "$view_js" ]; then
	sed -i 's|^ \* for OpenWrt (Apache-2\.0)\. See docs/fwlive-ui-design-target\.md in the fwlive repo\.$| * for OpenWrt (Apache-2.0).|' \
		"$view_js"
fi

constants_js="$OUT/htdocs/luci-static/resources/fwlive/constants.js"
if [ -f "$constants_js" ]; then
	sed -i \
		's|Keep in sync with openwrt-feed/luci-app-fwlive/Makefile PKG_VERSION\.|Keep in sync with Makefile PKG_VERSION.|' \
		"$constants_js"
fi

# Internal tracker/audit refs do not ship. Two comment lines in, two out, so
# the file's (unreferenced) line count stays put.
logging_sh="$OUT/root/usr/libexec/fwlive-logging.sh"
if [ -f "$logging_sh" ]; then
	sed -i \
		-e 's|^# Resolve a firewall section id to its canonical cfgXXXX form (issue B-1 /$|# Resolve a firewall section id to its canonical cfgXXXX form.|' \
		-e 's|^# multi-model audit)\. `uci -X show` disables|# `uci -X show` disables|' \
		"$logging_sh"
fi

# Drop fwlive tracker ids from comments. GitHub would auto-link them to
# openwrt/luci issues. Do not touch CSS hex or shell case arms (*[!0-9]*).
python3 - "$OUT" <<'PY'
import re, sys
from pathlib import Path

def is_comment(line, suffix):
    s = line.lstrip()
    if s.startswith('#!') or s.startswith('# shellcheck'):
        return False
    if suffix == '.js':
        return (s.startswith('//') or s.startswith('/*') or s.startswith('* ')
                or s.startswith('*/') or s == '*')
    return s.startswith('#')

def clean(s):
    s = re.sub(r'\s*\(Grok #\d+[^)]*\)', '', s)
    s = re.sub(r'\s*\(#\d+[^)]*\)', '', s)
    s = re.sub(r'\s*\(issue #\d+\)', '', s, flags=re.I)
    s = re.sub(r'\b[Ii]ssue #\d+:\s*', '', s)
    s = re.sub(r'\bissue #\d+\s*/\s*', '', s)
    s = re.sub(r'\bissue #\d+\b', '', s, flags=re.I)
    s = re.sub(r',\s*#\d+(?:\s+C\d+)?\)', ')', s)
    s = re.sub(r'^(\s*/\*\s*)#\d+\s+', r'\1', s)
    s = re.sub(r'(#\s+)\.\s+', r'\1', s)
    s = re.sub(r'(#)\.(?=\s)', r'\1 ', s)
    return s

root = Path(sys.argv[1])
for path in root.rglob('*'):
    if not path.is_file() or path.suffix in {'.pot', '.json'}:
        continue
    try:
        raw = path.read_text(encoding='utf-8')
    except UnicodeDecodeError:
        print('upstream-cut: skip non-UTF-8 %s' % path.relative_to(root), file=sys.stderr)
        continue
    out = []
    for line in raw.splitlines(keepends=True):
        nl = '\n' if line.endswith('\n') else ''
        body = line[:-1] if nl else line
        if is_comment(body, path.suffix):
            body = clean(body)
        out.append(body + nl)
    new = ''.join(out)
    if new != raw:
        path.write_text(new, encoding='utf-8')
PY

# .pot #: refs are copied from the monorepo template, where they read
# openwrt-feed/luci-app-fwlive/... . In the luci tree the same files live at
# applications/luci-app-fwlive/..., which is what ./build/i18n-scan.pl emits
# when it is run there. Ship that shape, so the template in the PR names paths
# a maintainer can resolve; 4/5 checks the line numbers behind them.
pot_out="$OUT/po/templates/luci-app-fwlive.pot"
if [ -f "$pot_out" ]; then
	sed -i -e '/^#: /s|openwrt-feed/luci-app-fwlive/|applications/luci-app-fwlive/|g' \
		"$pot_out"
fi

}
upstream_cut_guarded_rewrite "$OUT"

# .pot #: refs must be luci-shaped, resolvable, and line-accurate — and the
# line numbers only stay accurate while the rewrites above keep the referenced
# files' line counts (checked here, not assumed).
upstream_cut_verify_pot_refs() {
	local out="$1" pkg="$2"
	python3 - "$out" "$pkg" <<'PY'
import sys
from pathlib import Path

out, pkg = Path(sys.argv[1]), Path(sys.argv[2])
pot = out / 'po/templates/luci-app-fwlive.pot'
if not pot.is_file():
    sys.exit(0)
prefix = 'applications/luci-app-fwlive/'
bad = []
refs = {}
for line in pot.read_text(encoding='utf-8').splitlines():
    if not line.startswith('#: '):
        continue
    for token in line[3:].split():
        path, sep, lineno = token.rpartition(':')
        if not sep or not lineno.isdigit():
            bad.append('unparseable ref %r' % token)
            continue
        if not path.startswith(prefix):
            bad.append('ref is not luci-shaped: %s' % token)
            continue
        refs.setdefault(path[len(prefix):], []).append(int(lineno))
for rel in sorted(refs):
    target = out / rel
    source = pkg / rel
    if not target.is_file():
        bad.append('ref target missing from cut: %s' % rel)
        continue
    cut_lines = len(target.read_text(encoding='utf-8', errors='replace').splitlines())
    if source.is_file():
        src_lines = len(source.read_text(encoding='utf-8', errors='replace').splitlines())
        if src_lines != cut_lines:
            bad.append('referenced file changed line count: %s (%d -> %d)'
                       % (rel, src_lines, cut_lines))
    for n in refs[rel]:
        if n < 1 or n > cut_lines:
            bad.append('ref line out of range: %s:%d (%d lines)' % (rel, n, cut_lines))
for msg in bad[:20]:
    print('  FAIL: %s' % msg)
sys.exit(1 if bad else 0)
PY
}

# README table rows must not name a path the cut does not ship; a dropped file
# or monorepo-only generator otherwise leaves a dangling row behind. An empty
# or structurally changed table is also a failure: silently parsing zero rows
# would turn this check into a pass when the README layout drifts.
upstream_cut_verify_readme_rows() {
	local out="$1"
	python3 - "$out" <<'PY'
import glob, re, sys
from pathlib import Path

out = Path(sys.argv[1])
readme = out / 'README.md'
if not readme.is_file():
    print('  FAIL: README path table has no parsed path rows (README.md missing)')
    sys.exit(1)

def table_cells(line):
    # Markdown tables allow up to three leading spaces and either outer pipe
    # to be omitted. Tabs and greater indentation are unsupported.
    indent = re.match(r'^[ \t]*', line).group(0)
    if '\t' in indent or len(indent) > 3:
        return None
    body = line[len(indent):]
    if '|' not in body:
        return None
    if body.startswith('|'):
        body = body[1:]
    cells = [cell.strip() for cell in body.split('|')]
    if cells and cells[-1] == '':
        cells.pop()
    return cells

def path_row_cells(line, cells):
    if cells is not None:
        candidate = cells[0] if cells else ''
    elif '|' in line:
        body = line.strip().strip('|')
        candidate = body.split('|', 1)[0].strip()
    else:
        return False
    match = re.fullmatch(r'`([^`]+)`', candidate)
    if not match:
        return False
    value = match.group(1)
    # Only flag path-shaped code spans after the inventory boundary; unrelated
    # tables or prose that happen to use inline code and pipes are not rows.
    return ('/' in value or re.search(r'\.[A-Za-z0-9]{1,12}$', value) is not None
            or value in {'Makefile', 'README', 'LICENSE', 'Kconfig', 'Dockerfile', 'Config.in'})

def is_separator(cells):
    return (cells is not None and len(cells) == 2
            and all(re.fullmatch(r':?-{3,}:?', cell) for cell in cells))

missing = []
outside = []
unlisted_absolute = []
unsupported = []
parsed = 0
in_path_table = False
need_delimiter = False
saw_path_header = False
fence = None
resolved_out = out.resolve()
for line in readme.read_text(encoding='utf-8', errors='replace').splitlines():
    fence_match = re.match(r'^ {0,3}(`{3,}|~{3,})', line)
    if fence is not None:
        if (fence_match and fence_match.group(1)[0] == fence[0]
                and len(fence_match.group(1)) >= fence[1]):
            fence = None
        continue
    if fence_match:
        fence = (fence_match.group(1)[0], len(fence_match.group(1)))
        continue

    cells = table_cells(line)
    if not in_path_table:
        if cells and cells[0].lower() == 'path':
            saw_path_header = True
            if len(cells) != 2 or cells[1].lower() != 'role':
                unsupported.append('invalid Path table header: %s' % line.strip())
                continue
            in_path_table = True
            need_delimiter = True
            continue
        if saw_path_header and path_row_cells(line, cells):
            unsupported.append('path row appears outside a Path/Role table: %s'
                               % line.strip())
        continue
    if not line.strip():
        if need_delimiter:
            unsupported.append('Path/Role table is missing its delimiter row')
        in_path_table = False
        need_delimiter = False
        continue
    if cells is None:
        if '|' in line:
            unsupported.append(line.strip())
        elif need_delimiter:
            unsupported.append('Path/Role table is missing its delimiter row')
        in_path_table = False
        need_delimiter = False
        continue
    if need_delimiter:
        if is_separator(cells):
            need_delimiter = False
            continue
        unsupported.append('Path/Role table has an invalid delimiter row: %s'
                           % line.strip())
        need_delimiter = False
    if len(cells) != 2:
        unsupported.append(line.strip())
        continue
    if is_separator(cells):
        unsupported.append('unexpected delimiter row: %s' % line.strip())
        continue
    match = re.fullmatch(r'`([^`]+)`', cells[0])
    if not match:
        unsupported.append(cells[0] or line.strip())
        continue
    path = match.group(1)
    parsed += 1
    # The documented runtime marker is the only absolute path allowed here.
    if path.startswith('/'):
        if path != '/etc/fwlive/wan-log-baseline':
            unlisted_absolute.append(path)
        continue
    # Expand glob rows, then validate every resolved match (including symlinks).
    # This catches ../ traversal and wildcard families escaping via symlinks.
    candidates = [Path(p) for p in glob.glob(str(out / path), recursive=True)] if glob.has_magic(path) else [out / path]
    if not candidates:
        missing.append(path)
        continue
    for candidate in candidates:
        resolved = candidate.resolve()
        try:
            resolved.relative_to(resolved_out)
        except ValueError:
            outside.append('%s (matched %s)' % (path, candidate))
            continue
        if not resolved.exists():
            missing.append(path)

if need_delimiter:
    unsupported.append('Path/Role table is missing its delimiter row')
if parsed == 0:
    print('  FAIL: README path table has no parsed path rows')
for path in unsupported:
    print('  FAIL: README path table has an unsupported row: %s' % path)
for path in outside:
    print('  FAIL: README row resolves outside the cut artifact: %s' % path)
for path in missing:
    print('  FAIL: README row names a path the cut does not ship; correct the row or add the required package path: %s' % path)
for path in unlisted_absolute:
    print('  FAIL: README row uses an absolute path outside the documented runtime allowlist; correct it or allowlist a justified runtime path: %s' % path)
sys.exit(1 if parsed == 0 or unsupported or outside or missing or unlisted_absolute else 0)
PY
}

# Scan the complete rewritten artifact tree. Keep the signatures narrow: these
# are monorepo-only paths/repo references or tracker forms, not generic URLs,
# relative paths, hash characters, or every occurrence of "core/".
upstream_cut_verify_artifacts() {
	local out="$1"
	python3 - "$out" <<'PY'
import ipaddress, re, sys
from pathlib import Path
from urllib.parse import urlsplit

root = Path(sys.argv[1])
relative_prefix = r'(?<![A-Za-z0-9_.-])(?:\./|\.\./)*'
token_end = r'(?![A-Za-z0-9_-]|\.[A-Za-z0-9])'
dns_host = re.compile(
    r'(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+'
    r'(?:[a-z]{2,}|xn--[a-z0-9-]{2,})\.?', re.I
)
single_label_host = re.compile(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.?', re.I)
absolute_url = re.compile(
    r'(?i)(?<![A-Za-z0-9_.+-])https?://[^\s<>`]+'
)
protocol_relative_url = re.compile(r'(?<![A-Za-z0-9_.:/-])//[^\s<>`]+')

def valid_url_host(host, allow_single_label=False):
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        try:
            ascii_host = host.encode('idna').decode('ascii')
        except UnicodeError:
            return False
        if dns_host.fullmatch(ascii_host):
            return True
        return allow_single_label and single_label_host.fullmatch(ascii_host) is not None

def url_spans(line):
    for pattern, relative in ((absolute_url, False), (protocol_relative_url, True)):
        for match in pattern.finditer(line):
            candidate = match.group(0).rstrip('.,;:!?')
            if relative:
                candidate = 'https:' + candidate
            try:
                parsed = urlsplit(candidate)
                host = parsed.hostname
                parsed.port  # Validate that any port is numeric and in range.
            except ValueError:
                continue
            if parsed.scheme.lower() not in ('http', 'https') or not host:
                continue
            if valid_url_host(host, allow_single_label=not relative):
                yield match.span()
leaks = [
    ('monorepo path', re.compile(relative_prefix + r'(?:openwrt-feed|scripts|lab|docs)/', re.I)),
    ('monorepo changelog path', re.compile(relative_prefix + r'CHANGELOG(?:\.md)?' + token_end, re.I)),
    ('monorepo source path', re.compile(relative_prefix + r'core/fwlive-log(?:\.js)?' + token_end, re.I)),
    ('monorepo CSS generator identifier', re.compile(relative_prefix + r'embed-fwlive-css(?:\.js)?' + token_end, re.I)),
    ('monorepo design-doc path', re.compile(relative_prefix + r'docs/fwlive-ui-design-target(?:\.md)?' + token_end, re.I)),
    ('monorepo GitHub repo', re.compile(r'(?i)(?:github\.com/)?lucas-albers-lz4/fwlive\b')),
    ('monorepo-only README/config reference', re.compile(r'(?i)\b(?:feeds\.conf\.example|in the fwlive repo|snapshot from the fwlive monorepo|regenerated? upstream of this tree|multi-model audit)\b')),
    ('internal tracker key', re.compile(r'(?i)\bissue\s+[A-Z]{1,3}-[0-9]+\b')),
    ('explicit numeric tracker reference', re.compile(r'(?i)\b(?:issue|Grok)\s+#\d+\b')),
    ('do-not-edit instruction', re.compile(r'(?i)\bdo not edit\b')),
    ('generated-source instruction', re.compile(r'(?i)GENERATED FILE\s*[—-]\s*do not edit')),
]
tracker = re.compile(r'(?<![A-Za-z0-9_])#([0-9]{2,})(?![A-Za-z0-9_])')
hex_color = re.compile(r'#[0-9a-fA-F]+')
color_property = re.compile(
    r'(?:--fwlive-(?:pass|deny|paused)-color|--fwlive-bg-medium|'
    r'color|background(?:-color|-image)?|'
    r'border(?:-(?:top|right|bottom|left))?(?:-color)?|outline(?:-color)?|'
    r'box-shadow|text-shadow|text-decoration-color|column-rule-color|'
    r'caret-color|accent-color|fill|stroke|stop-color|flood-color|lighting-color)', re.I
)
css_carrier = 'htdocs/luci-static/resources/fwlive/css.js'
tint_carrier = 'htdocs/luci-static/resources/fwlive/tint.js'

def css_declaration_bounds(line, start, end):
    # css.js carries escaped newlines (\\n) in one generated source line.
    separators = (r'\n', ';', '{', '}')
    left = 0
    right = len(line)
    for separator in separators:
        before = line.rfind(separator, 0, start)
        if before >= 0:
            left = max(left, before + len(separator))
        after = line.find(separator, end)
        if after >= 0:
            right = min(right, after)
    return left, right

def split_function_args(value):
    args = []
    depth = 0
    start = 0
    for index, char in enumerate(value):
        if char == '(':
            depth += 1
        elif char == ')':
            depth -= 1
            if depth < 0:
                return []
        elif char == ',' and depth == 0:
            args.append(value[start:index].strip())
            start = index + 1
    if depth != 0:
        return []
    args.append(value[start:].strip())
    return args

def css_color_value(value):
    # Exempt only a whole hex color (optionally reached through a var() fallback).
    # Composite or malformed values fail closed instead of granting every hash
    # in a color-bearing declaration the same exemption.
    value = re.sub(r'\\[tr]', ' ', value).strip()
    value = re.sub(r'\s*!important\s*$', '', value, flags=re.I).strip()
    if re.fullmatch(r'#[0-9a-fA-F]+', value):
        return len(value) - 1 in (3, 4, 6, 8)
    if not value.lower().startswith('var(') or not value.endswith(')'):
        return False
    args = split_function_args(value[4:-1])
    return (len(args) == 2
            and re.fullmatch(r'--[A-Za-z0-9_-]+', args[0]) is not None
            and css_color_value(args[1]))

def color_value_context(line, match):
    before = line[:match.start()]
    if before.rfind('/*') > before.rfind('*/'):
        return False
    start, end = css_declaration_bounds(line, match.start(), match.end())
    declaration = line[start:end]
    property_part, separator, value_part = declaration.partition(':')
    property_part = re.sub(r'\\[tr]', ' ', property_part).strip()
    if not separator or not color_property.fullmatch(property_part):
        return False
    color_matches = list(hex_color.finditer(value_part))
    if len(color_matches) != 1 or len(color_matches[0].group(0)) - 1 not in (3, 4, 6, 8):
        return False
    value_start = start + declaration.index(':') + 1
    value_before = line[value_start:match.start()]
    if value_before.lower().rfind('url(') > value_before.rfind(')'):
        return False
    quote = None
    escaped = False
    for char in value_before:
        if escaped:
            escaped = False
        elif char == '\\':
            escaped = True
        elif quote and char == quote:
            quote = None
        elif not quote and char in ('"', "'"):
            quote = char
    if quote is not None or not css_color_value(value_part):
        return False
    return True

def mask_css_comments(text):
    # Keep offsets and line breaks stable while removing comments from the
    # color-context view. Tracker scanning still uses the original source.
    chars = list(text)
    comment = False
    quote = None
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        if comment:
            if text.startswith('*/', index):
                chars[index] = chars[index + 1] = ' '
                comment = False
                index += 2
                continue
            if char not in ('\r', '\n'):
                chars[index] = ' '
            index += 1
            continue
        if quote:
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == quote:
                quote = None
            index += 1
            continue
        if text.startswith('/*', index):
            chars[index] = chars[index + 1] = ' '
            comment = True
            index += 2
            continue
        if char in ('"', "'"):
            quote = char
        index += 1
    return ''.join(chars)

def mask_js_noncode(text):
    # Preserve offsets while excluding comments and string/template contents
    # from declaration matching. Tracker checks still use the original source.
    chars = list(text)
    comment = None
    quote = None
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        if comment == 'line':
            if char in ('\r', '\n'):
                comment = None
            else:
                chars[index] = ' '
            index += 1
            continue
        if comment == 'block':
            if text.startswith('*/', index):
                chars[index] = chars[index + 1] = ' '
                comment = None
                index += 2
                continue
            if char not in ('\r', '\n'):
                chars[index] = ' '
            index += 1
            continue
        if quote:
            if char not in ('\r', '\n'):
                chars[index] = ' '
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == quote:
                quote = None
            index += 1
            continue
        if text.startswith('//', index):
            chars[index] = chars[index + 1] = ' '
            comment = 'line'
            index += 2
            continue
        if text.startswith('/*', index):
            chars[index] = chars[index + 1] = ' '
            comment = 'block'
            index += 2
            continue
        if char in ('"', "'", '`'):
            chars[index] = ' '
            quote = char
        index += 1
    return ''.join(chars)

def color_spans(line, suffix, relative, color_line=None):
    # Real CSS assets carry color syntax directly; fwlive embeds its stylesheet
    # and tint palette in two JavaScript modules, so inspect only their literal
    # color contexts and retain tracker checks elsewhere in those files.
    if suffix.lower() == '.css':
        context = line if color_line is None else color_line
        spans = []
        for match in hex_color.finditer(context):
            if color_value_context(context, match):
                spans.append(match.span())
        return spans

    if relative == css_carrier:
        # embed-fwlive-css.js emits one JSON.stringify double-quoted literal on
        # one source line. Other shapes are deliberately left unexempted, so a
        # numeric CSS color there fails closed instead of hiding tracker text.
        style = re.search(r'\bstyleText\s*:\s*("(?:\\.|[^"\\])*")', line)
        if not style:
            return []
        content = style.group(1)[1:-1]
        offset = style.start(1) + 1
        spans = []
        for match in hex_color.finditer(content):
            if not color_value_context(content, match):
                continue
            spans.append((offset + match.start(), offset + match.end()))
        return spans

    if relative == tint_carrier:
        assignment = re.compile(
            r'\b(?:var|let|const)\s+[A-Za-z_$][A-Za-z0-9_$]*_HEX\s*=\s*'
            r'(?P<quote>["\'])(?P<value>#[0-9a-fA-F]+)(?P=quote)'
        )
        spans = []
        for declared in assignment.finditer(line):
            code_line = line if color_line is None else color_line
            if declared.start() >= len(code_line) or code_line[declared.start()].isspace():
                continue
            value = declared.group('value')
            if len(value) - 1 in (3, 4, 6, 8):
                start = declared.start('value')
                spans.append((start, start + len(value)))
        return spans

    return []

def tracker_ids(line, suffix, relative, color_line=None):
    # URL fragments are legitimate. Scan every emitted line for bare tracker
    # forms, not only comments; exempt only actual CSS/palette color literals.
    line_url_spans = list(url_spans(line))
    line_color_spans = color_spans(line, suffix, relative, color_line)
    for match in tracker.finditer(line):
        if any(start <= match.start() < end for start, end in line_url_spans):
            continue
        if any(start <= match.start() < end for start, end in line_color_spans):
            continue
        yield match


hits = []
if not root.is_dir():
    print('  FAIL: artifact scan root is missing: %s' % root)
    sys.exit(1)
for path in sorted(root.rglob('*')):
    if path.is_symlink():
        hits.append('%s: symlink is not supported in cut artifact' % path.relative_to(root))
        continue
    if not path.is_file():
        continue
    text = path.read_text(encoding='utf-8', errors='replace')
    relative = path.relative_to(root).as_posix()
    if path.suffix.lower() == '.css':
        color_scan_text = mask_css_comments(text)
    elif relative == tint_carrier:
        color_scan_text = mask_js_noncode(text)
    else:
        color_scan_text = text
    for number, (line, color_line) in enumerate(
            zip(text.splitlines(), color_scan_text.splitlines()), 1):
        line_url_spans = list(url_spans(line))
        for label, pattern in leaks:
            for match in pattern.finditer(line):
                in_url = any(start <= match.start() < end for start, end in line_url_spans)
                if label != 'monorepo GitHub repo' and in_url:
                    continue
                hits.append('%s:%d: %s: %s' %
                            (path.relative_to(root), number, label, line.strip()[:160]))
        for match in tracker_ids(line, path.suffix, relative, color_line):
            hits.append('%s:%d: numeric tracker reference #%s: %s' %
                        (path.relative_to(root), number, match.group(1), line.strip()[:160]))
if hits:
    for hit in hits[:20]:
        print('  FAIL: post-rewrite artifact leakage: %s' % hit)
    sys.exit(1)
sys.exit(0)
PY
}

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

if grep -q 'lucas-albers-lz4/fwlive' "$OUT/README.md"; then
	echo "  FAIL: luci README still cites the out-of-tree GitHub repo" >&2
	fail=1
fi

if grep -qE '^## (Maintenance|Documentation)$' "$OUT/README.md"; then
	echo "  FAIL: luci README still has Maintenance or Documentation sections" >&2
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

if ! upstream_cut_verify_pot_refs "$OUT" "$PKG"; then
	fail=1
fi

if ! upstream_cut_verify_readme_rows "$OUT"; then
	fail=1
fi

if grep -rn 'TOPDIR)/feeds/luci' "$OUT/Makefile" >/dev/null 2>&1; then
	echo "  FAIL: feed-path luci.mk include remains in Makefile" >&2
	fail=1
fi

if ! upstream_cut_verify_artifacts "$OUT"; then
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

# Point the canonical ref at the verified split before dropping the temp
# branch. A checked-out canonical branch cannot be force-updated; keep the
# temp branch so the EXIT trap does not delete the only good cut (#890).
upstream_cut_promote_canonical() {
	local current
	KEEP_SPLIT_BRANCH=1
	current="$(git branch --show-current)"
	if [[ "$current" == "$CANONICAL_SPLIT_BRANCH" ]]; then
		echo "ERROR: ${CANONICAL_SPLIT_BRANCH} is checked out; verified split kept on ${SPLIT_BRANCH}" >&2
		return 1
	fi
	if ! git branch -f "$CANONICAL_SPLIT_BRANCH" "$SPLIT_BRANCH"; then
		echo "ERROR: could not update ${CANONICAL_SPLIT_BRANCH}; verified split kept on ${SPLIT_BRANCH}" >&2
		return 1
	fi
	git branch -D "$SPLIT_BRANCH" >/dev/null 2>&1 || true
	SPLIT_BRANCH="$CANONICAL_SPLIT_BRANCH"
}

# Promote only after the cut verifies. Replacing first would drop a good
# canonical branch if a later check failed (#841 review).
if [[ "$REPLACE_CANONICAL" == 1 ]]; then
	upstream_cut_promote_canonical
fi

echo "  OK: $out_count files (source $src_count minus $drop_count); Makefile include rewritten;"
echo "  OK: luci README has no out-of-tree GitHub links; po template present; locale dirs dropped"

echo "== 5/5 next steps =="
echo "  Copy $OUT into a luci fork at luci/applications/luci-app-fwlive/"
echo "  Optional: re-run luci ./build/i18n-scan.pl in that tree and diff — the cut .pot is already luci-shaped (paths + line numbers)."
echo "  Apache-2.0 in PR body (PKG_LICENSE already set)."
