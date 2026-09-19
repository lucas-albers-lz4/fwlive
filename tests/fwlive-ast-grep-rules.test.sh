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

# 2. A planted violation must be caught - one per rule, plus the shapes that
# used to bypass the E()/HTML-sink patterns (identifier attrs, 2-arg E(), +=).
mkdir -p "$TMP/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive"
cat >"$TMP/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/probe.js" <<'EOF'
'use strict';
function probe(parts, untrusted, timeAttrs) {
	const bare = E('td', {}, 'literal');
	const translated = E('td', {}, _('x'));
	const concatenated = E('td', {}, 'a' + untrusted);
	const identAttrs = E('td', timeAttrs, 'literal');
	const twoArg = E('div', 'literal');
	const twoArgI18n = E('span', _('x'));
	const dynamic = new Function('return 1');
	const sink = function (el, v) { el.innerHTML = v; };
	const appendSink = function (el, v) { el.innerHTML += v; };
	return [bare, translated, concatenated, identAttrs, twoArg, twoArgI18n, dynamic, sink, appendSink, parts];
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

e_hits="$(printf '%s\n' "$out" | grep -c 'fwlive-e-children-must-be-array' || true)"
if [[ "$e_hits" -lt 6 ]]; then
	echo "FAIL: expected >=6 e-children hits (3-arg, ident attrs, 2-arg), got ${e_hits}" >&2
	printf '%s\n' "$out" >&2
	exit 1
fi
sink_hits="$(printf '%s\n' "$out" | grep -c 'fwlive-html-sink-nonliteral' || true)"
if [[ "$sink_hits" -lt 2 ]]; then
	echo "FAIL: expected >=2 html-sink hits (assignment and +=), got ${sink_hits}" >&2
	printf '%s\n' "$out" >&2
	exit 1
fi

# 3. Compliant shapes must stay silent (no friction on correct code).
cat >"$TMP/openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/probe.js" <<'EOF'
'use strict';
function probe(parts, timeAttrs) {
	const arrayForm = E('td', {}, [ 'literal' ]);
	const nodeChild = E('tr', {}, E('td', {}, [ 'x' ]));
	const identifierChild = E('td', {}, parts);
	const identAttrsArray = E('td', timeAttrs, [ 'literal' ]);
	const twoArgAttrs = E('div', { 'class': 'x' });
	const clearNode = function (el) { el.innerHTML = ''; };
	return [arrayForm, nodeChild, identifierChild, identAttrsArray, twoArgAttrs, clearNode];
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
