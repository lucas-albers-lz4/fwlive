#!/usr/bin/env python3
"""Linkcheck external-URL classification (production seam, wave #152).

Extracted from scripts/fwlive-linkcheck.sh so the classifier is a real,
importable unit — the test exercises THIS code, not a copy.

    classify_code('200') -> 'ok'    (2xx/3xx)
    classify_code('404') -> 'fail'  (genuine HTTP error)
    classify_code('000') -> 'warn'  (no HTTP response: DNS/TLS/timeout)
    classify_code('403') -> 'warn'  (bot protection / rate limit)

'warn' codes: 000, 403, 429, 500, 502, 503, 504. Everything else that
isn't 2xx/3xx is 'fail' (404, 410, 418, 451, ...).
"""

WARN_CODES = frozenset(('403', '429', '500', '502', '503', '504'))


def classify_code(code):
    """Classify an HTTP status code string.

    Returns 'ok' (2xx/3xx), 'warn' (000 + WARN_CODES), or 'fail'.
    An empty/None code is treated as a network-level failure ('000') —
    curl reported nothing, which is the same class as no response.
    """
    code = (code or '').strip()
    if not code:
        return 'warn'  # empty == '000' class
    if code[0] in ('2', '3'):
        return 'ok'
    if code in WARN_CODES:
        return 'warn'
    if code == '000':
        return 'warn'
    return 'fail'


if __name__ == '__main__':
    # Quick smoke when run directly: every classified sample prints.
    for sample in ('200', '301', '404', '410', '418', '451', '000', '403',
                   '429', '500', '502', '503', '504', ''):
        print(f"{sample!r:8} -> {classify_code(sample)}")
