#!/usr/bin/env node
'use strict';

/**
 * Scroll followLive flip guard (#782).
 */

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

async function testScrollFixedTopDoesNotRecompute() {
	const h = loadFwliveView();
	const v = h.view;
	v.followLive = true;
	v.tablePaused = false;

	let statusCalls = 0;
	let filterCalls = 0;
	const origStatus = v.updateStatus.bind(v);
	const origFilter = v.filteredRows.bind(v);
	v.updateStatus = function () {
		statusCalls++;
		return origStatus();
	};
	v.filteredRows = function () {
		filterCalls++;
		return origFilter();
	};

	const ev = { target: { scrollTop: 0 } };
	for (let i = 0; i < 100; i++) v.onScrollArea(ev);

	assert.strictEqual(statusCalls, 0, 'unchanged followLive must not refresh status');
	assert.strictEqual(filterCalls, 0, 'unchanged followLive must not recompute filteredRows');
	console.log('fwlive-view scroll: fixed scrollTop is a no-op OK');
}

async function testScrollFlipUpdatesOnce() {
	const h = loadFwliveView();
	const v = h.view;
	v.followLive = true;
	v.tablePaused = false;

	let statusCalls = 0;
	v.updateStatus = function () {
		statusCalls++;
	};

	v.onScrollArea({ target: { scrollTop: 32 } });
	assert.strictEqual(v.followLive, false);
	assert.strictEqual(statusCalls, 1, 'crossing the threshold refreshes status once');

	v.onScrollArea({ target: { scrollTop: 40 } });
	assert.strictEqual(statusCalls, 1, 'further scroll below the line is ignored');

	v.onScrollArea({ target: { scrollTop: 0 } });
	assert.strictEqual(v.followLive, true);
	assert.strictEqual(statusCalls, 2, 'return to top refreshes status once');
	console.log('fwlive-view scroll: followLive flip OK');
}

(async function main() {
	try {
		await testScrollFixedTopDoesNotRecompute();
		await testScrollFlipUpdatesOnce();
		console.log('fwlive-view scroll tests passed');
	} catch (e) {
		console.error(e && e.stack ? e.stack : String(e));
		process.exit(1);
	}
})();
