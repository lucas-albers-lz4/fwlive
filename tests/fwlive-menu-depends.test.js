#!/usr/bin/env node
'use strict';

/**
 * Guard: LuCI menu.d depends on ACL only (#53 / #62 / #70).
 * fs AND of nft+iptables hid Firewall Live View on stock fw3-only and fw4-only images.
 */

const fs = require('fs');
const path = require('path');

const MENU_PATH = path.join(
	__dirname,
	'..',
	'openwrt-feed/luci-app-fwlive/root/usr/share/luci/menu.d/luci-app-fwlive.json'
);

let menu;
let raw;
try {
	raw = fs.readFileSync(MENU_PATH, 'utf8');
	menu = JSON.parse(raw);
} catch (e) {
	console.error('failed to read/parse menu.d JSON at %s: %s', MENU_PATH, e.message || e);
	process.exit(1);
}

const node = menu['admin/status/fwlive'];
if (!node) {
	console.error('missing admin/status/fwlive menu node');
	process.exit(1);
}
if (node.title !== 'Firewall Live View') {
	console.error('unexpected menu title:', node.title);
	process.exit(1);
}
const depends = node.depends || {};
const acl = depends.acl || [];
if (acl.indexOf('luci-app-fwlive') < 0) {
	console.error('menu must depend on acl luci-app-fwlive');
	process.exit(1);
}
if (depends.fs) {
	console.error('menu must not use depends.fs (breaks fw3-only / fw4-only):', depends.fs);
	process.exit(1);
}
if (/\/usr\/sbin\/nft|\/usr\/sbin\/iptables/.test(raw)) {
	console.error('menu.d must not reference nft/iptables paths');
	process.exit(1);
}

console.log('fwlive menu depends tests passed');
