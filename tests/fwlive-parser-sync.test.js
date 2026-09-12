#!/usr/bin/env node
'use strict';

/**
 * Guard: Node parser (core/fwlive-log.js) and LuCI mirror (fwlive/log.js) stay aligned.
 */

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { loadFwliveModule } = require('./lib/load-fwlive-module');

const ROOT = path.join(__dirname, '..');
const CORE = path.join(ROOT, 'core/fwlive-log.js');
const LUCI = path.join(
	ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js'
);

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

const spaceTs = { time: '2024-01-01 12:00:00' };
assert.strictEqual(core.timestampUnix(spaceTs), luci.timestampUnix(spaceTs));
assert.strictEqual(
	core.timestampUnix({ time: '2024-01-01T12:00:00Z' }),
	luci.timestampUnix({ time: '2024-01-01T12:00:00Z' })
);

const kvPass = core.parseKeyValueLog('IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP MAC=aa:bb PASS=noise');
assert.strictEqual(
	core.inferActionRaw('IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP MAC=aa:bb PASS=noise', kvPass, 'UNKNOWN'),
	'PASS'
);
assert.strictEqual(
	luci.inferActionRaw('IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP MAC=aa:bb PASS=noise', kvPass, 'UNKNOWN'),
	'PASS'
);

const classifyMsgs = [
	'',
	'dnsmasq[123]: query',
	'Dnsmasq[1]: x',
	'x DST= DROP',
	'IN=wan OUT= SRC= DST=2001:db8::2 PROTO=TCP',
	'[  239.247521] fwlive-pingIN=lo OUT= SRC=127.0.0.1 DST=127.0.0.1 PROTO=ICMP',
	'not-a-firewall-line at all'
];
for (let i = 0; i < classifyMsgs.length; i++) {
	const msg = classifyMsgs[i];
	const entry = { msg: msg };
	assert.strictEqual(
		core.isFirewallEvent(entry),
		luci.isFirewallEvent(entry),
		'isFirewallEvent mismatch: ' + JSON.stringify(msg)
	);
}

const coreSrc = fs.readFileSync(CORE, 'utf8');
const luciSrc = fs.readFileSync(LUCI, 'utf8');
assert.ok(coreSrc.indexOf('.includes(') < 0, 'core still uses String.includes');
assert.ok(luciSrc.indexOf('.includes(') < 0, 'LuCI still uses String.includes');
assert.ok(coreSrc.indexOf('Object.values') < 0, 'core still uses Object.values');
assert.ok(luciSrc.indexOf('Object.values') < 0, 'LuCI still uses Object.values');
assert.ok(luciSrc.indexOf('@fwlive-codegen:luci-preserve-begin') >= 0, 'missing luci-preserve region');

console.log('fwlive parser sync OK (classify + presentation)');

const syncSamples = [
	{ time: '2026-03-20T02:00:00.000Z', msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=10.0.0.2 DST=1.1.1.1 PROTO=TCP SPT=49999 DPT=443' },
	{ time: '2026-03-20T02:00:00.000Z', msg: 'fw4: ACCEPT IN=lo OUT= SRC=127.0.0.1 DST=127.0.0.1 PROTO=ICMP' },
	{ time: '2026-03-20T02:00:00.000Z', msg: 'fw4: ACCEPT without key values' }
];
const syncFilters = [
	{},
	{ q: '10.0.0.2' },
	{ q: '!10.0.0.2' },
	{ action: 'drop' },
	{ action: '!drop' },
	{ interface: 'br-lan' },
	{ interface: 'eth0' },
	{ proto: 'TCP' },
	{ src: '10.0.0.2', dst: '!1.1.1.1' }
];
// Expected outcomes: [sample][filterIndex] — correctness, not just parity.
const syncExpected = [
	[true, true, false, true, false, true, true, true, false],
	[true, false, true, false, true, false, false, false, false],
	[true, false, true, false, true, false, false, false, false]
];
for (let i = 0; i < syncSamples.length; i++) {
	const coreRow = core.normalizeEntry(syncSamples[i]);
	const luciRow = luci.normalizeEntry(syncSamples[i]);
	assert.deepStrictEqual(luciRow, coreRow,
		'normalizeEntry mismatch for ' + JSON.stringify(syncSamples[i].msg));
	for (let j = 0; j < syncFilters.length; j++) {
		assert.strictEqual(
			core.matchesFilter(coreRow, syncFilters[j]),
			syncExpected[i][j],
			'unexpected filter result for sample ' + i + ' filter ' + JSON.stringify(syncFilters[j])
		);
		assert.strictEqual(
			luci.matchesFilter(luciRow, syncFilters[j]),
			core.matchesFilter(coreRow, syncFilters[j]),
			'matchesFilter mismatch for filter ' + JSON.stringify(syncFilters[j])
		);
	}
}

console.log('fwlive parser sync OK (normalize + filter)');
