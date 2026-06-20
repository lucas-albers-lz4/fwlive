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
	assert.ok(actions.includes('drop'));
	assert.ok(actions.includes('pass'));

	const msgs = rows.map((r) => r.message).join('\n');
	assert.ok(!msgs.includes('dnsmasq'));
	assert.ok(!msgs.includes('procd'));
	assert.ok(!msgs.includes('netifd'));

	const filtered = rows.filter((r) => core.matchesFilter(r, { src: '192.168.1.150' }));
	assert.equal(filtered.length, 1);
	assert.equal(filtered[0].dport, '443');
	assert.equal(filtered[0].action, 'drop');

	const byNorm = rows.filter((r) => core.matchesFilter(r, { action: 'drop' }));
	assert.ok(byNorm.length >= 1);

	// AND: multiple active filters must all match.
	const andTcp = rows.filter((r) => core.matchesFilter(r, {
		proto: 'TCP',
		action: 'drop',
		src: '192.168.1.150'
	}));
	assert.equal(andTcp.length, 1);
	assert.equal(andTcp[0].dport, '443');

	const andMiss = rows.filter((r) => core.matchesFilter(r, {
		proto: 'TCP',
		src: '192.168.1.150',
		dport: '22'
	}));
	assert.equal(andMiss.length, 0);

	const notDrop = rows.filter((r) => core.matchesFilter(r, { action: '!drop' }));
	assert.ok(notDrop.length >= 1);
	assert.ok(notDrop.every((r) => r.action !== 'drop'));

	const notSrc = rows.filter((r) => core.matchesFilter(r, { src: '!192.168.1.150' }));
	assert.ok(notSrc.every((r) => !r.src.includes('192.168.1.150')));

	const notProto = rows.filter((r) => core.matchesFilter(r, { proto: '!TCP' }));
	assert.ok(notProto.every((r) => r.proto !== 'TCP'));

	const iptFixture = path.join(__dirname, 'fixtures', 'logread-iptables.json');
	const iptPayload = JSON.parse(fs.readFileSync(iptFixture, 'utf8'));
	const iptStats = core.statsLogEntries(iptPayload.log);
	assert.equal(iptStats.firewall, 4);
	assert.equal(iptStats.noise, 1);
	const iptRows = core.filterLogEntries(iptPayload.log);
	assert.equal(iptRows.length, 4);
	assert.ok(iptRows.some((r) => r.rule_hint === 'fwlive-ping'));
	assert.ok(iptRows.some((r) => r.action === 'drop' && r.interface_in === 'wan'));

	console.log('fwlive firewall filter tests passed');
}

run();
