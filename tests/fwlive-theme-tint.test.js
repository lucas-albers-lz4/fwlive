#!/usr/bin/env node
'use strict';

/**
 * Host unit tests for air-gapped row-tint paint-delta helpers (issue #14).
 * Extracts FWLIVE_TINT_HELPERS_* block from fwlive.js and exercises pure logic.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.join(__dirname, '..');
const VIEW_PATH = path.join(
	ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js'
);

const text = fs.readFileSync(VIEW_PATH, 'utf8');
const block = text.match(
	/\/\* FWLIVE_TINT_HELPERS_START \*\/([\s\S]*?)\/\* FWLIVE_TINT_HELPERS_END \*\//
);
if (!block)
	throw new Error('missing FWLIVE_TINT_HELPERS_START/END block in fwlive.js');

const sandbox = {};
vm.runInNewContext(block[1], sandbox);

const {
	FWLIVE_TINT_PAINT_DELTA_MIN,
	FWLIVE_TINT_PASS_HEX,
	FWLIVE_TINT_DENY_HEX,
	fwliveParseCssRgbChannels,
	fwliveCssColorPaintDelta,
	fwliveTintShouldEngageFallback
} = sandbox;

function assert(cond, msg) {
	if (!cond) {
		console.error(msg);
		process.exit(1);
	}
}

assert(typeof FWLIVE_TINT_PAINT_DELTA_MIN === 'number', 'missing FWLIVE_TINT_PAINT_DELTA_MIN');
assert(FWLIVE_TINT_PASS_HEX === '#46a546', 'unexpected FWLIVE_TINT_PASS_HEX');
assert(FWLIVE_TINT_DENY_HEX === '#ca3c3c', 'unexpected FWLIVE_TINT_DENY_HEX');

assert(fwliveParseCssRgbChannels('transparent') === null, 'transparent should be null');
assert(fwliveParseCssRgbChannels('rgba(0, 0, 0, 0)') === null, 'fully transparent rgba should be null');
assert(
	JSON.stringify(fwliveParseCssRgbChannels('rgb(70, 165, 70)')) === JSON.stringify([70, 165, 70]),
	'rgb parse failed'
);
assert(
	JSON.stringify(fwliveParseCssRgbChannels('rgba(202, 60, 60, 0.12)')) === JSON.stringify([202, 60, 60]),
	'rgba parse failed'
);
assert(
	Math.abs(fwliveParseCssRgbChannels('color(srgb 0 0.67451 0.34902 / 0.12)')[1] - 0.67451 * 255) < 0.01,
	'color(srgb) parse failed'
);
assert(
	fwliveCssColorPaintDelta('color(srgb 0 0.67451 0.34902 / 0.12)', 'rgba(0, 0, 0, 0)') > FWLIVE_TINT_PAINT_DELTA_MIN,
	'color-mix srgb serialization vs transparent must count as paint'
);

assert(fwliveCssColorPaintDelta('rgb(70, 165, 70)', 'rgb(70, 165, 70)') === 0, 'identical colors delta 0');
assert(
	fwliveCssColorPaintDelta('rgb(70, 165, 70)', 'rgb(255, 255, 255)') > FWLIVE_TINT_PAINT_DELTA_MIN,
	'pass tint vs white should exceed min delta'
);
assert(
	fwliveCssColorPaintDelta('transparent', 'rgb(255, 255, 255)') === 255 + 255 + 255,
	'transparent vs opaque must count as paint (not 0)'
);
assert(
	fwliveCssColorPaintDelta('rgba(70, 165, 70, 0.12)', 'rgba(0, 0, 0, 0)') === 70 + 165 + 70,
	'tinted rgba vs fully-transparent off-state must count as paint'
);
assert(
	fwliveCssColorPaintDelta('transparent', 'rgba(0, 0, 0, 0)') === 0,
	'transparent vs transparent stays 0'
);

assert(
	fwliveTintShouldEngageFallback({ tokenResolved: false, paintDelta: 50 }) === false,
	'good paint delta must win over missing token'
);
assert(
	fwliveTintShouldEngageFallback({ tokenResolved: false }) === true,
	'missing token engages fallback only when paint was not measured'
);
assert(
	fwliveTintShouldEngageFallback({ tokenResolved: true, paintDelta: 0 }) === true,
	'zero paint delta must engage fallback'
);
assert(
	fwliveTintShouldEngageFallback({
		tokenResolved: true,
		paintDelta: FWLIVE_TINT_PAINT_DELTA_MIN - 1
	}) === true,
	'paint delta below threshold must engage fallback'
);
assert(
	fwliveTintShouldEngageFallback({
		tokenResolved: true,
		paintDelta: FWLIVE_TINT_PAINT_DELTA_MIN
	}) === false,
	'adequate paint delta should not engage fallback'
);
assert(
	fwliveTintShouldEngageFallback({
		tokenResolved: true,
		paintDelta: 40
	}) === false,
	'strong paint delta should not engage fallback'
);

/* Probe must prefer non-alt rows (documented in source). */
assert(
	text.includes('tr:not(.fwlive-row-alt)') || text.includes(':not(.fwlive-row-alt)'),
	'probe must prefer non-alt rows'
);
assert(text.includes('probeRowTintPaint'), 'missing probeRowTintPaint');
assert(text.includes('applyTintFallback'), 'missing applyTintFallback');
assert(
	text.includes('air-gapped') || text.includes('no data leaves the device'),
	'Help text must describe air-gapped fallback'
);
assert(!/fetch\(|XMLHttpRequest|navigator\.sendBeacon/.test(block[1]), 'helpers must stay air-gapped');

console.log('fwlive theme tint helper tests passed');
