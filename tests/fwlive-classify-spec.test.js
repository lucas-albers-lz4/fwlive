#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const core = require('../core/fwlive-log.js');

const FIXTURE_DIR = path.join(__dirname, 'fixtures');
const FIXTURES = [ 'logread-mixed.json', 'logread-iptables.json' ];

/*
 * Independent oracle for the mixed + iptables corpora. Literal expect, not
 * isFirewallEvent — that wrapper delegates to evaluateClassifySpec, so a
 * self-comparison cannot catch a CLASSIFY_SPEC rule regression.
 */
const CORPUS = [
	{
		fixture: 'logread-mixed.json', i: 0, expect: false,
		msg: 'dnsmasq[1]: started, version 2.92 cachesize 1000'
	},
	{
		fixture: 'logread-mixed.json', i: 1, expect: false,
		msg: 'procd: Instance sysntpd::instance1 s in a crash loop 6 crashes, 0 seconds since last crash'
	},
	{
		fixture: 'logread-mixed.json', i: 2, expect: true,
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.168.1.150 DST=8.8.8.8 PROTO=TCP SPT=49210 DPT=443'
	},
	{
		fixture: 'logread-mixed.json', i: 3, expect: true,
		msg: 'kernel: IN=eth0 OUT= MAC=... SRC=10.0.0.2 DST=1.1.1.1 LEN=60 PROTO=TCP SPT=49999 DPT=443 SYN'
	},
	{
		fixture: 'logread-mixed.json', i: 4, expect: true,
		msg: 'fwlive-test: ACCEPT IN=br-lan SRC=192.168.1.10 DST=192.168.1.1 PROTO=UDP SPT=5353 DPT=5353'
	},
	{
		fixture: 'logread-mixed.json', i: 5, expect: false,
		msg: "netifd: Network device 'eth0' link is up"
	},
	{
		fixture: 'logread-mixed.json', i: 6, expect: true,
		msg: 'nft: drop IN=wan OUT= SRC=203.0.113.5 DST=192.168.1.1 PROTO=TCP DPT=22'
	},
	{
		fixture: 'logread-mixed.json', i: 7, expect: true,
		msg: 'kernel: IN=eth0 OUT= MAC=... SRC=10.0.0.2 DST=1.1.1.1 LEN=60 PROTO=TCP SPT=49999 DPT=443 WINDOW=65535 RES=0x00 SYN URGP=0'
	},
	{
		fixture: 'logread-iptables.json', i: 0, expect: true,
		msg: '[  123.456789] fwlive-ping: IN=br-lan OUT= MAC=00:11:22:33:44:55:66:77 SRC=192.168.1.10 DST=192.168.1.1 LEN=84 PROTO=ICMP TYPE=8 CODE=0'
	},
	{
		fixture: 'logread-iptables.json', i: 1, expect: true,
		msg: 'iptables: DROP IN=wan OUT= SRC=203.0.113.5 DST=192.168.1.1 PROTO=TCP SPT=54321 DPT=22'
	},
	{
		fixture: 'logread-iptables.json', i: 2, expect: true,
		msg: 'custom-chain: ACCEPT IN=lan OUT= SRC=10.0.0.5 DST=8.8.8.8 PROTO=UDP SPT=5353 DPT=5353'
	},
	{
		fixture: 'logread-iptables.json', i: 3, expect: true,
		msg: 'fwlive-testIN=eth0 OUT= SRC=192.168.1.20 DST=1.1.1.1 PROTO=ICMP'
	},
	{
		fixture: 'logread-iptables.json', i: 4, expect: false,
		msg: 'dnsmasq[1]: query[A] example.com from 192.168.1.5'
	},
	{
		fixture: 'logread-iptables.json', i: 5, expect: true,
		msg: '[   42.147422] fwlive-custom: IN=lo OUT= MAC=00:00:00:00:00:00:00:00:00:00:00:00:08:00 SRC=127.0.0.1 DST=127.0.0.1 LEN=84 TOS=0x00 PREC=0x00 TTL=64 ID=340 DF PROTO=ICMP TYPE=8 CODE=0 ID=5365 SEQ=0'
	},
	{
		fixture: 'logread-iptables.json', i: 6, expect: true,
		msg: 'DROPIN=wan SRC=203.0.113.5 DST=192.168.1.1 PROTO=TCP DPT=22'
	},
	{
		fixture: 'logread-iptables.json', i: 7, expect: true,
		msg: 'REJECTIN=lan SRC=192.168.1.1 DST=203.0.113.5 PROTO=TCP DPT=22'
	},
	{
		fixture: 'logread-iptables.json', i: 8, expect: true,
		msg: 'reject_from_wan IN=eth0 SRC=203.0.113.5 DST=192.168.1.1 PROTO=TCP DPT=22'
	}
];

