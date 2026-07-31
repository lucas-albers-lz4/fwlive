#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const SHELL_DST = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.sh');
const LUCI_DST = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js');
const GEN_SHELL = path.join(ROOT, 'scripts/gen-shell-classifier.js');
const GEN_LUCI = path.join(ROOT, 'scripts/gen-luci-wrapper.js');

const out = spawnSync(process.execPath, [GEN_SHELL], { encoding: 'utf8' });
assert.equal(out.status, 0, out.stderr || out.stdout);
assert.strictEqual(out.stdout, fs.readFileSync(SHELL_DST, 'utf8'),
	'fwlive-is-firewall-event.sh is stale — run ./scripts/gen-all.sh and commit');

const syn = spawnSync('sh', ['-n', SHELL_DST], { encoding: 'utf8' });
assert.equal(syn.status, 0, 'generated shell fails sh -n: ' + syn.stderr);

const out2 = spawnSync(process.execPath, [GEN_LUCI], { encoding: 'utf8' });
assert.equal(out2.status, 0, out2.stderr || out2.stdout);
assert.strictEqual(out2.stdout, fs.readFileSync(LUCI_DST, 'utf8'),
	'fwlive/log.js failed gen-luci-wrapper checks');
assert.ok(out2.stdout.indexOf('.includes(') < 0 && out2.stdout.indexOf('Object.values') < 0,
	'generated LuCI wrapper must stay 21.02-compatible');

console.log('fwlive codegen freshness + syntax OK');
