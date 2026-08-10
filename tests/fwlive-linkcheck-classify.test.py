#!/usr/bin/env python3
"""Unit tests for the linkcheck external-URL classifier (production seam).

Exercises scripts/lib/linkcheck_classify.py — the SAME module the
linkcheck script imports (not a copy). If the production classifier
regresses (e.g. '000' re-classified as fail), these tests fail.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', 'scripts', 'lib'))
from linkcheck_classify import classify_code


def test_000_warns():
    assert classify_code('000') == 'warn'


def test_empty_code_warns():
    # curl reported nothing (empty) == '000' class: no HTTP response.
    assert classify_code('') == 'warn'
    assert classify_code(None) == 'warn'


def test_200_ok():
    assert classify_code('200') == 'ok'


def test_301_ok():
    assert classify_code('301') == 'ok'


def test_404_fails():
    assert classify_code('404') == 'fail'


def test_403_warns():
    assert classify_code('403') == 'warn'


def test_429_warns():
    assert classify_code('429') == 'warn'


def test_5xx_warns():
    for c in ('500', '502', '503', '504'):
        assert classify_code(c) == 'warn', f'{c} should warn'


def test_other_fail():
    for c in ('410', '418', '451'):
        assert classify_code(c) == 'fail', f'{c} should fail'


def test_whitespace_stripped():
    assert classify_code(' 404 ') == 'fail'
    assert classify_code(' 200\n') == 'ok'


def test_verdicts_cover_all_codes():
    """Every plausible code gets exactly one of ok/warn/fail."""
    for c in ('200', '301', '404', '410', '418', '451', '000', '403',
              '429', '500', '502', '503', '504', ''):
        v = classify_code(c)
        assert v in ('ok', 'warn', 'fail'), f'{c!r} -> {v}'


def _run(name):
    fn = globals()[name]
    fn()
    print(f"  OK: {name}")


if __name__ == '__main__':
    for name in sorted(n for n in globals() if n.startswith('test_')):
        _run(name)
    print('all tests passed')
