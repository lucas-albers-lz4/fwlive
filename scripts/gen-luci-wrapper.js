#!/usr/bin/env node
'use strict';

/**
 * LuCI wrapper gate for gen-all.sh: verifies preserve markers, CLASSIFY_SPEC surface,
 * spec-derived classify regex parity, and ES5 API constraints; emits committed log.js
 * bytes (idempotent).
 *
 * This is a gate, not a generator: shared classify logic in log.js is hand-maintained
 * and must stay deep-equal to core CLASSIFY_SPEC with regexes derived from it. Running
 * gen-all.sh re-emits the committed file only after checks pass.
 */

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const ROOT = path.join(__dirname, '..');
const LUCI = process.argv[2]
	? path.resolve(process.argv[2])
	: path.join(ROOT,
		'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js');
const core = require(path.join(ROOT, 'core', 'fwlive-log.js'));

const src = fs.readFileSync(LUCI, 'utf8');

assert.ok(src.indexOf('@fwlive-codegen:luci-preserve-begin') >= 0, 'missing luci-preserve-begin');
assert.ok(src.indexOf('@fwlive-codegen:luci-preserve-end') >= 0, 'missing luci-preserve-end');
assert.ok(src.indexOf('CLASSIFY_SPEC') >= 0, 'missing CLASSIFY_SPEC');
assert.ok(src.indexOf('evaluateClassifySpec') >= 0, 'missing evaluateClassifySpec');
assert.ok(src.indexOf('gen-all.sh') >= 0, 'missing gen-all.sh banner');
assert.ok(src.indexOf('.includes(') < 0 && src.indexOf('Object.values') < 0,
	'LuCI wrapper must not use Array.includes or Object.values');

function wordPattern(words) {
	const alt = words.join('|');
	return new RegExp('(^|[^A-Za-z0-9_])(' + alt + ')([^A-Za-z0-9_]|$)', 'i');
}

/** Build classify regexes from CLASSIFY_SPEC (mirror core/fwlive-log.js). */
function buildClassifyRegexes(spec) {
	const denyClass = spec.actionWords.slice(3);
	return {
		NON_FIREWALL_PREFIX: new RegExp(
			'^(' + spec.nonFirewallPrefixes.join('|') + ')(' +
				(spec.nonFirewallPrefixHyphenContinuation ? '[^A-Za-z0-9_-]' : '[^A-Za-z0-9_]') + '|$)',
			'i'
		),
		FIREWALL_HINT: wordPattern(spec.firewallHints),
		ACTION_RE: wordPattern(spec.actionWords),
		DENY_ACTION: wordPattern(denyClass),
		DENY_ACTION_UNDERSCORE: new RegExp(
			'(?:^|[^A-Za-z0-9])(?:' + denyClass.join('|') + ')(?:[^A-Za-z0-9]|$)',
			'i'
		),
		NETFILTER_KV_GLUE: new RegExp(
			'([^\\s])(?=(' + spec.glueKeys.join('|') + ')=)',
			'g'
		)
	};
}

function assertRegexParity(label, actual, expected) {
	assert.strictEqual(actual.source, expected.source,
		label + ' regex source drifted from CLASSIFY_SPEC');
	assert.strictEqual(actual.flags, expected.flags,
		label + ' regex flags drifted from CLASSIFY_SPEC');
}

function extractClassifySpec(text) {
	let keyAt = text.indexOf('const CLASSIFY_SPEC');
	if (keyAt < 0)
		keyAt = text.indexOf('CLASSIFY_SPEC =');
	assert.ok(keyAt >= 0, 'CLASSIFY_SPEC key not found in LuCI wrapper');
	const start = text.indexOf('{', keyAt);
	assert.ok(start >= 0, 'CLASSIFY_SPEC object not found in LuCI wrapper');
	let depth = 0;
	let end = -1;
	for (let i = start; i < text.length; i++) {
		const c = text[i];
		if (c === '{')
			depth++;
		else if (c === '}') {
			depth--;
			if (depth === 0) {
				end = i + 1;
				break;
			}
		}
	}
	assert.ok(end > start, 'CLASSIFY_SPEC object not balanced in LuCI wrapper');
	return Function('"use strict"; return (' + text.slice(start, end) + ');')();
}

function loadLuciLogModule(text) {
	const body = text
		.replace(/^'use strict';\s*/m, '')
		.replace(/^'require [^']+';[^\n]*\n/gm, '');
	const baseclass = { extend: function(desc) { return desc; } };
	const fn = new Function('baseclass', body);
	return fn(baseclass);
}

const luciSpec = extractClassifySpec(src);
assert.deepEqual(core.CLASSIFY_SPEC, luciSpec,
	'LuCI wrapper CLASSIFY_SPEC drifted from core');

const expected = buildClassifyRegexes(core.CLASSIFY_SPEC);
const luci = loadLuciLogModule(src);
const regexNames = [
	'NON_FIREWALL_PREFIX',
	'FIREWALL_HINT',
	'ACTION_RE',
	'DENY_ACTION',
	'DENY_ACTION_UNDERSCORE',
	'NETFILTER_KV_GLUE'
];
for (let i = 0; i < regexNames.length; i++) {
	const name = regexNames[i];
	assert.ok(luci[name] instanceof RegExp,
		'LuCI wrapper missing spec-derived regex ' + name);
	assertRegexParity('LuCI ' + name, luci[name], expected[name]);
}

assertRegexParity('core NON_FIREWALL_PREFIX', core.NON_FIREWALL_PREFIX, expected.NON_FIREWALL_PREFIX);
assertRegexParity('core FIREWALL_HINT', core.FIREWALL_HINT, expected.FIREWALL_HINT);
assertRegexParity('core ACTION_RE', core.ACTION_RE, expected.ACTION_RE);
assertRegexParity('core DENY_ACTION', core.DENY_ACTION, expected.DENY_ACTION);
assertRegexParity('core DENY_ACTION_UNDERSCORE', core.DENY_ACTION_UNDERSCORE, expected.DENY_ACTION_UNDERSCORE);
assertRegexParity('core NETFILTER_KV_GLUE', core.NETFILTER_KV_GLUE, expected.NETFILTER_KV_GLUE);

process.stdout.write(src);
