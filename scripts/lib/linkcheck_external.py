#!/usr/bin/env python3
"""External URL probe used by scripts/fwlive-linkcheck.sh (#461).

The retry-to-fail dispatch lives here so tests can drive the same branch
the CI script runs (curl shim / FWLIVE_LINKCHECK_URLS) without hitting
the live network.
"""

import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from linkcheck_classify import classify_code, classify_retry  # noqa: E402

SKIP_HOST_RE = re.compile(
    r'^https?://(127\.0\.0\.1|localhost|\[::1\])(:|/|$)', re.I
)


def curl_bin():
    return os.environ.get('FWLIVE_LINKCHECK_CURL', 'curl')


def http_code(url):
    r = subprocess.run(
        [curl_bin(), '-sL', '-o', '/dev/null', '-w', '%{http_code}',
         '-A', 'Mozilla/5.0 (X11; Linux x86_64)', '--max-time', '15', url],
        capture_output=True, text=True, timeout=20)
    return r.stdout.strip()


def collect_markdown_urls():
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
    return urls


def urls_from_env():
    raw = os.environ.get('FWLIVE_LINKCHECK_URLS', '').strip()
    if not raw:
        return None
    return set(raw.split())


def record_retry(first_code, retry_code):
    """Map a 000-then-retry pair to (bucket, label).

    Failures keep the retry evidence ('000 then 404') so a retried miss
    is not indistinguishable from a first-probe 404 (#461).
    """
    first = (first_code or '').strip() or '000'
    retry = (retry_code or '').strip() or '000'
    verdict = classify_retry(first, retry)
    if verdict == 'ok':
        return 'ok', retry
    if verdict == 'fail':
        return 'fail', f'{first} then {retry}'
    return 'warn', retry


def probe_urls(urls):
    fails, warns = [], []
    skipped = 0
    for u in sorted(urls):
        if SKIP_HOST_RE.match(u):
            skipped += 1
            continue
        try:
            code = http_code(u)
            verdict = classify_code(code)
            if verdict == 'ok':
                continue
            if verdict == 'warn':
                if code == '000':
                    try:
                        code2 = http_code(u)
                        bucket, label = record_retry(code, code2)
                        if bucket == 'ok':
                            continue
                        if bucket == 'fail':
                            fails.append((u, label))
                        else:
                            warns.append((u, label))
                    except Exception:
                        warns.append((u, '000 (retry also failed)'))
                else:
                    warns.append((u, code))
            else:
                fails.append((u, code))
        except Exception as e:
            warns.append((u, f'error: {e}'))
    return fails, warns, skipped


def main():
    urls = urls_from_env()
    if urls is None:
        urls = collect_markdown_urls()
    fails, warns, skipped = probe_urls(urls)
    for u, code in warns:
        print(f"  WARN: {u} -> {code} (bot protection / rate limit / timeout)")
    for u, code in fails:
        print(f"  FAIL: {u} -> {code}")
    print(
        f"external URLs checked: {len(urls)}, failed: {len(fails)}, "
        f"warned: {len(warns)}, skipped-local: {skipped}"
    )
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
