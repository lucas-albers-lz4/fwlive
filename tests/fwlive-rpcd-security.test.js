#!/usr/bin/env node
'use strict';

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const RPCD = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/libexec/rpcd/fwlive');
const ACL = path.join(ROOT,
	'openwrt-feed/luci-app-fwlive/root/usr/share/rpcd/acl.d/luci-app-fwlive.json');
const LOGGING_TEST = path.join(ROOT, 'tests/fwlive-logging.test.sh');

const acl = JSON.parse(fs.readFileSync(ACL, 'utf8'));
const readUbus = acl['luci-app-fwlive']?.read?.ubus || {};
if (Object.prototype.hasOwnProperty.call(readUbus, 'log')) {
	console.error('ACL must not grant ubus log.* (poll uses root log.read inside rpcd)');
	process.exit(1);
}
if (!Array.isArray(readUbus.fwlive) || !readUbus.fwlive.includes('poll')) {
	console.error('ACL must grant fwlive.poll for Luci sessions');
	process.exit(1);
}

const out = execFileSync('sh', [RPCD, '__selftest'], { encoding: 'utf8' });
if (out.includes('skip:'))
	console.log('fwlive rpcd security: ' + out.trim());

execFileSync('bash', [LOGGING_TEST], { stdio: 'inherit' });

console.log('fwlive rpcd security: OK');
