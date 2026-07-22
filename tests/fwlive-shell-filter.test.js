#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const core = require('../core/fwlive-log.js');

const ROOT = path.join(__dirname, '..');
const IS_FW = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.sh');
const FILTER_SH = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-log-filter.sh');
const FIXTURE = path.join(__dirname, 'fixtures', 'logread-mixed.json');

function shellIsFirewall(msg) {
	const out = execFileSync('sh', ['-c', '. "$IS_FW" && is_firewall_event_msg "$FW_MSG" && echo yes || echo no'], {
		encoding: 'utf8',
		env: { ...process.env, IS_FW: IS_FW, FW_MSG: msg }
	}).trim();
	return out === 'yes';
}

function runMsgParity() {
	const fixture = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
	const extra = [
		{ msg: 'fw4: ACCEPT without key values' },
		{ msg: '[  239.247521] fwlive-pingIN=lo OUT= SRC=127.0.0.1 DST=127.0.0.1 PROTO=ICMP' },
		{ msg: '[  123.456789] fwlive-ping: IN=br-lan OUT= SRC=192.168.1.10 DST=192.168.1.1 PROTO=ICMP' },
		{ msg: 'iptables: DROP IN=wan OUT= SRC=203.0.113.5 DST=192.168.1.1 PROTO=TCP DPT=22' },
		{ msg: '' },
		{ msg: '   ' }
	];

	for (const entry of fixture.log.concat(extra)) {
		const js = core.isFirewallEvent(entry);
		const sh = shellIsFirewall(entry.msg || '');
		assert.equal(sh, js, `parity mismatch for: ${JSON.stringify(entry.msg)}`);
	}
}

function runJsonParity() {
	if (!fs.existsSync(FILTER_SH))
		throw new Error('missing fwlive-log-filter.sh');

	const payload = fs.readFileSync(FIXTURE, 'utf8');
	const jf = spawnSync('sh', ['-c', 'command -v jsonfilter'], { encoding: 'utf8' });
	if (jf.status !== 0 || !jf.stdout.trim()) {
		console.log('fwlive shell filter: skip JSON round-trip (jsonfilter not on host)');
		return;
	}

	const filtered = spawnSync('sh', [FILTER_SH], {
		input: payload,
		encoding: 'utf8'
	});
	assert.equal(filtered.status, 0, filtered.stderr || filtered.stdout);

	const shellOut = JSON.parse(filtered.stdout);
	const jsMsgs = JSON.parse(payload).log
		.filter((e) => core.isFirewallEvent(e))
		.map((e) => e.msg)
		.sort();
	const shMsgs = (shellOut.log || []).map((e) => e.msg).sort();

	assert.deepEqual(shMsgs, jsMsgs);
}

function runMetacharSafety() {
	const nasty = [
		'$(reboot); IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP SPT=1 DPT=2',
		'`id` IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=UDP SPT=1 DPT=53',
		'IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP; rm -rf /',
		'IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP $(echo pwned)',
		'dropbear[1]: Bad packet length 12345'
	];

	for (const msg of nasty) {
		assert.doesNotThrow(() => shellIsFirewall(msg));
	}

	if (!fs.existsSync(FILTER_SH))
		throw new Error('missing fwlive-log-filter.sh');

	const jf = spawnSync('sh', ['-c', 'command -v jsonfilter'], { encoding: 'utf8' });
	if (jf.status !== 0 || !jf.stdout.trim()) {
		console.log('fwlive shell filter: skip metachar JSON round-trip (jsonfilter not on host)');
		return;
	}

	const payload = JSON.stringify({
		log: nasty.map((msg, i) => ({ msg, id: i }))
	});
	const filtered = spawnSync('sh', [FILTER_SH], {
		input: payload,
		encoding: 'utf8'
	});
	assert.equal(filtered.status, 0, filtered.stderr || filtered.stdout);
	assert.doesNotThrow(() => JSON.parse(filtered.stdout));
}

function run() {
	runMsgParity();
	runJsonParity();
	runMetacharSafety();
	console.log('fwlive shell filter parity tests passed');
}

run();
