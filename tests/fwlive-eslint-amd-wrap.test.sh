#!/usr/bin/env bash
# Regression pin for #375 / #377: the AMD-wrap processor lints a virtual
# `<name>.js.wrapped` filename, and flat config matches per filename. If the
# `**/*.js.wrapped` block is dropped, `npm run lint:js` exits 0 with no rules
# applied. --print-config on the virtual path must keep no-undef at error.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ESLINT="$ROOT/node_modules/.bin/eslint"
if [[ ! -x "$ESLINT" ]]; then
	echo "FAIL: eslint not found at $ESLINT (run npm ci)" >&2
	exit 1
fi

WRAPPED="openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/chips.js.wrapped"

"$ESLINT" --print-config "$WRAPPED" | python3 -c '
import json, sys

cfg = json.load(sys.stdin)
undef = (cfg.get("rules") or {}).get("no-undef")
severity = undef[0] if isinstance(undef, list) else undef
if severity not in ("error", 2):
    sys.stderr.write(
        "FAIL: no-undef is %r on chips.js.wrapped (expected error)\n" % (undef,)
    )
    sys.exit(1)
print("ok: AMD-wrap virtual filename has no-undef error")
'