function loadFixture(name) {
	return JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, name), 'utf8'));
}

function corpusFor(name) {
	return CORPUS.filter((row) => row.fixture === name);
}

/* Golden expectations: presence-based kv (empty values count); mixed-case daemons. */
const GOLDEN = [
	{ msg: '', expect: false },
	{ msg: '   ', expect: false },
	{ msg: 'dnsmasq[123]: query[A] google.com from 192.168.1.1', expect: false },
	{ msg: 'Dnsmasq[123]: query[A] example.com from 192.168.1.1', expect: false },
	{ msg: 'PROCD[1]: service did something', expect: false },
	{ msg: 'dropbear[1]: Bad packet length 12345', expect: false },
	{ msg: '[  239.247521] fwlive-pingIN=lo OUT= SRC=127.0.0.1 DST=127.0.0.1 PROTO=ICMP', expect: true },
	{ msg: 'IN=wan OUT= SRC=2001:db8::1 DST=2001:db8::2 PROTO=TCP SPT=1234 DPT=443', expect: true },
	{ msg: 'not-a-firewall-line at all', expect: false },
	{ msg: 'wpad-drop IN=wlan0 SRC=203.0.113.5 DST=192.0.2.1 PROTO=TCP DROP', expect: true },
	{ msg: 'hostapd-filter IN=wlan0 SRC=203.0.113.5 DST=192.0.2.1 PROTO=TCP DROP', expect: true },
	/* Presence semantics (empty values): unified outcome = shell's TRUE. */
	{ msg: 'x DST= DROP', expect: true },
	{ msg: 'IN=wan OUT= SRC= DST=2001:db8::2 PROTO=TCP', expect: true },
	{ msg: 'IN= OUT= SRC= DST= PROTO=', expect: true },
	/* #499 — trim must not drop real firewall lines */
	{ msg: ' IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP', expect: true }
];

function run() {
	for (const name of FIXTURES) {
		const log = loadFixture(name).log;
		const rows = corpusFor(name);
		assert.equal(log.length, rows.length,
			'corpus must cover every ' + name + ' row');
		for (let i = 0; i < rows.length; i++) {
			const row = rows[i];
			const e = log[i];
			const label = name + '[' + i + ']';
			assert.equal(row.i, i, 'corpus index order ' + name);
			assert.equal(e.msg, row.msg, 'fixture drift ' + label);
			assert.strictEqual(core.evaluateClassifySpec(e.msg || ''), row.expect,
				'corpus classify: ' + e.msg);
			assert.strictEqual(core.isFirewallEvent(e), row.expect,
				'corpus isFirewallEvent: ' + e.msg);
		}
	}

	for (const g of GOLDEN) {
		const got = core.evaluateClassifySpec(g.msg);
		assert.strictEqual(got, g.expect, JSON.stringify(g.msg));
		assert.strictEqual(core.isFirewallEvent({ msg: g.msg }), g.expect,
			'isFirewallEvent: ' + JSON.stringify(g.msg));
	}

	assert.strictEqual(
		core.isFirewallEvent({ msg: 'wpad[1]: filter IN=wlan0 SRC=203.0.113.5 DST=192.0.2.1 PROTO=TCP DROP' }),
		false,
		'syslog-tagged wpad line must remain non-firewall'
	);

	/* #499 — trim before non-firewall prefix guard (shell parity) */
	for (const msg of [
		'  dnsmasq[1]: IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP',
		' wpad[1]: IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP DROP'
	]) {
		assert.strictEqual(core.isFirewallEvent({ msg }), false,
			'leading-whitespace daemon line: ' + JSON.stringify(msg));
	}

	console.log('fwlive classify spec golden corpus passed');
}

run();
