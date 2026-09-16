#!/usr/bin/env node
'use strict';

/* Frozen #338 Auto/Manual fetch-budget and preference-order contracts. */

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

function pollReply() {
	return { log: [], adaptive: 1 };
}

async function requestedLines(limit, mode, manual, paused) {
	let got = null;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function (args) {
				got = args.addresses[0];
				return pollReply();
			}
		}
	});
	const v = h.view;
	v.applyRowLimit(limit);
	v.fetchMode = mode;
	v.manualFetchLines = manual;
	v.paused = !!paused;
	v.rpcPreferencesResolved = true;
	await v.fetchEntries();
	return got;
}

async function testAutoAndManualBudgets() {
	assert.strictEqual(await requestedLines(25, 'auto', 100, false), '100');
	assert.strictEqual(await requestedLines(2000, 'auto', 100, false), '2000');
	assert.strictEqual(await requestedLines(25, 'manual', 250, false), '250');
	assert.strictEqual(await requestedLines(2000, 'manual', 250, true), '250');
	console.log('fwlive-view fetch-budget: Auto boundaries and Manual paused bound OK');
}

async function testManualSeeding() {
	for (const [limit, expected] of [
		[25, 100],
		[100, 250],
		[500, 2000],
		[2000, 2000]
	]) {
		const h = loadFwliveView({
			storage: { 'fwlive-row-limit': String(limit) }
		});
		h.view.resolveRpcPreferences();
		assert.strictEqual(h.view.fetchMode, 'auto');
		assert.strictEqual(h.view.manualFetchLines, expected, 'seed for Limit=' + limit);
	}
	console.log('fwlive-view fetch-budget: Manual seeding snaps down OK');
}

async function testHashOrderAndAutoWriteThrough() {
	for (const hash of ['#maxraw=500&poll=manual&limit=25', '#limit=25&poll=manual&maxraw=500']) {
		const h = loadFwliveView({
			storage: {
				'fwlive-row-limit': '100',
				'fwlive-poll-mode': 'auto',
				'fwlive-manual-lines': '100'
			},
			location: { hash: hash }
		});
		h.view.resolveRpcPreferences();
		assert.deepStrictEqual(
			[h.view.rowLimit, h.view.fetchMode, h.view.manualFetchLines],
			[25, 'manual', 500],
			hash
		);
	}

	const h = loadFwliveView({
		storage: {
			'fwlive-poll-mode': 'manual',
			'fwlive-manual-lines': '250'
		},
		location: { hash: '#maxraw=2000&poll=auto' }
	});
	h.view.resolveRpcPreferences();
	assert.strictEqual(h.view.fetchMode, 'auto');
	assert.strictEqual(h.view.manualFetchLines, 250, 'Auto must not overwrite stored Manual');
	console.log('fwlive-view fetch-budget: hash precedence and Auto write-through OK');
}

async function testFirstRpcUsesResolvedPreferences() {
	let firstAddress = null;
	const h = loadFwliveView({
		storage: {
			'fwlive-row-limit': '100',
			'fwlive-poll-mode': 'manual',
			'fwlive-manual-lines': '25'
		},
		rpcMocks: {
			'fwlive.poll': async function (args) {
				firstAddress = args.addresses[0];
				return pollReply();
			}
		}
	});
	h.view.loadRulesMap = function () {
		return Promise.resolve();
	};
	h.view.loadLoggingStatus = function () {
		return Promise.resolve();
	};
	await h.view.load();
	assert.strictEqual(firstAddress, '25', 'first RPC must use stored Manual maximum');
	console.log('fwlive-view fetch-budget: preferences precede first RPC OK');
}

async function testBudgetControlsAndMetadata() {
	const replies = [
		{ log: [], adaptive: 1, effective_limit: 250 },
		{ log: [], adaptive: 1, effective_limit: '250' },
		{ log: [], adaptive: 0 },
		{ log: [] }
	];
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return replies.shift();
			}
		}
	});
	const v = h.view;
	h.document.querySelector = function () {
		return null;
	};
	v.updateRowTintUi = function () {};
	h.document.getElementById('fwlive-watch-dot').classList = {
		add: function () {},
		remove: function () {}
	};
	v.applyRowLimit(100);
	v.fetchMode = 'auto';
	v.rpcPreferencesResolved = true;
	v.updateStreamControlsUi();
	const mode = h.document.getElementById('fwlive-fetch-mode');
	const manual = h.document.getElementById('fwlive-manual-lines');
	assert.ok(mode, 'Fetch budget control must render');
	assert.strictEqual(mode._attrs['aria-controls'], 'fwlive-manual-lines');
	assert.strictEqual(manual.disabled, true, 'Manual maximum is disabled in Auto');

	await v.fetchEntries();
	assert.match(
		h.document.getElementById('fwlive-adaptive').textContent,
		/server limited fetch to 250/
	);
	await v.fetchEntries();
	assert.doesNotMatch(
		h.document.getElementById('fwlive-adaptive').textContent,
		/server limited fetch/
	);
	await v.fetchEntries();
	assert.match(
		h.document.getElementById('fwlive-adaptive').textContent,
		/protection is disabled/i
	);
	await v.fetchEntries();
	assert.match(h.document.getElementById('fwlive-adaptive').textContent, /state is unknown/i);

	v.fetchMode = 'manual';
	v.updateStreamControlsUi();
	assert.strictEqual(manual.disabled, false, 'Manual maximum is enabled in Manual');
	console.log('fwlive-view fetch-budget: controls and metadata validation OK');
}

async function main() {
	await testAutoAndManualBudgets();
	await testManualSeeding();
	await testHashOrderAndAutoWriteThrough();
	await testFirstRpcUsesResolvedPreferences();
	await testBudgetControlsAndMetadata();
	console.log('fwlive-view fetch-budget tests passed');
}

main().catch(function (err) {
	console.error(err.stack || err);
	process.exit(1);
});
