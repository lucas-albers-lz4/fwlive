#!/usr/bin/env bash
# Self-test for the invariant rule set: the rules must stay silent on the real
# tree and must fire on a planted violation. Guards against rule rot (a rule that
# silently stops matching is worse than no rule).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED="0.45.3"

if ! command -v ast-grep >/dev/null 2>&1; then
	echo "Install ast-grep to run this test: pipx install 'ast-grep-cli==${EXPECTED}'" >&2
	exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. The shipped tree is compliant: the rule set reports nothing.
cd "$ROOT"
if ! out="$(ast-grep scan --config sgconfig.yml . 2>&1)"; then
	echo "FAIL: invariant rules reported findings on the shipped tree:" >&2
	printf '%s\n' "$out" >&2
	exit 1
fi

# 2. A planted violation must be caught - one per rule.
mkdir -p "$TMP/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive"
cat >"$TMP/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/probe.js" <<'EOF'
'use strict';
function probe(parts, untrusted) {
	const bare = E('td', {}, 'literal');
	const translated = E('td', {}, _('x'));
	const concatenated = E('td', {}, 'a' + untrusted);
	const dynamic = new Function('return 1');
	const sink = function (el, v) { el.innerHTML = v; };
	return [bare, translated, concatenated, dynamic, sink, parts];
}
return baseclass.extend({ probe: probe });
EOF

pushd "$TMP" >/dev/null
out="$(ast-grep scan --config "$ROOT/sgconfig.yml" . 2>&1 || true)"
popd >/dev/null

for id in fwlive-e-children-must-be-array fwlive-no-dynamic-code fwlive-html-sink-nonliteral; do
	if ! printf '%s\n' "$out" | grep -q "$id"; then
		echo "FAIL: rule '$id' did not fire on the planted violation" >&2
		printf '%s\n' "$out" >&2
		exit 1
	fi
done

# 3. Compliant shapes must stay silent (no friction on correct code).
cat >"$TMP/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/probe.js" <<'EOF'
'use strict';
function probe(parts) {
	const arrayForm = E('td', {}, [ 'literal' ]);
	const nodeChild = E('tr', {}, E('td', {}, [ 'x' ]));
	const identifierChild = E('td', {}, parts);
	const clearNode = function (el) { el.innerHTML = ''; };
	return [arrayForm, nodeChild, identifierChild, clearNode];
}
return baseclass.extend({ probe: probe });
EOF

pushd "$TMP" >/dev/null
if ! out="$(ast-grep scan --config "$ROOT/sgconfig.yml" . 2>&1)"; then
	popd >/dev/null
	echo "FAIL: compliant shapes were flagged (false positives):" >&2
	printf '%s\n' "$out" >&2
	exit 1
fi
popd >/dev/null

echo "ok: invariant rules silent on clean code, firing on planted violations"
