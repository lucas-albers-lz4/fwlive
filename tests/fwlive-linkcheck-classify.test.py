#!/usr/bin/env python3
"""Unit tests for the linkcheck external-URL classifier."""

import sys


def classify(code):
    """Replicate the classification logic from scripts/fwlive-linkcheck.sh."""
    if code.startswith('2') or code.startswith('3'):
        return 'ok'
    if code in ('403', '429', '500', '502', '503', '504'):
        return 'warn'
    if code == '000':
        return 'warn'
    return 'fail'


def test_000_warns():
    assert classify('000') == 'warn', f"expected warn, got {classify('000')}"


def test_200_ok():
    assert classify('200') == 'ok'


def test_301_ok():
    assert classify('301') == 'ok'


def test_404_fails():
    assert classify('404') == 'fail', f"expected fail, got {classify('404')}"


def test_403_warns():
    assert classify('403') == 'warn'


def test_429_warns():
    assert classify('429') == 'warn'


def test_500_warns():
    assert classify('500') == 'warn'


def test_502_warns():
    assert classify('502') == 'warn'


def test_503_warns():
    assert classify('503') == 'warn'


def test_504_warns():
    assert classify('504') == 'warn'


def test_other_fail():
    assert classify('410') == 'fail'
    assert classify('418') == 'fail'
    assert classify('451') == 'fail'


if __name__ == '__main__':
    failures = 0
    for name, fn in list(globals().items()):
        if name.startswith('test_') and callable(fn):
            try:
                fn()
            except AssertionError as e:
                print(f"FAIL: {name}: {e}")
                failures += 1
            else:
                print(f"  OK: {name}")
    if failures:
        print(f"\n{failures} test(s) failed")
        sys.exit(1)
    print("\nall tests passed")
