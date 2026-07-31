#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const core = require('../core/fwlive-log.js');

const FIXTURES = [
	path.join(__dirname, 'fixtures', 'logread-mixed.json'),
	path.join(__dirname, 'fixtures', 'logread-iptables.json')
];

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
	/* Presence semantics (empty values): unified outcome = shell's TRUE. */
	{ msg: 'x DST= DROP', expect: true },
	{ msg: 'IN=wan OUT= SRC= DST=2001:db8::2 PROTO=TCP', expect: true },
	{ msg: 'IN= OUT= SRC= DST= PROTO=', expect: true }
];

function run() {
	for (const f of FIXTURES) {
		for (const e of JSON.parse(fs.readFileSync(f, 'utf8')).log) {
			const expect = core.isFirewallEvent(e);
			const got = core.evaluateClassifySpec(e.msg || '');
			assert.strictEqual(got, expect, 'corpus: ' + e.msg);
		}
	}

	for (const g of GOLDEN) {
		const got = core.evaluateClassifySpec(g.msg);
		assert.strictEqual(got, g.expect, JSON.stringify(g.msg));
		assert.strictEqual(core.isFirewallEvent({ msg: g.msg }), g.expect,
			'isFirewallEvent: ' + JSON.stringify(g.msg));
	}

	console.log('fwlive classify spec golden corpus passed');
}

run();
