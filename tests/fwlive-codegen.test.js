#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('./lib/child-process-timeout');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const SHELL_DST = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.sh');
const AWK_DST = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.awk');
const LUCI_DST = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js');
const GEN_SHELL = path.join(ROOT, 'scripts/gen-shell-classifier.js');
const GEN_LUCI = path.join(ROOT, 'scripts/gen-luci-wrapper.js');

const out = spawnSync(process.execPath, [GEN_SHELL], { encoding: 'utf8' });
assert.equal(out.status, 0, out.stderr || out.stdout);
assert.strictEqual(out.stdout, fs.readFileSync(SHELL_DST, 'utf8'),
	'fwlive-is-firewall-event.sh is stale — run ./scripts/gen-all.sh and commit');

const awk = spawnSync(process.execPath, [GEN_SHELL, '--awk'], { encoding: 'utf8' });
assert.equal(awk.status, 0, awk.stderr || awk.stdout);
assert.strictEqual(awk.stdout, fs.readFileSync(AWK_DST, 'utf8'),
	'fwlive-is-firewall-event.awk is stale — run ./scripts/gen-all.sh and commit');
assert.equal(fs.statSync(AWK_DST).mode & 0o111, 0,
	'fwlive-is-firewall-event.awk must not be executable');
const awkSyntax = spawnSync('awk', ['-f', AWK_DST], { input: '', encoding: 'utf8' });
assert.equal(awkSyntax.status, 0, 'generated awk fails syntax check: ' + awkSyntax.stderr);

const syn = spawnSync('sh', ['-n', SHELL_DST], { encoding: 'utf8' });
assert.equal(syn.status, 0, 'generated shell fails sh -n: ' + syn.stderr);

const out2 = spawnSync(process.execPath, [GEN_LUCI], { encoding: 'utf8' });
assert.equal(out2.status, 0, out2.stderr || out2.stdout);
assert.ok(out2.stdout.indexOf('.includes(') < 0 && out2.stdout.indexOf('Object.values') < 0,
	'generated LuCI wrapper must not use Array.includes or Object.values');

const luciFd = fs.openSync(LUCI_DST, 'r');
let luciSrc;
try {
	assert.equal((fs.fstatSync(luciFd).mode & 0o044), 0o044,
		'fwlive/log.js must be world-readable');
	luciSrc = fs.readFileSync(luciFd, 'utf8');
} finally {
	fs.closeSync(luciFd);
}
assert.strictEqual(out2.stdout, luciSrc,
	'fwlive/log.js failed gen-luci-wrapper checks');
const luciTmp = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-luci-gate-'));
try {
	const stalePrefixSrc = luciSrc.replace(
		/const NON_FIREWALL_PREFIX = new RegExp\([\s\S]*?\);/,
		'const NON_FIREWALL_PREFIX = /^(staledaemon)/i;'
	);
	const stalePrefixPath = path.join(luciTmp, 'stale-prefix.js');
	fs.writeFileSync(stalePrefixPath, stalePrefixSrc);
	const stalePrefix = spawnSync(process.execPath, [GEN_LUCI, stalePrefixPath], { encoding: 'utf8' });
	assert.notEqual(stalePrefix.status, 0,
		'stale NON_FIREWALL_PREFIX should fail gen-luci-wrapper regex gate');
	assert.match(stalePrefix.stderr + stalePrefix.stdout,
		/NON_FIREWALL_PREFIX regex source drifted from CLASSIFY_SPEC/);

	const staleGlueSrc = luciSrc.replace(
		/const NETFILTER_KV_GLUE = new RegExp\([\s\S]*?\);/,
		'const NETFILTER_KV_GLUE = /([^\\s])(?=(STALE)=)/g;'
	);
	const staleGluePath = path.join(luciTmp, 'stale-glue.js');
	fs.writeFileSync(staleGluePath, staleGlueSrc);
	const staleGlue = spawnSync(process.execPath, [GEN_LUCI, staleGluePath], { encoding: 'utf8' });
	assert.notEqual(staleGlue.status, 0,
		'stale NETFILTER_KV_GLUE should fail gen-luci-wrapper regex gate');
	assert.match(staleGlue.stderr + staleGlue.stdout,
		/NETFILTER_KV_GLUE regex source drifted from CLASSIFY_SPEC/);

	const mutatedSpecSrc = luciSrc.replace(
		"'wpad'",
		"'wpad', 'staledaemon'"
	);
	const mutatedSpecPath = path.join(luciTmp, 'mutated-spec.js');
	fs.writeFileSync(mutatedSpecPath, mutatedSpecSrc);
	const mutatedSpec = spawnSync(process.execPath, [GEN_LUCI, mutatedSpecPath], { encoding: 'utf8' });
	assert.notEqual(mutatedSpec.status, 0,
		'CLASSIFY_SPEC mutation without core sync should fail gen-luci-wrapper gate');
	assert.match(mutatedSpec.stderr + mutatedSpec.stdout,
		/CLASSIFY_SPEC drifted from core/);
} finally {
	fs.rmSync(luciTmp, { recursive: true, force: true });
}

const core = require(path.join(ROOT, 'core/fwlive-log.js'));

