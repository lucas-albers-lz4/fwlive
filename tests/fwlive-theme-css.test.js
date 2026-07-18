#!/usr/bin/env node
'use strict';

/**
 * Guard: fwlive view styles use LuCI theme CSS variables (no hardcoded hex outside tint fallbacks).
 * See GitHub issue #6 (dark mode) and #14 (Material / missing *-color-high resilience).
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

/* Hex is allowed only in scoped tint token chains and rgba tint base / fallback rules. */
const tintHexAllowRe = /--fwlive-(?:pass|deny)-color:\s*var\([^;]*#[0-9a-fA-F]{3,8}/g;
const tintAllowedHex = new Set();
let allowMatch;
while ((allowMatch = tintHexAllowRe.exec(css)) !== null) {
	const hexes = allowMatch[0].match(/#[0-9a-fA-F]{3,8}\b/g) || [];
	hexes.forEach((h) => tintAllowedHex.add(h.toLowerCase()));
}

const allHex = css.match(/#[0-9a-fA-F]{3,8}\b/g) || [];
const bannedHex = allHex.filter((h) => !tintAllowedHex.has(h.toLowerCase()));
if (bannedHex.length) {
	console.error('hardcoded hex colors outside tint fallbacks:', bannedHex.join(', '));
	process.exit(1);
}

function hasVarUsage(cssText, name) {
	return cssText.includes(`var(${name})`) || cssText.includes(`var(${name},`);
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
	if (!hasVarUsage(css, v)) {
		console.error(`missing LuCI theme variable usage: ${v}`);
		process.exit(1);
	}
}

/* Material / custom themes expose short names; Bootstrap uses *-high. */
if (!hasVarUsage(css, '--success-color')) {
	console.error('missing Material fallback chain var(--success-color, ...)');
	process.exit(1);
}
if (!hasVarUsage(css, '--error-color')) {
	console.error('missing Material fallback chain var(--error-color, ...)');
	process.exit(1);
}

if (!css.includes('--fwlive-pass-color:') || !css.includes('--fwlive-deny-color:')) {
	console.error('missing scoped --fwlive-pass-color / --fwlive-deny-color tokens');
	process.exit(1);
}

const keySelectors = [
	'.fwlive-scroll',
	'#fwlive-table thead th',
	'.fwlive-empty',
	'.fwlive-deny',
	'.fwlive-pass',
	'#fwlive-table td.fwlive-action.fwlive-pass',
	'#fwlive-table td.fwlive-action.fwlive-deny',
	'#fwlive-table tbody tr.fwlive-row-pass td',
	'#fwlive-table tbody tr.fwlive-row-deny td'
];

for (const sel of keySelectors) {
	const idx = css.indexOf(sel);
	if (idx < 0) {
		console.error(`missing selector in style block: ${sel}`);
		process.exit(1);
	}
	const chunk = css.slice(idx, idx + 400);
	if (!/var\(--/.test(chunk) && !/rgba\(/.test(chunk)) {
		console.error(`selector ${sel} has no var(--...) or rgba(...) color rule nearby`);
		process.exit(1);
	}
}

const rowTintPass = css.indexOf('#fwlive-table tbody tr.fwlive-row-pass td');
const rowTintDeny = css.indexOf('#fwlive-table tbody tr.fwlive-row-deny td');
const passChunk = css.slice(rowTintPass, rowTintPass + 350);
const denyChunk = css.slice(rowTintDeny, rowTintDeny + 350);

if (!/rgba\(\s*70\s*,\s*165\s*,\s*70/.test(passChunk)) {
	console.error('fwlive-row-pass must include rgba base tint (non-color-mix fallback)');
	process.exit(1);
}
if (!/rgba\(\s*202\s*,\s*60\s*,\s*60/.test(denyChunk)) {
	console.error('fwlive-row-deny must include rgba base tint (non-color-mix fallback)');
	process.exit(1);
}
if (!/color-mix\(in srgb,\s*var\(--fwlive-pass-color\)/.test(passChunk)) {
	console.error('fwlive-row-pass must use color-mix with --fwlive-pass-color');
	process.exit(1);
}
if (!/color-mix\(in srgb,\s*var\(--fwlive-deny-color\)/.test(denyChunk)) {
	console.error('fwlive-row-deny must use color-mix with --fwlive-deny-color');
	process.exit(1);
}

if (!css.includes('data-tint-fallback')) {
	console.error('missing data-tint-fallback solid paint rules');
	process.exit(1);
}

if (!text.includes("localStorage.getItem('fwlive-row-tint')")) {
	console.error('missing fwlive-row-tint localStorage persistence');
	process.exit(1);
}
if (!text.includes("'id': 'fwlive-row-tint'")) {
	console.error('missing Row tint checkbox in toolbar');
	process.exit(1);
}
if (!text.includes("'id': 'fwlive-tint-warn'")) {
	console.error('missing theme tint warning element');
	process.exit(1);
}

console.log('fwlive theme CSS tests passed');
