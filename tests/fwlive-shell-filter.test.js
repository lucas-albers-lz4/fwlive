#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { execFileSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const core = require('../core/fwlive-log.js');

const ROOT = path.join(__dirname, '..');
const IS_FW = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.sh');
const FILTER_SH = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-log-filter.sh');
const FIXTURE = path.join(__dirname, 'fixtures', 'logread-mixed.json');
/* Override with SH=busybox or SH='busybox sh' for ash parity (#103). */
const SH = process.env.SH || 'sh';

function shSpawn(scriptOrFile, opts) {
	const parts = SH.split(/\s+/).filter(Boolean);
	const cmd = parts[0];
	const prefix = parts.slice(1);
	if (opts && opts.argvFile) {
		return spawnSync(cmd, prefix.concat([opts.argvFile]), {
			input: opts.input,
			encoding: opts.encoding || 'utf8'
		});
	}
	return execFileSync(cmd, prefix.concat(['-c', scriptOrFile]), {
		encoding: 'utf8',
		env: opts && opts.env ? opts.env : process.env
	});
}

function shellIsFirewall(msg) {
	const out = shSpawn(
		'. "$IS_FW" && is_firewall_event_msg "$FW_MSG" && echo yes || echo no',
		{ env: { ...process.env, IS_FW: IS_FW, FW_MSG: msg } }
	).trim();
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
		{ msg: '   ' },
		/* #58 edge cases — keep shell/JS parity honest across engines */
		{ msg: 'IN=wan OUT= SRC=2001:db8::1 DST=2001:db8::2 PROTO=TCP SPT=1234 DPT=443' },
		{ msg: '\tIN=wan OUT= SRC=203.0.113.9 DST=192.0.2.9 PROTO=UDP SPT=53 DPT=53\n' },
		{ msg: 'kernel: IN=wan OUT= SRC=203.0.113.10 DST=192.0.2.10 PROTO=ICMP' },
		{ msg: 'fw4rejectIN=wan OUT= SRC=203.0.113.11 DST=192.0.2.11 PROTO=TCP DPT=22' },
		{ msg: 'IN=wan OUT= SRC=203.0.113.12 DST=192.0.2.12 PROTO=TCP MAC=aa:bb:cc:dd:ee:ff PASS=noise' },
		{ msg: 'not-a-firewall-line at all' },
		{ msg: 'Dnsmasq[123]: query[A] example.com from 192.168.1.1' },
		{ msg: 'PROCD[1]: service did something' },
		/* #100 — prefix boundary: word-suffix must not match non-firewall daemon glob */
		{ msg: 'dnsmasqfoo: IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP' },
		{ msg: 'x DST= DROP' },
		{ msg: 'IN=wan OUT= SRC= DST=2001:db8::2 PROTO=TCP' }
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

	const filtered = shSpawn(null, { argvFile: FILTER_SH, input: payload, encoding: 'utf8' });
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
	const filtered = shSpawn(null, { argvFile: FILTER_SH, input: payload, encoding: 'utf8' });
	assert.equal(filtered.status, 0, filtered.stderr || filtered.stdout);
	assert.doesNotThrow(() => JSON.parse(filtered.stdout));
}

function runMissingJsonfilter() {
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-no-jf-'));
	try {
		fs.writeFileSync(path.join(stubDir, 'logger'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
		const r = spawnSync('/bin/sh', [FILTER_SH], {
			input: '{"log":[{"msg":"IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP"}]}',
			encoding: 'utf8',
			env: { ...process.env, PATH: stubDir }
		});
		assert.notEqual(r.status, 0, 'missing jsonfilter must exit non-zero');
		const j = JSON.parse(r.stdout);
		assert.equal(j.error, 'jsonfilter_missing');
		assert.deepEqual(j.log, []);
	} finally {
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function run() {
	runMsgParity();
	runJsonParity();
	runMetacharSafety();
	runMissingJsonfilter();
	console.log('fwlive shell filter parity tests passed (SH=' + SH + ')');
}

run();
