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
			encoding: opts.encoding || 'utf8',
			env: opts.env || process.env
		});
	}
	return execFileSync(cmd, prefix.concat(['-c', scriptOrFile]), {
		encoding: 'utf8',
		env: opts && opts.env ? opts.env : process.env
	});
}

function filterSpawn(args, opts) {
	const parts = SH.split(/\s+/).filter(Boolean);
	const cmd = parts[0];
	const prefix = parts.slice(1);
	return spawnSync(cmd, prefix.concat([FILTER_SH]).concat(args || []), {
		input: opts && opts.input,
		encoding: opts && opts.encoding ? opts.encoding : 'utf8',
		env: opts && opts.env ? opts.env : process.env
	});
}

function shellIsFirewall(msg) {
	const out = shSpawn(
		'. "$IS_FW" && is_firewall_event_msg "$FW_MSG" && echo yes || echo no',
		{ env: { ...process.env, FILTER_DIR: path.dirname(IS_FW), IS_FW: IS_FW, FW_MSG: msg } }
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

function jsonfilterPathEnv() {
	const jf = spawnSync('sh', ['-c', 'command -v jsonfilter'], { encoding: 'utf8' });
	if (jf.status === 0 && jf.stdout.trim())
		return { env: process.env, cleanup: function() {} };

	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-jf-'));
	fs.writeFileSync(path.join(stubDir, 'jsonfilter'), [
		'#!/usr/bin/env node',
		"'use strict';",
		'const fs = require("fs");',
		'let input = "";',
		'let expr = "";',
		'let usedS = false;',
		'const argv = process.argv.slice(2);',
		'for (let i = 0; i < argv.length; i++) {',
		'\tif (argv[i] === "-s" && i + 1 < argv.length) { input = argv[++i]; usedS = true; }',
		'\telse if (argv[i] === "-e" && i + 1 < argv.length) expr = argv[++i];',
		'}',
		'/* Host stand-in for Linux MAX_ARG_STRLEN (#234): reject huge -s. */',
		'if (usedS && Buffer.byteLength(input, "utf8") > 128 * 1024) process.exit(1);',
		'if (!usedS) input = fs.readFileSync(0, "utf8");',
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

function assertFilterParity(payload, env) {
	const filtered = shSpawn(null, {
		argvFile: FILTER_SH, input: payload, encoding: 'utf8', env: env
	});
	assert.equal(filtered.status, 0, filtered.stderr || filtered.stdout);
	const shellOut = JSON.parse(filtered.stdout);
	const jsMsgs = JSON.parse(payload).log
		.filter((e) => core.isFirewallEvent(e))
		.map((e) => e.msg)
		.sort();
	const shMsgs = (shellOut.log || []).map((e) => e.msg).sort();
	assert.deepEqual(shMsgs, jsMsgs);
	assert.equal(shellOut.messages_received, JSON.parse(payload).log.length,
		'messages_received must count every enumerated log entry before filtering');
}

function runJsonParity() {
	if (!fs.existsSync(FILTER_SH))
		throw new Error('missing fwlive-log-filter.sh');

	const jf = jsonfilterPathEnv();
	try {
		assertFilterParity(fs.readFileSync(FIXTURE, 'utf8'), jf.env);
		assertFilterParity(JSON.stringify({ log: [] }), jf.env);
		assertFilterParity(JSON.stringify({
			log: [
				{ msg: 'fw4: DROP\bIN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP' },
				{ msg: 'fw4: DROP\fIN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP' },
				{ msg: 'fw4: DROP' + String.fromCharCode(1) + 'IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP' }
			]
		}), jf.env);
	} finally {
		jf.cleanup();
	}
}

function runTempDirGuards() {
	const jf = jsonfilterPathEnv();
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-filter-tmp-'));
	const payload = JSON.stringify({ log: [] });
	try {
		fs.chmodSync(dir, 0o777);
		let filtered = filterSpawn([dir], {
			input: payload,
			encoding: 'utf8',
			env: jf.env
		});
		assert.notEqual(filtered.status, 0, 'non-sticky filter directory must fail');
		assert.equal(JSON.parse(filtered.stdout).error, 'filter_tempfile_failed');

		fs.chmodSync(dir, 0o1777);
		filtered = filterSpawn([dir], {
			input: payload,
			encoding: 'utf8',
			env: jf.env
		});
		assert.equal(filtered.status, 0, filtered.stderr || filtered.stdout);
		assert.equal(JSON.parse(filtered.stdout).messages_received, 0);
	} finally {
		jf.cleanup();
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

function runMktempFailure() {
	const jf = jsonfilterPathEnv();
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-filter-mktemp-'));
	const stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-mktemp-stub-'));
	const stubMarker = path.join(stubDir, 'mktemp-called');
	const payload = JSON.stringify({ log: [] });
	try {
		fs.chmodSync(dir, 0o1777);
		fs.writeFileSync(path.join(stubDir, 'mktemp'), [
			'#!/bin/sh',
			'printf called >"' + stubMarker + '"',
			'exit 1',
			''
		].join('\n'), { mode: 0o755 });
		let env = {
			...jf.env,
			PATH: stubDir + path.delimiter + (jf.env.PATH || process.env.PATH || '')
		};
		let filtered = filterSpawn([dir], {
			input: payload,
			encoding: 'utf8',
			env
		});
		if (filtered.status === 0 && SH.includes('busybox')) {
			// BusyBox ash resolves mktemp as a builtin, so PATH shadowing does
			// not reach the production guard. Sticky + owner r-x (01500) still
			// passes -d/-k and makes builtin mktemp fail for a non-root owner.
			// 01577 was still group/other-writable, so mktemp could succeed.
			// Root bypasses DAC, so fall back to a regular file at the path
			// (same error token, every uid).
			fs.chmodSync(dir, 0o1500);
			filtered = filterSpawn([dir], {
				input: payload,
				encoding: 'utf8',
				env: jf.env
			});
			if (filtered.status === 0) {
				fs.rmSync(dir, { recursive: true, force: true });
				fs.writeFileSync(dir, 'not a directory\n');
				filtered = filterSpawn([dir], {
					input: payload,
					encoding: 'utf8',
					env: jf.env
				});
			}
		} else {
			assert.ok(fs.existsSync(stubMarker), 'PATH-shadowed mktemp must run on dash/sh');
		}
		assert.notEqual(filtered.status, 0, 'mktemp failure must exit non-zero');
		assert.equal(JSON.parse(filtered.stdout).error, 'filter_tempfile_failed');
		if (fs.statSync(dir).isDirectory()) {
			const leftovers = fs.readdirSync(dir).filter((f) => f.startsWith('fwlive-filter.'));
			assert.equal(leftovers.length, 0, 'mktemp failure must not leave partial temp files');
		}
	} finally {
		jf.cleanup();
		fs.rmSync(dir, { recursive: true, force: true });
		fs.rmSync(stubDir, { recursive: true, force: true });
	}
}

function runSymlinkTempDir() {
	const jf = jsonfilterPathEnv();
	const realDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-filter-real-'));
	const linkDir = path.join(os.tmpdir(), `fwlive-filter-link-${process.pid}`);
	const payload = JSON.stringify({ log: [] });
	try {
		fs.chmodSync(realDir, 0o1777);
		fs.rmSync(linkDir, { force: true });
		fs.symlinkSync(realDir, linkDir);
		const filtered = filterSpawn([linkDir], {
			input: payload,
			encoding: 'utf8',
			env: jf.env
		});
		assert.notEqual(filtered.status, 0, 'symlink filter directory must fail');
		assert.equal(JSON.parse(filtered.stdout).error, 'filter_tempfile_failed');
	} finally {
		jf.cleanup();
		fs.rmSync(linkDir, { force: true });
		fs.rmSync(realDir, { recursive: true, force: true });
	}
}

function runJsonGetMsgEscapes() {
	const cases = [
		'{"msg":"fw4: DROP\\bIN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP"}',
		'{"msg":"fw4: DROP\\fIN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP"}',
		'{"msg":"fw4: DROP\\u0009IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP"}',
		'{"msg":"fw4: DROP\\u0001IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP"}'
	];
	for (const line of cases) {
		const out = shSpawn(
			'. "$IS_FW" && printf \'%s\\n\' "$LINE" | _fwlive_filter_json_entries',
			{ env: { ...process.env, FILTER_DIR: path.dirname(IS_FW), IS_FW: IS_FW, LINE: line } }
		);
		assert.ok(out.includes('IN=wan'), 'json_get_msg dropped classify for ' + line);
	}
}

function runEmptyMalformedInput() {
	const jf = jsonfilterPathEnv();
	try {
		for (const input of ['', '{not-json']) {
			const filtered = shSpawn(null, {
				argvFile: FILTER_SH, input, encoding: 'utf8', env: jf.env
			});
			assert.notEqual(filtered.status, 0, 'malformed input must remain an error');
			assert.equal(JSON.parse(filtered.stdout).error, 'filter_failed',
				'jsonfilter failure must not become a healthy empty result');
		}
	} finally {
		jf.cleanup();
	}
}

function runSummaryContract() {
	const jf = jsonfilterPathEnv();
	const payload = JSON.stringify({
		log: [
			{ msg: 'fw4: DROP IN=wan SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP' },
			{ msg: 'fw4: DROP IN=wan SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP' },
			{ msg: 'fw4: ACCEPT IN=wan SRC=203.0.113.2 DST=192.0.2.1 PROTO=TCP' },
			{ msg: 'netifd: link ready' }
		]
	});
	try {
		const filtered = shSpawn(null, {
			argvFile: FILTER_SH, input: payload, encoding: 'utf8', env: jf.env
		});
		assert.equal(filtered.status, 0, filtered.stderr || filtered.stdout);
		const out = JSON.parse(filtered.stdout);
		assert.equal(out.summary.scope, 'top of shown sample');
		assert.equal(out.summary.top_drops[0].value, 'drop');
		assert.equal(out.summary.top_drops[0].count, 2);
		assert.equal(out.summary.top_talkers[0].value, '203.0.113.1');
		assert.ok(Buffer.byteLength(JSON.stringify(out.summary), 'utf8') <= 1024,
			'summary must stay within the escaped JSON byte bound');

		const disabled = shSpawn(null, {
			argvFile: FILTER_SH,
			input: payload,
			encoding: 'utf8',
			env: { ...jf.env, FWLIVE_SUMMARY: '0' }
		});
		assert.equal(disabled.status, 0, disabled.stderr || disabled.stdout);
		assert.equal(JSON.parse(disabled.stdout).summary, undefined,
			'adaptive-off filter reply must omit summary');
	} finally {
		jf.cleanup();
	}
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

	const payload = JSON.stringify({
		log: nasty.map((msg, i) => ({ msg, id: i }))
	});
	const jf = jsonfilterPathEnv();
	try {
		const filtered = shSpawn(null, {
			argvFile: FILTER_SH, input: payload, encoding: 'utf8', env: jf.env
		});
		assert.equal(filtered.status, 0, filtered.stderr || filtered.stdout);
		assert.doesNotThrow(() => JSON.parse(filtered.stdout));
	} finally {
		jf.cleanup();
	}
}

function runUnicodeSummaryBound() {
	const unicode = '🔥'.repeat(64);
	const payload = JSON.stringify({
		log: [0, 1, 2].map((i) => ({
			msg: `${i}${unicode}: DROP IN=wan SRC=${i}${unicode} DST=192.0.2.1 PROTO=TCP`
		}))
	});
	const jf = jsonfilterPathEnv();
	try {
		const filtered = shSpawn(null, {
			argvFile: FILTER_SH, input: payload, encoding: 'utf8', env: jf.env
		});
		assert.equal(filtered.status, 0, filtered.stderr || filtered.stdout);
		const summary = JSON.parse(filtered.stdout).summary;
		assert.equal(summary.truncated, true,
			'Unicode summary must use the conservative byte-safe fallback');
		assert.ok(Buffer.byteLength(JSON.stringify(summary), 'utf8') <= 1024,
			'Unicode summary must stay within the escaped JSON byte bound');
	} finally {
		jf.cleanup();
	}
}

function runUnicodeFieldTruncation() {
	const unicode = '🔥'.repeat(20);
	const payload = JSON.stringify({
		log: [0, 1].map((i) => ({
			msg: `${i}: DROP IN=wan SRC=203.0.113.1${unicode} DST=192.0.2.1 PROTO=TCP`
		}))
	});
	const jf = jsonfilterPathEnv();
	try {
		const filtered = shSpawn(null, {
			argvFile: FILTER_SH, input: payload, encoding: 'utf8', env: jf.env
		});
		assert.equal(filtered.status, 0, filtered.stderr || filtered.stdout);
		const summary = JSON.parse(filtered.stdout).summary;
		assert.equal(summary.truncated, undefined,
			'field truncation fixture must stay below the whole-summary fallback bound');
		const value = summary.top_talkers[0].value;
		assert.ok(Buffer.byteLength(value, 'utf8') <= 64,
			'bounded talker value must stay within the raw byte limit');
		assert.equal(Buffer.from(value, 'utf8').toString('utf8'), value,
			'bounded talker value must end on a UTF-8 character boundary');
		assert.ok(value.endsWith('🔥'), 'bounded talker value should retain complete emoji');
	} finally {
		jf.cleanup();
	}
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

function runMissingClassifier() {
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-no-classifier-'));
	const jf = jsonfilterPathEnv();
	try {
		fs.copyFileSync(FILTER_SH, path.join(work, 'fwlive-log-filter.sh'));
		fs.copyFileSync(IS_FW, path.join(work, 'fwlive-is-firewall-event.sh'));
		const r = spawnSync('/bin/sh', [path.join(work, 'fwlive-log-filter.sh')], {
			input: '{"log":[{"msg":"IN=wan OUT= SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP"}]}',
			encoding: 'utf8',
			env: jf.env
		});
		assert.notEqual(r.status, 0, 'missing classifier must exit non-zero');
		const j = JSON.parse(r.stdout);
		assert.equal(j.error, 'classifier_missing');
		assert.deepEqual(j.log, []);
	} finally {
		jf.cleanup();
		fs.rmSync(work, { recursive: true, force: true });
	}
}

function runOversizedStdin() {
	/* Stub rejects -s over 128KiB; stdin path must still classify (#234). */
	const pad = 'x'.repeat(130 * 1024);
	const payload = JSON.stringify({
		log: [
			{ msg: 'IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP', id: 1, _pad: pad }
		]
	});
	assert.ok(Buffer.byteLength(payload, 'utf8') > 128 * 1024);
	const jf = jsonfilterPathEnv();
	try {
		const filtered = shSpawn(null, {
			argvFile: FILTER_SH, input: payload, encoding: 'utf8', env: jf.env
		});
		assert.equal(filtered.status, 0, filtered.stderr || filtered.stdout);
		const out = JSON.parse(filtered.stdout);
		assert.equal(out.log.length, 1, 'oversized stdin must not collapse to empty log');
		assert.equal(out.log[0].msg,
			'IN=wan OUT= SRC=203.0.113.1 DST=192.0.2.1 PROTO=TCP');
		assert.equal(out.error, undefined);
	} finally {
		jf.cleanup();
	}
}

function run() {
	runMsgParity();
	runJsonParity();
	runTempDirGuards();
	runMktempFailure();
	runSymlinkTempDir();
	runJsonGetMsgEscapes();
	runEmptyMalformedInput();
	runSummaryContract();
	runMetacharSafety();
	runUnicodeSummaryBound();
	runUnicodeFieldTruncation();
	runMissingJsonfilter();
	runMissingClassifier();
	runOversizedStdin();
	console.log('fwlive shell filter parity tests passed (SH=' + SH + ')');
}

run();
