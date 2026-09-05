#!/usr/bin/env node
'use strict';

/**
 * #240 C1 — parser corpus pin.
 *
 * Replay the logread-shaped fixtures through core/fwlive-log.js (classify +
 * normalize) and fwlive-log-filter.sh. Both paths must satisfy the same
 * golden table. Shell filter keeps raw entries; JS additionally pins
 * normalize fields. Not a new proof — a golden-row contract on the
 * existing mixed + iptables corpora.
 */

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const core = require('../core/fwlive-log.js');

const ROOT = path.join(__dirname, '..');
const FILTER_SH = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-log-filter.sh');
const FIXTURE_DIR = path.join(__dirname, 'fixtures');
/* Override with SH=busybox or SH='busybox sh' for ash parity. */
const SH = process.env.SH || 'sh';

const FIXTURES = [ 'logread-mixed.json', 'logread-iptables.json' ];

const ROW_FIELDS = [
	'action', 'action_raw', 'proto', 'src', 'dst', 'sport', 'dport',
	'interface_in', 'interface_out', 'rule_hint', 'flags', 'length', 'timestamp'
];

/* Index + msg pin fixture identity; firewall + fields are the C1 contract. */
const GOLDEN = [
	{
		fixture: 'logread-mixed.json', i: 0, firewall: false,
		msg: 'dnsmasq[1]: started, version 2.92 cachesize 1000'
	},
	{
		fixture: 'logread-mixed.json', i: 1, firewall: false,
		msg: 'procd: Instance sysntpd::instance1 s in a crash loop 6 crashes, 0 seconds since last crash'
	},
	{
		fixture: 'logread-mixed.json', i: 2, firewall: true,
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.168.1.150 DST=8.8.8.8 PROTO=TCP SPT=49210 DPT=443',
		action: 'drop', action_raw: 'DROP', proto: 'TCP',
		src: '192.168.1.150', dst: '8.8.8.8', sport: '49210', dport: '443',
		interface_in: 'br-lan', interface_out: 'eth0', rule_hint: 'fw4',
		flags: '', length: null, timestamp: 1717675742
	},
	{
		fixture: 'logread-mixed.json', i: 3, firewall: true,
		msg: 'kernel: IN=eth0 OUT= MAC=... SRC=10.0.0.2 DST=1.1.1.1 LEN=60 PROTO=TCP SPT=49999 DPT=443 SYN',
		action: 'unknown', action_raw: 'UNKNOWN', proto: 'TCP',
		src: '10.0.0.2', dst: '1.1.1.1', sport: '49999', dport: '443',
		interface_in: 'eth0', interface_out: '', rule_hint: '',
		flags: 'SYN', length: 60, timestamp: 1717675743
	},
	{
		fixture: 'logread-mixed.json', i: 4, firewall: true,
		msg: 'fwlive-test: ACCEPT IN=br-lan SRC=192.168.1.10 DST=192.168.1.1 PROTO=UDP SPT=5353 DPT=5353',
		action: 'pass', action_raw: 'ACCEPT', proto: 'UDP',
		src: '192.168.1.10', dst: '192.168.1.1', sport: '5353', dport: '5353',
		interface_in: 'br-lan', interface_out: '', rule_hint: 'fwlive-test',
		flags: '', length: null, timestamp: 1717675744
	},
	{
		fixture: 'logread-mixed.json', i: 5, firewall: false,
		msg: "netifd: Network device 'eth0' link is up"
	},
	{
		fixture: 'logread-mixed.json', i: 6, firewall: true,
		msg: 'nft: drop IN=wan OUT= SRC=203.0.113.5 DST=192.168.1.1 PROTO=TCP DPT=22',
		action: 'drop', action_raw: 'DROP', proto: 'TCP',
		src: '203.0.113.5', dst: '192.168.1.1', sport: '', dport: '22',
		interface_in: 'wan', interface_out: '', rule_hint: 'nft',
		flags: '', length: null, timestamp: 1717675746
	},
	{
		fixture: 'logread-iptables.json', i: 0, firewall: true,
		msg: '[  123.456789] fwlive-ping: IN=br-lan OUT= MAC=00:11:22:33:44:55:66:77 SRC=192.168.1.10 DST=192.168.1.1 LEN=84 PROTO=ICMP TYPE=8 CODE=0',
		action: 'pass', action_raw: 'PASS', proto: 'ICMP',
		src: '192.168.1.10', dst: '192.168.1.1', sport: '', dport: '',
		interface_in: 'br-lan', interface_out: '', rule_hint: 'fwlive-ping',
		flags: '', length: 84, timestamp: 1717675800
	},
	{
		fixture: 'logread-iptables.json', i: 1, firewall: true,
		msg: 'iptables: DROP IN=wan OUT= SRC=203.0.113.5 DST=192.168.1.1 PROTO=TCP SPT=54321 DPT=22',
		action: 'drop', action_raw: 'DROP', proto: 'TCP',
		src: '203.0.113.5', dst: '192.168.1.1', sport: '54321', dport: '22',
		interface_in: 'wan', interface_out: '', rule_hint: '',
		flags: '', length: null, timestamp: 1717675801
	},
	{
		fixture: 'logread-iptables.json', i: 2, firewall: true,
		msg: 'custom-chain: ACCEPT IN=lan OUT= SRC=10.0.0.5 DST=8.8.8.8 PROTO=UDP SPT=5353 DPT=5353',
		action: 'pass', action_raw: 'ACCEPT', proto: 'UDP',
		src: '10.0.0.5', dst: '8.8.8.8', sport: '5353', dport: '5353',
		interface_in: 'lan', interface_out: '', rule_hint: 'custom-chain',
		flags: '', length: null, timestamp: 1717675802
	},
	{
		fixture: 'logread-iptables.json', i: 3, firewall: true,
		msg: 'fwlive-testIN=eth0 OUT= SRC=192.168.1.20 DST=1.1.1.1 PROTO=ICMP',
		action: 'pass', action_raw: 'PASS', proto: 'ICMP',
		src: '192.168.1.20', dst: '1.1.1.1', sport: '', dport: '',
		interface_in: 'eth0', interface_out: '', rule_hint: 'fwlive-test',
		flags: '', length: null, timestamp: 1717675803
	},
	{
		fixture: 'logread-iptables.json', i: 4, firewall: false,
		msg: 'dnsmasq[1]: query[A] example.com from 192.168.1.5'
	},
	{
		fixture: 'logread-iptables.json', i: 5, firewall: true,
		msg: '[   42.147422] fwlive-custom: IN=lo OUT= MAC=00:00:00:00:00:00:00:00:00:00:00:00:08:00 SRC=127.0.0.1 DST=127.0.0.1 LEN=84 TOS=0x00 PREC=0x00 TTL=64 ID=340 DF PROTO=ICMP TYPE=8 CODE=0 ID=5365 SEQ=0',
		action: 'pass', action_raw: 'PASS', proto: 'ICMP',
		src: '127.0.0.1', dst: '127.0.0.1', sport: '', dport: '',
		interface_in: 'lo', interface_out: '', rule_hint: 'fwlive-custom',
		flags: '', length: 84, timestamp: 1781999395
	}
];

