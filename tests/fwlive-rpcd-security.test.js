#!/usr/bin/env node
'use strict';

const { execFileSync } = require('node:child_process');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const RPCD = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive');

const out = execFileSync('sh', [RPCD, '__selftest'], { encoding: 'utf8' });
if (out.includes('skip:'))
	console.log('fwlive rpcd security: %s', out.trim());

console.log('fwlive rpcd security: OK');
