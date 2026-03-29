#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');

function parseKeyValueLog(message) {
	const out = {};
	const re = /\b([A-Z]+)=([^\s]+)/g;
	let match;

	while ((match = re.exec(message)) !== null)
		out[match[1]] = match[2];

	return out;
}

function normalizeEntry(entry) {
	const kv = parseKeyValueLog(entry.msg || '');
	const ts = entry.time ? new Date(entry.time).toISOString() : '';
	const proto = (kv.PROTO || '').toUpperCase();
	const src = kv.SRC || '';
	const dst = kv.DST || '';
	const sport = kv.SPT || '';
	const dport = kv.DPT || '';
	return { timestamp: ts, proto, src, dst, sport, dport };
}

function run() {
	const sample = {
		time: '2026-03-20T02:00:00.000Z',
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=10.0.0.2 DST=1.1.1.1 PROTO=TCP SPT=49999 DPT=443'
	};
	const row = normalizeEntry(sample);
	assert.equal(row.timestamp, '2026-03-20T02:00:00.000Z');
	assert.equal(row.proto, 'TCP');
	assert.equal(row.src, '10.0.0.2');
	assert.equal(row.dst, '1.1.1.1');
	assert.equal(row.sport, '49999');
	assert.equal(row.dport, '443');

	const missing = normalizeEntry({ msg: 'fw4: ACCEPT without key values' });
	assert.equal(missing.proto, '');
	assert.equal(missing.src, '');

	console.log('fwlive parser/filter tests passed');
}

run();