function loadFixture(name) {
	return JSON.parse(fs.readFileSync(path.join(FIXTURE_DIR, name), 'utf8'));
}

function goldenFor(name) {
	return GOLDEN.filter((g) => g.fixture === name);
}

function jsonfilterPathEnv() {
	const jf = spawnSync('sh', ['-c', 'command -v jsonfilter'], { encoding: 'utf8' });
	if (jf.status === 0 && jf.stdout.trim())
		return { env: process.env, cleanup: function() {} };

	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-c1-jf-'));
	fs.writeFileSync(path.join(stubDir, 'jsonfilter'), [
		'#!/usr/bin/env node',
		"'use strict';",
		'const fs = require("fs");',
		'let input = fs.readFileSync(0, "utf8");',
		'let expr = "";',
		'const argv = process.argv.slice(2);',
		'for (let i = 0; i < argv.length; i++) {',
		'\tif (argv[i] === "-e" && i + 1 < argv.length) expr = argv[++i];',
		'}',
		'if (expr !== "@.log[*]") process.exit(1);',
		'let data;',
		'try { data = JSON.parse(input); } catch (e) { process.exit(1); }',
		'const log = (data && Array.isArray(data.log)) ? data.log : [];',
		'for (const e of log) process.stdout.write(JSON.stringify(e) + "\\n");',
		''
	].join('\n'), { mode: 0o755 });
	return {
		env: { ...process.env, PATH: stubDir + path.delimiter + (process.env.PATH || '') },
		cleanup: function() { fs.rmSync(stubDir, { recursive: true, force: true }); }
	};
}

function shellFilter(payload, env) {
	const parts = SH.split(/\s+/).filter(Boolean);
	const r = spawnSync(parts[0], parts.slice(1).concat([FILTER_SH]), {
		input: payload,
		encoding: 'utf8',
		env: env
	});
	assert.equal(r.status, 0, r.stderr || r.stdout);
	return JSON.parse(r.stdout);
}

function assertJsRow(entry, g) {
	const label = g.fixture + '[' + g.i + ']';
	assert.equal(entry.msg, g.msg, 'fixture drift ' + label);
	assert.equal(core.isFirewallEvent(entry), g.firewall, 'JS classify ' + label);

	if (!g.firewall)
		return;

	const row = core.normalizeEntry(entry);
	for (const f of ROW_FIELDS)
		assert.strictEqual(row[f], g[f], 'JS ' + f + ' ' + label);
}

function assertShellMsgs(name, payload, env) {
	const out = shellFilter(payload, env);
	const got = (out.log || []).map((e) => e.msg);
	const want = goldenFor(name).filter((g) => g.firewall).map((g) => g.msg);
	assert.deepEqual(got, want, 'shell filter msgs ' + name);
}

function run() {
	assert.ok(fs.existsSync(FILTER_SH), 'missing fwlive-log-filter.sh');

	for (const name of FIXTURES) {
		const payload = loadFixture(name);
		const gold = goldenFor(name);
		assert.equal(payload.log.length, gold.length,
			'golden must cover every ' + name + ' row');
		for (let i = 0; i < gold.length; i++)
			assert.equal(gold[i].i, i, 'golden index order ' + name);
	}

	for (const g of GOLDEN)
		assertJsRow(loadFixture(g.fixture).log[g.i], g);

	const jf = jsonfilterPathEnv();
	try {
		for (const name of FIXTURES) {
			const raw = fs.readFileSync(path.join(FIXTURE_DIR, name), 'utf8');
			const jsMsgs = JSON.parse(raw).log
				.filter((e) => core.isFirewallEvent(e))
				.map((e) => e.msg);
			const want = goldenFor(name).filter((g) => g.firewall).map((g) => g.msg);
			assert.deepEqual(jsMsgs, want, 'JS filter msgs ' + name);
			assertShellMsgs(name, raw, jf.env);
		}
	} finally {
		jf.cleanup();
	}

	console.log('fwlive parser corpus pin (#240 C1) passed (SH=' + SH + ')');
}

run();
