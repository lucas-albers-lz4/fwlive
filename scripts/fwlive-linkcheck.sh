#!/usr/bin/env bash
# fwlive link check: internal markdown links (strict) + external URLs (404 = fail).
# Scans git-tracked *.md only (skips local SDK/openwrt trees).
# Run via: npm run test:links   (or CI: ./scripts/fwlive-linkcheck.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== internal markdown links (file + anchor) =="
python3 - <<'PYEOF'
import os, re, subprocess, sys


def heading_slugs(path):
    """GitHub-style anchor slugs for every heading in a markdown file."""
    slugs = set()
    try:
        txt = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return slugs
    for line in txt.splitlines():
        if not re.match(r'^#{1,6}\s', line):
            continue
        text = re.sub(r'^#{1,6}\s+', '', line).strip()
        # GitHub slugger: lowercase, strip punctuation, spaces -> '-'
        slug = re.sub(r'[^\w\s-]', '', text.lower()).replace(' ', '-')
        slugs.add(slug)
    return slugs


files = subprocess.check_output(
    ['git', 'ls-files', '*.md'], text=True
).splitlines()

broken = []
checked = 0
for path in files:
    dirpath = os.path.dirname(path) or '.'
    try:
        txt = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        continue
    for m in re.finditer(r'\[[^\]]*\]\(([^)]+)\)', txt):
        target = m.group(1).split('?')[0].strip()
        if not target or target.startswith(('http://', 'https://', 'mailto:')):
            continue
        if '#' in target:
            filepart, anchor = target.split('#', 1)
        else:
            filepart, anchor = target, None
        checked += 1
        full = os.path.normpath(os.path.join(dirpath, filepart))
        if not os.path.exists(full):
            broken.append((path, target, f"file missing: {full}"))
            continue
        if anchor is not None:
            # Heading-only links (bare '#foo') resolve against the same file.
            # If a target file has NO headings, treat '#' links as unchecked
            # rather than broken (e.g. generated content).
            slugs = heading_slugs(full)
            if slugs and anchor not in slugs:
                broken.append((path, target, f"anchor missing in {full}: #{anchor}"))

if broken:
    for path, target, why in broken:
        print(f"  BROKEN: {path}: -> {target} ({why})")
    print(f"internal links checked: {checked}, broken: {len(broken)}")
    sys.exit(1)
print(f"internal links checked: {checked}, broken: 0")
PYEOF

echo "== external URLs (404 = fail; 403/429/5xx = warn) =="
python3 - <<'PYEOF'
import os, re, subprocess, sys

files = subprocess.check_output(
    ['git', 'ls-files', '*.md'], text=True
).splitlines()

urls = set()
for path in files:
    try:
        txt = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        continue
    for m in re.finditer(r'\[[^\]]*\]\((https?://[^)\s]+)\)', txt):
        urls.add(m.group(1).rstrip('.,;:'))

# Lab / local examples (QEMU LuCI) — not reachable from CI
SKIP_HOST_RE = re.compile(
    r'^https?://(127\.0\.0\.1|localhost|\[::1\])(:|/|$)', re.I
)

fails, warns = [], []
skipped = 0
for u in sorted(urls):
    if SKIP_HOST_RE.match(u):
        skipped += 1
        continue
    try:
        r = subprocess.run(
            ['curl', '-sL', '-o', '/dev/null', '-w', '%{http_code}',
             '-A', 'Mozilla/5.0 (X11; Linux x86_64)', '--max-time', '15', u],
            capture_output=True, text=True, timeout=20)
        code = r.stdout.strip()
        if code.startswith('2') or code.startswith('3'):
            continue
        if code in ('403', '429', '500', '502', '503', '504'):
            warns.append((u, code))
        else:
            fails.append((u, code))
    except Exception as e:
        warns.append((u, f'error: {e}'))

for u, code in warns:
    print(f"  WARN: {u} -> {code} (bot protection / rate limit / timeout)")
for u, code in fails:
    print(f"  FAIL: {u} -> {code}")

print(
    f"external URLs checked: {len(urls)}, failed: {len(fails)}, "
    f"warned: {len(warns)}, skipped-local: {skipped}"
)
sys.exit(1 if fails else 0)
PYEOF
