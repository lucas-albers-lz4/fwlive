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
	assert.equal(row.timestamp, Math.floor(new Date(sample.time).getTime() / 1000));
	assert.equal(row.timestamp_display, '2026-03-20T02:00:00.000Z');
	assert.equal(row.action, 'drop');
	assert.equal(row.action_raw, 'DROP');
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
	assert.equal(weak.action, 'pass');
	assert.equal(weak.action_raw, 'ACCEPT');

	// Real nft log prefix glued to IN= (QEMU / kernel nf_log).
	const nftPing = {
		time: 1780797240,
		msg: '[  239.247521] fwlive-pingIN=lo OUT= MAC=00:00:00:00:00:00:00:00:00:00:00:00:08:00 SRC=127.0.0.1 DST=127.0.0.1 LEN=84 TOS=0x00 PREC=0x00 TTL=64 ID=6376 DF PROTO=ICMP TYPE=8 CODE=0 ID=3139 SEQ=2'
	};
	assert.equal(core.isFirewallEvent(nftPing), true);
	const pingRow = core.normalizeEntry(nftPing);
	assert.equal(pingRow.interface_in, 'lo');
	assert.equal(pingRow.interface_out, '');
	assert.equal(pingRow.direction, 'in');
	assert.equal(pingRow.proto, 'ICMP');
	assert.equal(pingRow.src, '127.0.0.1');
	assert.equal(pingRow.dst, '127.0.0.1');
	assert.equal(pingRow.length, 84);
	assert.equal(pingRow.action, 'pass');
	assert.equal(pingRow.action_raw, 'PASS');
	assert.equal(pingRow.rule_hint, 'fwlive-ping');
	assert.equal(pingRow.rule_label, 'fwlive ping');

	const fw4Drop = core.normalizeEntry({
		time: 1717675742,
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.168.1.150 DST=8.8.8.8 PROTO=TCP'
	});
	assert.equal(fw4Drop.rule_hint, 'fw4');

	const fwliveTest = core.normalizeEntry({
		time: 1717675740,
		msg: 'fwlive-test: ACCEPT IN=br-lan SRC=192.168.1.10 DST=192.168.1.1 PROTO=UDP'
	});
	assert.equal(fwliveTest.rule_hint, 'fwlive-test');

	// Ambiguous kernel line without explicit verdict stays unknown.
	const kernelOnly = {
		time: 1717675740,
		msg: 'kernel: IN=eth0 OUT= MAC=aa SRC=10.0.0.2 DST=1.1.1.1 LEN=60 PROTO=TCP'
	};
	const kernelRow = core.normalizeEntry(kernelOnly);
	assert.equal(kernelRow.action, 'unknown');

	console.log('fwlive parser/filter tests passed');
}

run();
