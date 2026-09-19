#!/usr/bin/env bash
# Regression pin for #375 / #377: the AMD-wrap processor lints a virtual
# `<name>.js.wrapped` filename, and flat config matches per filename. If the
# `**/*.js.wrapped` block is dropped, `npm run lint:js` exits 0 with no rules
# applied. --print-config on the virtual path must keep no-undef at error, and
# a planted probe must still fire no-restricted-properties on the wrap path.
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
rules = cfg.get("rules") or {}

def severity(name):
    val = rules.get(name)
    return val[0] if isinstance(val, list) else val

for name in ("no-undef", "no-new-func", "no-implied-eval", "no-restricted-properties"):
    sev = severity(name)
    if sev not in ("error", 2):
        sys.stderr.write("FAIL: %s is %r on chips.js.wrapped (expected error)\n" % (name, rules.get(name)))
        sys.exit(1)

restricted = rules.get("no-restricted-properties")
entries = restricted[1:] if isinstance(restricted, list) else []
wanted = {("globalThis", "Function"), ("window", "Function")}
found = {(e.get("object"), e.get("property")) for e in entries if isinstance(e, dict)}
missing = wanted - found
if missing:
    sys.stderr.write("FAIL: no-restricted-properties missing %r on chips.js.wrapped\n" % (sorted(missing),))
    sys.exit(1)
print("ok: AMD-wrap virtual filename has dynamic-code rules at error")
'

PROBE_DIR="openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive"
PROBE="$PROBE_DIR/_eslint-function-probe.js"
cleanup() { rm -f "$PROBE"; }
trap cleanup EXIT
cat > "$PROBE" <<'EOF'
globalThis.Function("return 1");
window.Function("return 1");
window["Function"]("return 1");
EOF

PROBE_JSON="$("$ESLINT" --format json --no-error-on-unmatched-pattern "$PROBE" || true)"
python3 -c '
import json, sys

reports = json.loads(sys.stdin.read() or "[]")
messages = []
for report in reports:
    messages.extend(report.get("messages") or [])
hits = [m for m in messages if m.get("ruleId") == "no-restricted-properties"]
if len(hits) < 3:
    sys.stderr.write(
        "FAIL: expected 3 no-restricted-properties hits on wrap-path probe, got %d: %s\n"
        % (len(hits), json.dumps(messages, indent=2))
    )
    sys.exit(1)
print("ok: wrap-path probe fires no-restricted-properties on globalThis/window.Function")
' <<< "$PROBE_JSON"
