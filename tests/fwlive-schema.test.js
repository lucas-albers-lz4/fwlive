#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const core = require('../core/fwlive-log.js');

const SCHEMA_FIELDS = [
	'timestamp',
	'timestamp_display',
	'action',
	'action_raw',
	'rule_hint',
	'rule_label',
	'interface_in',
	'interface_out',
	'proto',
	'src',
	'sport',
	'dst',
	'dport',
	'flags',
	'length',
	'message'
];

function run() {
	const fixture = path.join(__dirname, 'fixtures', 'logread-mixed.json');
	const payload = JSON.parse(fs.readFileSync(fixture, 'utf8'));
	const rows = core.filterLogEntries(payload.log);

	for (const row of rows) {
		for (const field of SCHEMA_FIELDS)
			assert.ok(field in row, `missing field ${field}`);
		assert.equal(typeof row.timestamp, 'number');
		assert.match(row.action, /^(pass|block|drop|reject|unknown)$/);
	}

	const kernel = rows.find((r) => r.message.indexOf('kernel:') === 0);
	assert.ok(kernel);
	assert.equal(kernel.length, 60);
	assert.equal(kernel.flags, 'SYN');
	assert.equal(kernel.interface_in, 'eth0');
	assert.equal(kernel.action, 'unknown');

	const fw4 = rows.find((r) => r.message.indexOf('fw4: DROP') === 0);
	assert.ok(fw4);
	assert.equal(fw4.action, 'drop');
	assert.equal(fw4.interface_in, 'br-lan');
	assert.equal(fw4.interface_out, 'eth0');
	assert.equal(fw4.timestamp, 1717675742);

	assert.equal(core.normalizeAction('ACCEPT'), 'pass');
	assert.equal(core.normalizeAction('DENY'), 'block');
	assert.equal(core.normalizeAction('REJECT'), 'reject');
	assert.equal(core.normalizeAction('DROP'), 'drop');
	assert.equal(core.normalizeAction('UNKNOWN'), 'unknown');

	console.log('fwlive schema tests passed');
}

run();
