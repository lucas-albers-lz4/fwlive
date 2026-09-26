#!/usr/bin/env bash
# Regression pin for #581: core/**/*.js is linted as Node/CommonJS, not as
# LuCI AMD. --print-config must keep no-undef at error without luci-amd-wrap,
# and a planted undef in a core/ file must fail `npm run lint:js`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ESLINT="$ROOT/node_modules/.bin/eslint"
if [[ ! -x "$ESLINT" ]]; then
	echo "FAIL: eslint not found at $ESLINT (run npm ci)" >&2
	exit 1
fi

CORE_FILE="core/fwlive-log.js"

"$ESLINT" --print-config "$CORE_FILE" | python3 -c '
import json, sys

cfg = json.load(sys.stdin)
rules = cfg.get("rules") or {}
lang = cfg.get("languageOptions") or {}
processor = cfg.get("processor")

def severity(name):
    val = rules.get(name)
    return val[0] if isinstance(val, list) else val

sev = severity("no-undef")
if sev not in ("error", 2):
    sys.stderr.write("FAIL: no-undef is %r on core/fwlive-log.js (expected error)\n" % (rules.get("no-undef"),))
    sys.exit(1)

source_type = lang.get("sourceType")
if source_type != "commonjs":
    sys.stderr.write("FAIL: sourceType is %r on core/fwlive-log.js (expected commonjs)\n" % (source_type,))
    sys.exit(1)

if processor:
    sys.stderr.write("FAIL: core/fwlive-log.js has processor %r (expected none)\n" % (processor,))
    sys.exit(1)

print("ok: core/fwlive-log.js is Node/CommonJS with no-undef and no AMD wrap")
'

BACKUP="$(mktemp)"
cleanup() { cp "$BACKUP" "$CORE_FILE"; rm -f "$BACKUP"; }
cp "$CORE_FILE" "$BACKUP"
trap cleanup EXIT

printf '\nnotDefinedAtAll();\n' >>"$CORE_FILE"

set +e
LINT_OUT="$(npm run lint:js 2>&1)"
LINT_STATUS=$?
set -e

if [[ "$LINT_STATUS" -eq 0 ]]; then
	echo "FAIL: planted core/ undef probe: lint:js exited 0" >&2
	printf '%s\n' "$LINT_OUT" >&2
	exit 1
fi
if ! printf '%s\n' "$LINT_OUT" | grep -Fq 'notDefinedAtAll'; then
	echo "FAIL: lint:js failed but did not report planted notDefinedAtAll" >&2
	printf '%s\n' "$LINT_OUT" >&2
	exit 1
fi
if ! printf '%s\n' "$LINT_OUT" | grep -Fq 'no-undef'; then
	echo "FAIL: lint:js failed but did not report no-undef on the core/ plant" >&2
	printf '%s\n' "$LINT_OUT" >&2
	exit 1
fi
echo "ok: planted core/ undef fails lint:js"
