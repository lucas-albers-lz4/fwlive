#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const core = require('../core/fwlive-log.js');

function run() {
	const fixture = path.join(__dirname, 'fixtures', 'logread-mixed.json');
	const payload = JSON.parse(fs.readFileSync(fixture, 'utf8'));

	const stats = core.statsLogEntries(payload.log);
	assert.equal(stats.total, 7);
	assert.equal(stats.noise, 3);
	assert.equal(stats.firewall, 4);

	const rows = core.filterLogEntries(payload.log);
	assert.equal(rows.length, 4);

	const actions = rows.map((r) => r.action);
	assert.ok(actions.includes('DROP'));
	assert.ok(actions.includes('ACCEPT'));

	const msgs = rows.map((r) => r.message).join('\n');
	assert.ok(!msgs.includes('dnsmasq'));
	assert.ok(!msgs.includes('procd'));
	assert.ok(!msgs.includes('netifd'));

	const filtered = rows.filter((r) => core.matchesFilter(r, { src: '192.168.1.150' }));
	assert.equal(filtered.length, 1);
	assert.equal(filtered[0].dport, '443');

	console.log('fwlive firewall filter tests passed');
}

run();
