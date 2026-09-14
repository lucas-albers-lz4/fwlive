#!/usr/bin/env bash
# Regression checks for the optional versus required i18n parity modes (#334).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MISSING_SCAN="$ROOT/tests/does-not-exist-i18n-scan.pl"
REQUIRED_OUTPUT=$(mktemp)
trap 'rm -f "$REQUIRED_OUTPUT"' EXIT

die() { echo "fwlive-upstream-cut mode test FAIL: $*" >&2; exit 1; }

optional_output=$(
	FWLIVE_I18N_SCAN="$MISSING_SCAN" \
		FWLIVE_I18N_REQUIRE_SCAN=0 \
		bash "$ROOT/tests/fwlive-upstream-cut.test.sh" 2>&1
) || die "optional mode rejected missing scanner"

grep -Fq "SKIP: msgid parity no i18n-scan.pl; set FWLIVE_I18N_SCAN" <<<"$optional_output" \
	|| die "optional mode did not report an explicit skip"
grep -Fq "fresh msgid parity SKIPPED" <<<"$optional_output" \
	|| die "optional mode did not report its summary"

if FWLIVE_I18N_SCAN="$MISSING_SCAN" \
	FWLIVE_I18N_REQUIRE_SCAN=1 \
	bash "$ROOT/tests/fwlive-upstream-cut.test.sh" >"$REQUIRED_OUTPUT" 2>&1; then
	die "required mode accepted missing scanner"
fi
grep -Fq "msgid parity required but unavailable: no i18n-scan.pl; set FWLIVE_I18N_SCAN" \
	"$REQUIRED_OUTPUT" \
	|| die "required mode did not report the missing scanner"

echo "fwlive-upstream-cut mode tests passed"
