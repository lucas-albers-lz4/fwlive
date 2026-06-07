#!/usr/bin/env node
'use strict';

/**
 * Guard: Node parser (core/fwlive-log.js) and LuCI mirror (fwlive/log.js) stay aligned.
 * Bump PARSER_SYNC_VERSION in both files when you intentionally change parser logic.
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const CORE = path.join(ROOT, 'core/fwlive-log.js');
const LUCI = path.join(
	ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/log.js'
);

const SYNC_RE = /PARSER_SYNC_VERSION:\s*(\d+)/;

function readVersion(file) {
	const text = fs.readFileSync(file, 'utf8');
	const m = text.match(SYNC_RE);
	if (!m)
		throw new Error(`missing PARSER_SYNC_VERSION in ${file}`);
	return m[1];
}

const coreV = readVersion(CORE);
const luciV = readVersion(LUCI);

if (coreV !== luciV) {
	console.error(`parser sync mismatch: core=${coreV} luci=${luciV}`);
	process.exit(1);
}

console.log(`fwlive parser sync OK (version ${coreV})`);
