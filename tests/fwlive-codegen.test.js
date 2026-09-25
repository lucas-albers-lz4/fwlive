#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
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

console.log('fwlive codegen freshness + syntax OK');
