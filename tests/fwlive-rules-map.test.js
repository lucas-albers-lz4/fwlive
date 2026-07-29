#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const RPCD = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive');
const FIXTURE = path.join(__dirname, 'fixtures', 'iptables-save.sample');
const RULESMAP = '/tmp/rulesmap';

function run() {
	fs.copyFileSync(FIXTURE, RULESMAP);

	const raw = execFileSync(RPCD, ['__rulesmap_iptables'], { encoding: 'utf8' });
	const res = JSON.parse(raw);

	assert.equal(res.backend, 'iptables');
	assert.equal(res.rules['fwlive-ping'], 'fwlive-ping');
	assert.equal(res.rules['allow-dns'], 'Allow-DNS');

	// Fixed path only: argv fixture path must not be readable when /tmp/rulesmap is gone.
	fs.unlinkSync(RULESMAP);
	let failed = false;
	try {
		execFileSync(RPCD, ['__rulesmap_iptables', FIXTURE], {
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'pipe'],
		});
	} catch (e) {
		failed = e.status !== 0;
	}
	assert.equal(failed, true, 'arbitrary argv path must not be accepted');

	console.log('fwlive rules map tests passed');
}

run();
