#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const SHELL_DST = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/fwlive-is-firewall-event.sh');
const GEN = path.join(ROOT, 'scripts/gen-shell-classifier.js');

const out = spawnSync(process.execPath, [GEN], { encoding: 'utf8' });
assert.equal(out.status, 0, out.stderr || out.stdout);
assert.strictEqual(out.stdout, fs.readFileSync(SHELL_DST, 'utf8'),
	'fwlive-is-firewall-event.sh is stale — run node scripts/gen-shell-classifier.js and commit');

const syn = spawnSync('sh', ['-n', SHELL_DST], { encoding: 'utf8' });
assert.equal(syn.status, 0, 'generated shell fails sh -n: ' + syn.stderr);

console.log('fwlive codegen freshness + syntax OK');
