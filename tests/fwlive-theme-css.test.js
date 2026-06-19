#!/usr/bin/env node
'use strict';

/**
 * Guard: fwlive view styles use LuCI theme CSS variables (no hardcoded hex colors).
 * See GitHub issue #6 — dark mode breaks when colors are fixed to light-theme values.
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const VIEW_PATH = path.join(
	ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js'
);

const text = fs.readFileSync(VIEW_PATH, 'utf8');
const styleMatch = text.match(/E\('style',\s*\{\},\s*`([\s\S]*?)`\)/);
if (!styleMatch)
	throw new Error('could not extract inline style block from fwlive.js');

const css = styleMatch[1];
const hexColors = css.match(/#[0-9a-fA-F]{3,8}\b/g) || [];
if (hexColors.length) {
	console.error('hardcoded hex colors in fwlive view CSS:', hexColors.join(', '));
	process.exit(1);
}

const requiredVars = [
	'--background-color-high',
	'--background-color-medium',
	'--background-color-low',
	'--text-color-high',
	'--text-color-medium',
	'--border-color-high',
	'--border-color-medium',
	'--border-color-low',
	'--primary-color-high',
	'--success-color-high',
	'--error-color-high',
	'--warn-color-high'
];

for (const v of requiredVars) {
	if (!css.includes(`var(${v})`)) {
		console.error(`missing LuCI theme variable usage: ${v}`);
		process.exit(1);
	}
}

const keySelectors = [
	'.fwlive-scroll',
	'#fwlive-table thead th',
	'.fwlive-empty',
	'.fwlive-deny',
	'.fwlive-pass'
];

for (const sel of keySelectors) {
	const idx = css.indexOf(sel);
	if (idx < 0) {
		console.error(`missing selector in style block: ${sel}`);
		process.exit(1);
	}
	const chunk = css.slice(idx, idx + 400);
	if (!/var\(--/.test(chunk)) {
		console.error(`selector ${sel} has no var(--...) color rule nearby`);
		process.exit(1);
	}
}

console.log('fwlive theme CSS tests passed');