const { emitAwkPred, emitAwkRules, emitAwkProgram } = require(GEN_SHELL);
assert.equal(emitAwkPred({ hint: true }), 'has_hint(s)');
assert.equal(emitAwkPred({ action: 'known' }), 'action != "UNKNOWN"');
assert.throws(
	() => emitAwkPred({ kv: ['SRC'], hint: true }),
	/exactly one key/
);
assert.throws(
	() => emitAwkPred({ notKv: ['SRC'] }),
	/unrecognised CLASSIFY_SPEC predicate node/
);

const originalRules = core.CLASSIFY_SPEC.rules;
function captureError(fn) {
	try {
		fn();
	} catch (error) {
		return error;
	}
	assert.fail('expected the validator to reject malformed CLASSIFY_SPEC data');
}

try {
	const sparseValues = [];
	sparseValues.length = 1;
	const malformed = [
		{
			rules: [],
			message: 'CLASSIFY_SPEC rules must be a non-empty array'
		},
		{
			rules: [{ and: [] }],
			message: 'CLASSIFY_SPEC and node must be a non-empty array'
		},
		{
			rules: [{ or: [] }],
			message: 'CLASSIFY_SPEC or node must be a non-empty array'
		},
		{
			rules: [{ and: 'SRC' }],
			message: 'CLASSIFY_SPEC and node must be an array'
		},
		{
			rules: [{ and: [{ kv: [] }] }],
			message: 'CLASSIFY_SPEC kv predicate must be a non-empty array of non-empty strings'
		},
		{
			rules: [{ and: [{ kv: [''] }] }],
			message: 'CLASSIFY_SPEC kv predicate must be a non-empty array of non-empty strings'
		},
		{
			rules: [{ and: [{ kv: [1] }] }],
			message: 'CLASSIFY_SPEC kv predicate must be a non-empty array of non-empty strings'
		},
		{
			rules: [{ and: [{ kv: sparseValues }] }],
			message: 'CLASSIFY_SPEC kv predicate must be a non-empty array of non-empty strings'
		},
		{
			rules: [{ and: [{ kvAny: [] }] }],
			message: 'CLASSIFY_SPEC kvAny predicate must be a non-empty array of non-empty strings'
		},
		{
			rules: [{ and: [{ kvAny: 'SRC' }] }],
			message: 'CLASSIFY_SPEC kvAny predicate must be a non-empty array of non-empty strings'
		},
		{
			rules: [{ and: [{ action: 'knownx' }] }],
			message: 'CLASSIFY_SPEC action predicate must be "known"'
		},
		{
			rules: [{ and: [{ hint: 0 }] }],
			message: 'CLASSIFY_SPEC hint predicate must be true'
		},
		{
			rules: [null],
			message: 'CLASSIFY_SPEC node must be an object'
		},
		{
			rules: [{ and: [{ kv: ['SRC'], hint: true }] }],
			message: 'CLASSIFY_SPEC node must have exactly one key: {\"kv\":[\"SRC\"],\"hint\":true}'
		},
		{
			rules: [{ or: [{ kv: ['SRC'] }, { kv: [] }] }],
			message: 'CLASSIFY_SPEC kv predicate must be a non-empty array of non-empty strings'
		}
	];
	for (const key of ['kv', 'kvAny']) {
		for (const value of ['a"b', 'a\\b', 'a\nb', 'a.b', 'a b']) {
			malformed.push({ rules: [{ [key]: [value] }],
				message: 'CLASSIFY_SPEC ' + key + ' predicate contains an invalid KV name' });
		}
	}
	for (let i = 0; i < malformed.length; i++) {
		core.CLASSIFY_SPEC.rules = malformed[i].rules;
		const jsError = captureError(() => core.validateClassifySpec(core.CLASSIFY_SPEC));
		const codegenError = captureError(() => emitAwkRules());
		assert.equal(jsError.message, malformed[i].message);
		assert.equal(codegenError.message, malformed[i].message);
		assert.equal(codegenError.message, jsError.message,
			'codegen and JS validator error text differs for ' + JSON.stringify(malformed[i].rules));
	}

	core.CLASSIFY_SPEC.rules = [{ or: [{ kv: ['SRC'] }] }];
	assert.match(emitAwkRules(), /if \(\(has_kv\(s, \"SRC\"\)\)\) return 1/);
	const barePredicateMessages = ['SRC=192.0.2.1', 'DST=192.0.2.1'];
	const barePredicateAwk = emitAwkProgram();
	for (let i = 0; i < barePredicateMessages.length; i++) {
		const message = barePredicateMessages[i];
		const expected = core.evaluateClassifySpec(message) ? '1' : '0';
		const result = spawnSync('awk', ['-v', 'MODE=msg', barePredicateAwk], {
			input: message,
			encoding: 'utf8'
		});
		assert.equal(result.status, 0, 'emitted awk failed for bare predicate: ' + result.stderr);
		assert.equal(result.stdout.trim(), expected,
			'emitted awk and JS evaluator disagree for bare predicate on ' + message);
	}

	core.CLASSIFY_SPEC.rules = [{ and: [{ kv: ['SRC'], hint: true }] }];
	assert.throws(
		() => core.validateClassifySpec(core.CLASSIFY_SPEC),
		/exactly one key/
	);
	assert.throws(() => emitAwkRules(), /exactly one key/);
} finally {
	core.CLASSIFY_SPEC.rules = originalRules;
}

console.log('fwlive codegen freshness + syntax OK');
