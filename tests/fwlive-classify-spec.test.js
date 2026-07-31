#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const core = require('../core/fwlive-log.js');

const FIXTURES = [
	path.join(__dirname, 'fixtures', 'logread-mixed.json'),
	path.join(__dirname, 'fixtures', 'logread-iptables.json'),
];
/* Golden expectations: {msg, expect} — extend from the shell-parity `extra` list.
   Mixed-case daemon lines pin the /i prefix semantics (MCR A/C); empty-value KV lines
   pin the presence-based `kv` semantics, documenting the intentional flip: today
   JS=false, shell=true for "x DST= DROP" — after A3 both agree (MCR C3). */
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
	/* Presence semantics (empty values): unified outcome = shell's current TRUE. */
	{ msg: 'x DST= DROP', expect: true },
	{ msg: 'IN=wan OUT= SRC= DST=2001:db8::2 PROTO=TCP', expect: true },
];

function run() {
	/* Dual KV semantics: classify uses presence (empty OK); parseKeyValueLog needs non-empty. */
	const emptyKv = 'x DST= DROP';
	assert.equal(Object.prototype.hasOwnProperty.call(core.parseKeyValueLog(emptyKv), 'DST'), false,
		'parseKeyValueLog must omit empty DST=');
	assert.equal(core.kvHas(emptyKv, 'DST'), true,
		'kvHas must treat empty DST= as present');

	const partialEmpty = 'IN=wan OUT= SRC= DST=2001:db8::2 PROTO=TCP';
	const parsed = core.parseKeyValueLog(partialEmpty);
	assert.equal(parsed.IN, 'wan');
	assert.equal(Object.prototype.hasOwnProperty.call(parsed, 'SRC'), false,
		'parseKeyValueLog must omit empty SRC=');
	assert.equal(core.kvHas(partialEmpty, 'SRC'), true);

	/* Equivalence loop vs the CURRENT isFirewallEvent. Holds only because no fixture
	   line is daemon-prefixed AND carries firewall KV (the prefix guard lives in
	   isFirewallEvent, not in evaluateClassifySpec) — keep it that way. */
	for (const f of FIXTURES) {
		for (const e of JSON.parse(fs.readFileSync(f, 'utf8')).log) {
			const expect = core.isFirewallEvent(e);
			const got = core.evaluateClassifySpec(e.msg || '');
			assert.strictEqual(got, expect, 'corpus: ' + e.msg);
		}
	}
	/* The evaluator under test (golden expectations). actionRaw is intentionally
	   undefined so the evaluator computes it on the NORMALIZED message, matching the
	   production call site (raw detectAction misses glued prefixes like "fw4 DROPIN=…"). */
	for (const g of GOLDEN) {
		const got = core.evaluateClassifySpec(g.msg);
		assert.strictEqual(got, g.expect, JSON.stringify(g.msg));
	}
	console.log('fwlive classify spec golden corpus passed');
}

run();
