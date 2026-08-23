#!/usr/bin/env node
'use strict';
/**
 * F4 malformed-input no-crash corpus for normalize/strip/classify (#200).
 * Invoked by scripts/z3-verify.py (--fast / --full).
 */
const assert = require('node:assert/strict');
const core = require('../core/fwlive-log.js');

const FAST_CORPUS = [
	'',
	'   ',
	'\t\n',
	'$(reboot)',
	'`id`',
	'fwlive-pingIN=lo',
	'IN=wan OUT= SRC= DST= PROTO=TCP',
	'x DST= DROP',
	'dnsmasqfoo: IN=wan',
	'not-a-firewall-line',
	'fw4: ACCEPT without key values',
	'IN=wan OUT= SRC=2001:db8::1 DST=2001:db8::2 PROTO=TCP',
	'kernel: IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=ICMP',
	'abcdefghijklmnopqrstuvwxyz0123456789',
	'DROP DROP DROP',
	'\\x00not quite null',
];

const FULL_EXTRA = [
	'log prefix "My \\" Rule"',
	'log prefix ""',
	'comment "a:b:c"',
	'--log-prefix "x" --comment "y"',
	'IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP; rm -rf /',
	'IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP $(echo pwned)',
	'fw4rejectIN=wan OUT= SRC=203.0.113.11 DST=192.0.2.11 PROTO=TCP DPT=22',
	'IN=wan OUT= SRC= DST=2001:db8::2 PROTO=TCP',
	' '.repeat(200),
	'IN=' + 'A'.repeat(120),
	'SYN ACK FIN RST PSH URG SYN ACK',
	'dead.beef.cafe.baad',
	'192.0.2.1\nextra',
	'aCcEpT IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP',
	'DrOp IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP DPT=22',
];

function exercise(msg) {
	const normalized = core.normalizeNetfilterMessage(msg);
	assert.equal(typeof normalized, 'string');
	const kv = core.parseKeyValueLog(msg);
	assert.equal(typeof kv, 'object');
	const action = core.detectAction(msg);
	assert.equal(typeof action, 'string');
	const fw = core.isFirewallEvent({ msg });
	assert.equal(typeof fw, 'boolean');
	core.evaluateClassifySpec(msg);
}

const mode = process.argv.includes('--full') ? 'full' : 'fast';
const corpus = mode === 'full' ? FAST_CORPUS.concat(FULL_EXTRA) : FAST_CORPUS;

for (const msg of corpus) {
	exercise(msg);
}

console.log(`z3-robustness: ${corpus.length} samples ok (${mode})`);
