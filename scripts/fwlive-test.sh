#!/usr/bin/env bash
# Run Firewall Live View unit tests and CLI checks (no browser).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NODE="${NODE:-}"
if [[ -z "$NODE" ]]; then
	if command -v node >/dev/null 2>&1; then
		NODE=node
	elif command -v nodejs >/dev/null 2>&1; then
		NODE=nodejs
	else
		echo "Install nodejs (e.g. apt install nodejs) to run fwlive tests." >&2
		exit 1
	fi
fi

echo "== fwlive view syntax (node --check) ==" >&2
"$NODE" --check openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js

echo "== fwlive shellcheck (libexec/rpcd) ==" >&2
bash "$ROOT/scripts/fwlive-shellcheck.sh"

echo "== fwlive parser sync (core vs LuCI) ==" >&2
"$NODE" tests/fwlive-parser-sync.test.js

echo "== fwlive parser/filter ==" >&2
"$NODE" tests/fwlive-parser-filter.test.js

echo "== fwlive firewall filter (fixtures) ==" >&2
"$NODE" tests/fwlive-firewall-filter.test.js

echo "== fwlive shell filter parity ==" >&2
"$NODE" tests/fwlive-shell-filter.test.js

echo "== fwlive classify spec ==" >&2
"$NODE" tests/fwlive-classify-spec.test.js

echo "== fwlive codegen freshness ==" >&2
"$NODE" tests/fwlive-codegen.test.js

echo "== fwlive rpcd security ==" >&2
"$NODE" tests/fwlive-rpcd-security.test.js

echo "== fwlive schema (stage 2) ==" >&2
"$NODE" tests/fwlive-schema.test.js

echo "== fwlive menu depends (ACL-only / #70) ==" >&2
"$NODE" tests/fwlive-menu-depends.test.js

echo "== fwlive theme CSS (LuCI dark mode / tint resilience) ==" >&2
"$NODE" tests/fwlive-theme-css.test.js

echo "== fwlive theme tint helpers ==" >&2
"$NODE" tests/fwlive-theme-tint.test.js

echo "== fwlive extracted modules smoke ==" >&2
"$NODE" tests/fwlive-modules-smoke.test.js

echo "== fwlive LuCI-accurate E() harness (#149) ==" >&2
"$NODE" tests/fwlive-e-harness.test.js

echo "== fwlive hostname cache ==" >&2
"$NODE" tests/fwlive-hostname-cache.test.js

echo "== fwlive i18n (PO completeness) ==" >&2
"$NODE" tests/fwlive-i18n.test.js

echo "== fwlive pause/resume buffer ==" >&2
"$NODE" tests/fwlive-pause-resume-buffer.test.js

echo "== fwlive filter negate toggle ==" >&2
"$NODE" tests/fwlive-filter-negate.test.js

echo "== fwlive feed release assets ==" >&2
bash tests/feed-publish-release-assets.test.sh

echo "== fwlive logging lock (race) ==" >&2
bash tests/fwlive-logging-lock.test.sh

echo "== fwlive rules map (iptables-save) ==" >&2
"$NODE" tests/fwlive-rules-map.test.js

echo "== fwlive linkcheck classifier ==" >&2
python3 tests/fwlive-linkcheck-classify.test.py

echo "== fwlive CLI pipeline ==" >&2
"$NODE" tests/fwlive-cli-pipeline.test.js

echo "== fwlive parser benchmark ==" >&2
"$NODE" tests/fwlive-parser-bench.js

echo "All fwlive tests passed." >&2
