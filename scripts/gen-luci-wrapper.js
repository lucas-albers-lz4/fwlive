#!/usr/bin/env node
'use strict';

/**
 * LuCI wrapper gate for gen-all.sh: verifies preserve markers, CLASSIFY_SPEC surface,
 * and 21.02 API constraints; emits committed log.js bytes (idempotent).
 *
 * This is a gate, not a generator: shared classify logic in log.js is hand-maintained
 * and must stay deep-equal to core CLASSIFY_SPEC. Running gen-all.sh re-emits the
 * committed file only after checks pass.
 */

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');

const ROOT = path.join(__dirname, '..');
const LUCI = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js');
const core = require(path.join(ROOT, 'core', 'fwlive-log.js'));

const src = fs.readFileSync(LUCI, 'utf8');

assert.ok(src.indexOf('@fwlive-codegen:luci-preserve-begin') >= 0, 'missing luci-preserve-begin');
assert.ok(src.indexOf('@fwlive-codegen:luci-preserve-end') >= 0, 'missing luci-preserve-end');
assert.ok(src.indexOf('CLASSIFY_SPEC') >= 0, 'missing CLASSIFY_SPEC');
assert.ok(src.indexOf('evaluateClassifySpec') >= 0, 'missing evaluateClassifySpec');
assert.ok(src.indexOf('gen-all.sh') >= 0, 'missing gen-all.sh banner');
assert.ok(src.indexOf('.includes(') < 0 && src.indexOf('Object.values') < 0,
	'LuCI wrapper must stay 21.02-compatible');

function extractClassifySpec(text) {
	const key = 'CLASSIFY_SPEC:';
	const keyAt = text.indexOf(key);
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

const luciSpec = extractClassifySpec(src);
assert.deepEqual(core.CLASSIFY_SPEC, luciSpec,
	'LuCI wrapper CLASSIFY_SPEC drifted from core');

process.stdout.write(src);
