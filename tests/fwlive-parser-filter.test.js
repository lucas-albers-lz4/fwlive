#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const core = require('../core/fwlive-log.js');

function run() {
	const sample = {
		time: '2026-03-20T02:00:00.000Z',
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=10.0.0.2 DST=1.1.1.1 PROTO=TCP SPT=49999 DPT=443'
	};
	const row = core.normalizeEntry(sample);
	assert.equal(row.timestamp, '2026-03-20T02:00:00.000Z');
	assert.equal(row.proto, 'TCP');
	assert.equal(row.src, '10.0.0.2');
	assert.equal(row.dst, '1.1.1.1');
	assert.equal(row.sport, '49999');
	assert.equal(row.dport, '443');
	assert.equal(row.interface_in, 'br-lan');
	assert.equal(row.interface_out, 'eth0');

	assert.equal(core.isFirewallEvent(sample), true);
	assert.equal(core.isFirewallEvent({ msg: 'dnsmasq[1]: started' }), false);
	assert.equal(core.isFirewallEvent({ msg: 'fw4: ACCEPT without key values' }), true);

	const weak = core.normalizeEntry({ msg: 'fw4: ACCEPT without key values' });
	assert.equal(weak.action, 'ACCEPT');

	console.log('fwlive parser/filter tests passed');
}

run();
