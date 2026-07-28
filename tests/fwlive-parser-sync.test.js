#!/usr/bin/env node
'use strict';

/**
 * Guard: Node parser (core/fwlive-log.js) and LuCI mirror (fwlive/log.js) stay aligned.
 * Bump PARSER_SYNC_VERSION in both files when you intentionally change parser logic.
 * Also asserts shared presentation helpers (actionRowClass) match behaviorally.
 */

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { loadFwliveModule } = require('./lib/load-fwlive-module');

const ROOT = path.join(__dirname, '..');
const CORE = path.join(ROOT, 'core/fwlive-log.js');
const LUCI = path.join(
	ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js'
);

const SYNC_RE = /PARSER_SYNC_VERSION:\s*(\d+)/;

function readVersion(file) {
	const text = fs.readFileSync(file, 'utf8');
	const m = text.match(SYNC_RE);
	if (!m)
		throw new Error(`missing PARSER_SYNC_VERSION in ${file}`);
	return m[1];
}

const coreV = readVersion(CORE);
const luciV = readVersion(LUCI);

if (coreV !== luciV) {
	console.error(`parser sync mismatch: core=${coreV} luci=${luciV}`);
	process.exit(1);
}

const core = require(CORE);
const luci = loadFwliveModule('log');

const samples = [ 'pass', 'drop', 'reject', 'block', 'accept', '', null, 'PASS' ];
for (let i = 0; i < samples.length; i++) {
	const a = samples[i];
	assert.strictEqual(
		core.actionRowClass(a),
		luci.actionRowClass(a),
		'actionRowClass mismatch for ' + JSON.stringify(a)
	);
}

assert.strictEqual(core.actionRowClass('pass'), 'fwlive-action fwlive-pass');
assert.strictEqual(core.actionRowClass('drop'), 'fwlive-action fwlive-deny');
assert.strictEqual(core.actionRowClass('weird'), 'fwlive-action fwlive-unknown');

/* 21.02-era APIs: no String.includes / Object.values in either mirror. */
const coreSrc = fs.readFileSync(CORE, 'utf8');
const luciSrc = fs.readFileSync(LUCI, 'utf8');
assert.ok(coreSrc.indexOf('.includes(') < 0, 'core still uses String.includes');
assert.ok(luciSrc.indexOf('.includes(') < 0, 'LuCI still uses String.includes');
assert.ok(coreSrc.indexOf('Object.values') < 0, 'core still uses Object.values');
assert.ok(luciSrc.indexOf('Object.values') < 0, 'LuCI still uses Object.values');

console.log(`fwlive parser sync OK (version ${coreV})`);
