#!/usr/bin/env node
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('./lib/child-process-timeout');
const source = fs.readFileSync(path.join(__dirname, '../scripts/qemu-budget-split.sh'), 'utf8');
const match = source.match(/cat >"\$shim_dir\/wrap" <<'WRAP'\n([\s\S]*?)\nWRAP/);
assert.ok(match, 'shipped guest shim heredoc must be found');
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-budget-shim-'));
try {
	const fixture = path.join(work, 'fixture.json');
	const tally = path.join(work, 'tally');
	const shim = path.join(work, 'ubus');
	const expected = '{"log":[{"msg":"literal firewall fixture"}]}\n';
	fs.writeFileSync(fixture, expected);
	fs.writeFileSync(shim, match[1].replaceAll('/tmp/fwlive-logread-2000.json', fixture).replaceAll('/tmp/fwlive-budget-tally', tally), {mode: 0o755});
	const good = spawnSync('dash', [shim, '-t', '5', 'call', 'log', 'read', '{"lines":2000}'], {encoding: 'utf8'});
	assert.strictEqual(good.status, 0);
	assert.strictEqual(good.stdout, expected, 'exact fixture bytes from production argv');
	for (const args of [['call','log','read'], ['-t','4','call','log','read'], ['-t','5','call','wrong','read']]) {
		const bad = spawnSync('dash', [shim, ...args], {encoding: 'utf8'});
		assert.strictEqual(bad.status, 96, 'unexpected ubus shape must never fall through to real logd');
		assert.match(bad.stderr, /PROFILE_ERROR unexpected ubus argv/);
	}
	assert.strictEqual(fs.readFileSync(tally, 'utf8'), 'ubus\nubus\nubus\nubus\n');
} finally { fs.rmSync(work, {recursive:true, force:true}); }
const readStage = source.match(/stage_read_rpc_input\(\) \{[\s\S]*?\n\}/);
assert.ok(readStage, 'shipped read-input stage found');
const hostPlugin = path.join(__dirname, '../openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive');
const read = spawnSync('dash', ['-c', readStage[0].replaceAll('/usr/libexec/rpcd/fwlive', hostPlugin) + '\nstage_read_rpc_input'], {encoding:'utf8'});
assert.strictEqual(read.status, 0, 'source plugin through supported list entry before calling helper');
assert.strictEqual(read.stdout, '{"addresses":["50"]}', 'source dispatch output must not contaminate input stage');
console.log('production-shaped budget shim fixtures passed');
