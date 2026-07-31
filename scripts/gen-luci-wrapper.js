#!/usr/bin/env node
'use strict';

/**
 * LuCI wrapper gate for gen-all.sh: verifies preserve markers, CLASSIFY_SPEC surface,
 * and 21.02 API constraints; emits committed log.js bytes (idempotent).
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

assert.deepEqual(
	core.CLASSIFY_SPEC.actionWords,
	['ACCEPT', 'ALLOW', 'PASS', 'DROP', 'REJECT', 'DENY', 'BLOCK']
);

process.stdout.write(src);
