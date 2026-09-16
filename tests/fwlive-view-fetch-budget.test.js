#!/usr/bin/env node
'use strict';

/* Frozen #338 Auto/Manual fetch-budget and preference-order contracts. */

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

function sleep(ms) {
	return new Promise(function (resolve) {
		setTimeout(resolve, ms);
	});
}

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
	const malformed = loadFwliveView({
		storage: { 'fwlive-poll-mode': 'manual', 'fwlive-manual-lines': '250junk' },
		location: { hash: '#poll=manual&maxraw=250junk' }
	});
	malformed.view.resolveRpcPreferences();
	assert.strictEqual(
		malformed.view.manualFetchLines,
		250,
		'malformed Manual value must seed safely'
	);
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
	h.view.fetchMode = 'manual';
	h.view.manualFetchLines = 500;
	h.view.rowLimit = 25;
	h.view.updateHash({ q: '' });
	assert.match(h.location ? h.location.hash : '', /poll=manual/);
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

async function testPausedBudgetChangesDoNotFetch() {
	const h = loadFwliveView({
		storage: {
			'fwlive-poll-mode': 'auto',
			'fwlive-manual-lines': '100'
		}
	});
	const v = h.view;
	let calls = 0;
	v.updateStreamControlsUi = function () {};
	v.paused = true;
	v.rpcPreferencesResolved = true;
	v.requestPoll = function () {
		calls++;
		return Promise.resolve();
	};
	v.onFetchModeChange({ target: { value: 'manual' } });
	v.onManualFetchLinesChange({ target: { value: '500' } });
	assert.strictEqual(v.fetchMode, 'manual');
	assert.strictEqual(v.manualFetchLines, 500);
	assert.strictEqual(calls, 0, 'paused budget changes must not fetch');
	assert.match(h.location.hash, /poll=manual/);
	assert.match(h.location.hash, /maxraw=500/);
	console.log('fwlive-view fetch-budget: paused changes defer fetch OK');
}

async function testLimitChangeWhileHiddenUsesVisibleCatchup() {
	let calls = 0;
	let requested = null;
	const h = loadFwliveView({
		rpcMocks: {
		'fwlive.poll': async function (args) {
			calls++;
			requested = args.addresses[0];
			return { log: [], adaptive: 1 };
		}
	}
	});
	const v = h.view;
	v.bindVisibility();
	v.rpcPreferencesResolved = true;
	h.setHidden(true);
	v.onRowLimitChange({ target: { value: '25' } });
	assert.strictEqual(calls, 0, 'hidden Limit change must not fetch immediately');
	h.setHidden(false);
	await sleep(20);
	assert.strictEqual(calls, 1, 'visible catch-up must fetch once');
	assert.strictEqual(requested, '100', 'catch-up must use the new Auto budget');
	console.log('fwlive-view fetch-budget: hidden Limit change catch-up OK');
}

async function testFillingStopRules() {
	const row = {
		id: 901,
		time: 1717675742,
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.0.2.1 DST=198.51.100.1 PROTO=TCP SPT=49210 DPT=443'
	};
	let reply = { log: [row], adaptive: 1, effective_limit: 250, messages_received: 250 };
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return reply;
			}
		}
	});
	const v = h.view;
	v.paused = true;
	v.fetchMode = 'manual';
	v.manualFetchLines = 250;
	v.rpcPreferencesResolved = true;
	await v.fetchEntries();
	assert.strictEqual(v.fillingBuffer, true, 'full page that grows the buffer keeps filling');

	await v.fetchEntries();
	assert.strictEqual(v.fillingBuffer, false, 'zero growth relative to buffer stops filling');

	reply = {
		log: [{ ...row, id: 902, time: row.time + 1 }],
		adaptive: 1,
		effective_limit: 250,
		messages_received: 100
	};
	await v.fetchEntries();
	assert.strictEqual(v.fillingBuffer, false, 'short raw page stops filling');

	v.fillingBuffer = true;
	v.resumeMerge = true;
	await v.fetchEntries();
	assert.strictEqual(v.fillingBuffer, false, 'resume merge stops filling');
	console.log('fwlive-view fetch-budget: filling stop rules OK');
}

async function testPagehideDisposesCoordinator() {
	let release;
	let calls = 0;
	const gate = new Promise(function (resolve) {
		release = resolve;
	});
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				calls++;
				await gate;
				return { log: [], adaptive: 1 };
			}
		}
	});
	const v = h.view;
	v.loadRulesMap = function () {
		return Promise.resolve();
	};
	v.loadLoggingStatus = function () {
		return Promise.resolve();
	};
	const loading = v.load();
	await sleep(10);
	assert.strictEqual(calls, 1, 'load must have one active request');
	h.dispatchPagehide();
	release();
	await loading;
	assert.strictEqual(v.entries.length, 0, 'pagehide must discard active reply');
	assert.strictEqual(v.pollDataInFlight, false, 'pagehide request must settle');
	assert.strictEqual(calls, 1, 'pagehide must not start a queued request');
	await v.requestPoll();
	assert.strictEqual(calls, 1, 'disposed coordinator must ignore later poll requests');
	console.log('fwlive-view fetch-budget: pagehide disposal contract OK');
}

async function main() {
	await testAutoAndManualBudgets();
	await testManualSeeding();
	await testHashOrderAndAutoWriteThrough();
	await testFirstRpcUsesResolvedPreferences();
	await testBudgetControlsAndMetadata();
	await testPausedBudgetChangesDoNotFetch();
	await testLimitChangeWhileHiddenUsesVisibleCatchup();
	await testFillingStopRules();
	await testPagehideDisposesCoordinator();
	console.log('fwlive-view fetch-budget tests passed');
}

main().catch(function (err) {
	console.error(err.stack || err);
	process.exit(1);
});
