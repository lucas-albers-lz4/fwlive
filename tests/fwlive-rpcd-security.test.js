#!/usr/bin/env node
'use strict';

const { execFileSync } = require('node:child_process');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const RPCD = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive');
const LOGGING_TEST = path.join(ROOT, 'tests/fwlive-logging.test.sh');

const out = execFileSync('sh', [RPCD, '__selftest'], { encoding: 'utf8' });
if (out.includes('skip:'))
	console.log('fwlive rpcd security: ' + out.trim());

execFileSync('bash', [LOGGING_TEST], { stdio: 'inherit' });

console.log('fwlive rpcd security: OK');
