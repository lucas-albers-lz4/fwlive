#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const RPCD = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive');
const FIXTURE = path.join(__dirname, 'fixtures', 'iptables-save.sample');

function run() {
	const raw = execFileSync(RPCD, ['__rulesmap_iptables', FIXTURE], { encoding: 'utf8' });
	const res = JSON.parse(raw);

	assert.equal(res.backend, 'iptables');
	assert.equal(res.rules['fwlive-ping'], 'fwlive-ping');
	assert.equal(res.rules['allow-dns'], 'Allow-DNS');

	console.log('fwlive rules map tests passed');
}

run();
