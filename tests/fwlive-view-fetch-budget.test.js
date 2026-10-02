#!/usr/bin/env node
'use strict';

/* Frozen #338 Auto/Manual fetch-budget and preference-order contracts. */

const assert = require('node:assert/strict');
const { loadFwliveView, waitFor } = require('./lib/load-fwlive-view');

function sleep(ms) {
	return new Promise(function (resolve) {
		setTimeout(resolve, ms);
	});
}

function pollReply() {
	return { log: [], adaptive: 1 };
}

async function requestedLines(limit, mode, manual, tablePaused) {
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
	v.tablePaused = !!tablePaused;
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

async function testPollAndResolveWireArguments() {
	let pollWireArgs = null;
	let resolveWireArgs = null;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function (wireArgs) {
				pollWireArgs = wireArgs;
				return pollReply();
			},
			'fwlive.resolve': async function (wireArgs) {
				resolveWireArgs = wireArgs;
				return { names: {} };
			}
		}
	});
	const v = h.view;
	v.fetchMode = 'manual';
	v.manualFetchLines = 1000;
	v.rpcPreferencesResolved = true;
	await v.fetchEntries();
	assert.deepStrictEqual(
		pollWireArgs,
		{ addresses: ['1000'] },
		'poll positional value must serialize as the declared addresses array'
	);

	v.showHostnames = true;
	await v.resolveHostnamesForEntries([{ src: '192.0.2.1', dst: '198.51.100.2' }]);
	assert.deepStrictEqual(
		resolveWireArgs,
		{ addresses: ['192.0.2.1', '198.51.100.2'] },
		'resolve positional value must serialize as the declared addresses array'
	);
	console.log('fwlive-view fetch-budget: poll/resolve wire arguments OK');
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
	const firstEntry = loadFwliveView({ storage: { 'fwlive-row-limit': '100' } });
	firstEntry.view.updateStreamControlsUi = function () {};
	firstEntry.view.resolveRpcPreferences();
	firstEntry.view.applyRowLimit(25);
	firstEntry.view.onFetchModeChange({ target: { value: 'manual' } });
	assert.strictEqual(
		firstEntry.view.manualFetchLines,
		100,
		'first Manual entry must use the current Auto budget'
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

	const invalidPoll = loadFwliveView({
		storage: { 'fwlive-poll-mode': 'manual', 'fwlive-manual-lines': '250' },
		location: { hash: '#poll=foo' }
	});
	invalidPoll.view.resolveRpcPreferences();
	assert.strictEqual(invalidPoll.view.fetchMode, 'manual');
	assert.strictEqual(invalidPoll.view.readFetchMode(), 'manual');

	const invalidLimit = loadFwliveView({
		storage: { 'fwlive-row-limit': '100' },
		location: { hash: '#limit=25junk' }
	});
	invalidLimit.view.resolveRpcPreferences();
	assert.strictEqual(invalidLimit.view.rowLimit, 100);
	assert.strictEqual(invalidLimit.view.readRowLimit(), 100);

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

async function testStartupPollFinishesBeforeMetadata() {
	for (const mode of ['fast', 'slow', 'rejected']) {
		let pollCalls = 0;
		let releasePoll;
		const firstReply = new Promise((resolve) => { releasePoll = resolve; });
		const h = loadFwliveView({ rpcMocks: {
			'fwlive.poll': async function () {
				pollCalls++;
				if (pollCalls === 1 && mode === 'slow') return firstReply;
				if (pollCalls === 1 && mode === 'rejected') throw new Error('transport failure');
				return pollReply();
			}
		} });
		// Model LuCI's idle add: the first registered entry runs immediately.
		const add = h.poll.add;
		h.poll.add = function (fn, interval) {
			const idle = this._entries.length === 0;
			add.call(this, fn, interval);
			if (idle) fn();
		};
		let releaseMetadata;
		const metadata = new Promise((resolve) => { releaseMetadata = resolve; });
		h.view.loadRulesMap = () => metadata;
		h.view.loadLoggingStatus = () => metadata;
		const startup = h.view.load();
		await waitFor(() => pollCalls === 1);
		if (mode !== 'slow') {
			await waitFor(() => !h.view.ensurePollCoordinator().getState().inFlight);
		}
		releaseMetadata();
		if (mode === 'slow') releasePoll(pollReply());
		await startup;
		assert.strictEqual(pollCalls, 1, mode + ' startup must reuse the original poll after metadata settles');
		await h.view.fetchEntries();
		assert.strictEqual(pollCalls, 2, mode + ' explicit refresh must still request new data');
		await h.poll._fn();
		assert.strictEqual(pollCalls, 3, mode + ' scheduled polls must continue normally');
		h.view.disposeView();
	}
	console.log('fwlive-view fetch-budget: completed/in-flight/rejected startup deduplication OK');
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

async function testMalformedEffectiveLimits() {
	const values = [0, 2001, 250.5, '250.5', '250junk'];
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return { log: [], adaptive: 1, effective_limit: values.shift() };
			}
		}
	});
	const v = h.view;
	v.rpcPreferencesResolved = true;
	const count = values.length;
	for (let i = 0; i < count; i++) {
		await v.fetchEntries();
		assert.doesNotMatch(
			h.document.getElementById('fwlive-adaptive').textContent,
			/server limited fetch/,
			'invalid effective_limit must not claim a server limit'
		);
	}
	console.log('fwlive-view fetch-budget: malformed effective_limit values rejected OK');
}

async function testBudgetChangesRespectCadence() {
	const idle = loadFwliveView();
	const idleView = idle.view;
	let idleCalls = 0;
	idleView.updateStreamControlsUi = function () {};
	idleView.rpcPreferencesResolved = true;
	idleView.setPollCadence(5);
	idleView.requestPoll = function () {
		idleCalls++;
		return Promise.resolve();
	};
	idleView.onFetchModeChange({ target: { value: 'manual' } });
	idleView.onManualFetchLinesChange({ target: { value: '500' } });
	assert.strictEqual(idleCalls, 0, 'idle budget changes must wait for the poll schedule');
	assert.strictEqual(idleView.fetchMode, 'manual');
	assert.strictEqual(idleView.manualFetchLines, 500);
	assert.strictEqual(idleView.readFetchMode(), 'manual');
	assert.match(idle.location.hash, /poll=manual/);
	assert.match(idle.location.hash, /maxraw=500/);

	let release;
	let inFlightCalls = 0;
	const gate = new Promise(function (resolve) {
		release = resolve;
	});
	const inFlight = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				inFlightCalls++;
				await gate;
				return { log: [], adaptive: 1 };
			}
		}
	});
	const inFlightView = inFlight.view;
	inFlightView.updateStreamControlsUi = function () {};
	inFlightView.rpcPreferencesResolved = true;
	inFlightView.setPollCadence(5);
	const current = inFlightView.requestPoll();
	await waitFor(function () { return inFlightCalls === 1; });
	inFlightView.onFetchModeChange({ target: { value: 'manual' } });
	inFlightView.onManualFetchLinesChange({ target: { value: '500' } });
	assert.strictEqual(inFlightCalls, 1, 'in-flight budget changes must not queue a fetch');
	assert.strictEqual(inFlightView.fetchMode, 'manual');
	assert.strictEqual(inFlightView.manualFetchLines, 500);
	assert.strictEqual(inFlightView.readFetchMode(), 'manual');
	assert.match(inFlight.location.hash, /poll=manual/);
	assert.match(inFlight.location.hash, /maxraw=500/);
	release();
	await current;
	assert.strictEqual(inFlightCalls, 1, 'accepted in-flight reply must remain the only request');
	console.log('fwlive-view fetch-budget: budget changes respect cadence OK');
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
	v.tablePaused = true;
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
	v.ensurePollCoordinator().startPolling();
	v.rpcPreferencesResolved = true;
	h.setHidden(true);
	v.onRowLimitChange({ target: { value: '25' } });
	assert.strictEqual(calls, 0, 'hidden Limit change must not fetch immediately');
	h.setHidden(false);
	await waitFor(function () { return calls === 1; });
	assert.strictEqual(calls, 1, 'visible catch-up must fetch once');
	assert.strictEqual(requested, '100', 'catch-up must use the new Auto budget');
	console.log('fwlive-view fetch-budget: hidden Limit change catch-up OK');
}

async function testLimitAndVisibilityDuringInFlightRequest() {
	let release;
	let calls = 0;
	const requested = [];
	const gate = new Promise(function (resolve) {
		release = resolve;
	});
	const oldRow = {
		id: 911,
		time: 1717675742,
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.0.2.1 DST=198.51.100.1 PROTO=TCP SPT=49210 DPT=443'
	};
	const newRow = { ...oldRow, id: 912, time: oldRow.time + 1 };
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function (args) {
				calls++;
				requested.push(args.addresses[0]);
				if (calls === 1) await gate;
				return { log: [calls === 1 ? oldRow : newRow], adaptive: 1 };
			}
		}
	});
	const v = h.view;
	v.rowLimit = 25;
	v.fetchMode = 'auto';
	v.rpcPreferencesResolved = true;
	v.ensurePollCoordinator().startPolling();

	const first = v.requestPoll();
	await waitFor(function () { return calls === 1; });
	assert.strictEqual(calls, 1, 'initial request must be active');
	assert.strictEqual(requested[0], '100', 'initial request must use the old Auto budget');

	v.onRowLimitChange({ target: { value: '500' } });
	h.setHidden(true);
	assert.strictEqual(v.ensurePollCoordinator().getState().disposed, false, 'visibility hide must not dispose coordinator');
	assert.strictEqual(v.ensurePollCoordinator().getState().queued, true, 'Limit refresh must remain queued while hidden');
	release();
	await first;
	assert.strictEqual(calls, 1, 'hidden transition must not start a queued request');
	assert.strictEqual(v.entries.length, 0, 'stale hidden reply must not apply');

	h.setHidden(false);
	await waitFor(function () {
		return calls === 2 && v.entries[0] && v.entries[0].id === 'log:' + newRow.id;
	});
	assert.strictEqual(calls, 2, 'visible transition must perform one catch-up request');
	assert.strictEqual(requested[1], '2000', 'catch-up must use the current Auto budget');
	assert.deepStrictEqual(v.entries.map((row) => row.id), ['log:' + newRow.id]);
	console.log('fwlive-view fetch-budget: Limit plus visibility in-flight lifecycle OK');
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
	v.tablePaused = true;
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
	const row = {
		id: 913,
		time: 1717675742,
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.0.2.1 DST=198.51.100.1 PROTO=TCP SPT=49210 DPT=443'
	};
	const gate = new Promise(function (resolve) {
		release = resolve;
	});
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				calls++;
				await gate;
				return { log: [row], adaptive: 1 };
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
	await waitFor(function () { return calls === 1; });
	assert.strictEqual(calls, 1, 'load must have one active request');
	const queued = v.requestPoll();
	assert.strictEqual(calls, 1, 'second request must be queued before pagehide');
	v.updateStreamControlsUi = function () {};
	v.onPauseClick();
	let statusUpdates = 0;
	v.updateStatus = function () { statusUpdates++; };
	h.dispatchPagehide();
	await queued;
	await loading;
	await sleep(0);
	assert.strictEqual(statusUpdates, 0, 'settled Pause callback must not update the departed view');
	assert.strictEqual(v.pagehideHandler, null, 'pagehide must remove its listener');
	assert.strictEqual(v.ensurePollCoordinator().getState().inFlight, false, 'pagehide must settle active waiters');
	release();
	await sleep(10);
	assert.strictEqual(v.entries.length, 0, 'pagehide must discard a real active reply');
	assert.strictEqual(calls, 1, 'pagehide must not start a queued request');
	await v.requestPoll();
	let lateLoadPreferenceResolutions = 0;
	v.resolveRpcPreferences = function () {
		lateLoadPreferenceResolutions++;
	};
	await v.load();
	assert.strictEqual(
		lateLoadPreferenceResolutions,
		0,
		'late load must not restore preferences after terminal disposal'
	);
	assert.strictEqual(calls, 1, 'disposed coordinator must ignore later poll requests');
	console.log('fwlive-view fetch-budget: pagehide disposal contract OK');
}

async function testPagehideDropsLateStartupUi() {
	let releaseRules;
	let releaseStatus;
	let startupCalls = 0;
	const rulesGate = new Promise(function (resolve) {
		releaseRules = resolve;
	});
	const statusGate = new Promise(function (resolve) {
		releaseStatus = resolve;
	});
	let pollCalls = 0;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.rules': async function () {
				startupCalls++;
				await rulesGate;
				return { rules: {}, backend: 'nft' };
			},
			'fwlive.logging_status': async function () {
				startupCalls++;
				await statusGate;
				return { ready: true, blockers: [], warnings: [] };
			},
			'fwlive.poll': async function () {
				pollCalls++;
				return { log: [], adaptive: 1 };
			}
		}
	});
	const v = h.view;
	v.rulesMap = { sentinel: 'keep' };
	v.firewallBackend = 'iptables';
	v.lastRulesError = 'keep';
	v.loggingStatus = { sentinel: 'keep' };
	v.weakDevice = true;
	v.resolveGeneration = 7;
	let backendUpdates = 0;
	let toolbarUpdates = 0;
	let emptyUpdates = 0;
	let pollRequests = 0;
	const requestPoll = v.requestPoll;
	v.requestPoll = function () {
		pollRequests++;
		return requestPoll.apply(this, arguments);
	};
	v.updateBackendUi = function () { backendUpdates++; };
	v.updateLoggingToolbarUi = function () { toolbarUpdates++; };
	v.updateEmptyStateUi = function () { emptyUpdates++; };
	const loading = v.load();
	await waitFor(function () { return startupCalls === 2; });
	assert.strictEqual(pollCalls, 1, 'initial poll must start before metadata settles');
	h.dispatchPagehide();
	releaseRules();
	releaseStatus();
	await loading;
	const inertRoot = v.render();
	v.addFooter();

	assert.strictEqual(inertRoot.childNodes.length, 0, 'disposed render must be inert');
	assert.deepStrictEqual(v.rulesMap, { sentinel: 'keep' }, 'late rules reply must be ignored');
	assert.strictEqual(v.firewallBackend, 'iptables', 'late rules reply must not change state');
	assert.strictEqual(v.lastRulesError, 'keep', 'late rules error must not change state');
	assert.deepStrictEqual(v.loggingStatus, { sentinel: 'keep' }, 'late status must be ignored');
	assert.strictEqual(v.weakDevice, true, 'late status must not change device state');
	assert.strictEqual(v.resolveGeneration, 8, 'late addFooter must not reset lifecycle state');
	assert.strictEqual(backendUpdates, 0, 'late rules reply must not update backend UI');
	assert.strictEqual(toolbarUpdates, 0, 'late status reply must not update logging UI');
	assert.strictEqual(emptyUpdates, 0, 'late startup replies must not update empty state');
	assert.strictEqual(pollRequests, 0, 'late startup completion must not request a poll');
	assert.strictEqual(pollCalls, 1, 'disposed startup completion must not start another poll');
	console.log('fwlive-view fetch-budget: pagehide drops late startup UI OK');
}

async function testPagehideDropsLateStartupFailures() {
	let rejectRules;
	let rejectStatus;
	let startupCalls = 0;
	const rulesGate = new Promise(function (_, reject) {
		rejectRules = reject;
	});
	const statusGate = new Promise(function (_, reject) {
		rejectStatus = reject;
	});
	let pollCalls = 0;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.rules': async function () {
				startupCalls++;
				await rulesGate;
				return { rules: {} };
			},
			'fwlive.logging_status': async function () {
				startupCalls++;
				await statusGate;
				return { ready: true };
			},
			'fwlive.poll': async function () {
				pollCalls++;
				return { log: [], adaptive: 1 };
			}
		}
	});
	const v = h.view;
	v.rulesMap = { sentinel: 'keep' };
	v.loggingStatus = { sentinel: 'keep' };
	v.weakDevice = true;
	let updates = 0;
	v.updateBackendUi = function () {
		updates++;
	};
	v.updateLoggingToolbarUi = function () {
		updates++;
	};
	v.updateEmptyStateUi = function () {
		updates++;
	};

	const loading = v.load();
	await waitFor(function () { return startupCalls === 2; });
	assert.strictEqual(pollCalls, 1, 'initial poll must start before metadata settles');
	h.dispatchPagehide();
	rejectRules(new Error('late rules failure'));
	rejectStatus(new Error('late status failure'));
	await loading;

	assert.deepStrictEqual(v.rulesMap, { sentinel: 'keep' }, 'late rules failure must be ignored');
	assert.deepStrictEqual(
		v.loggingStatus,
		{ sentinel: 'keep' },
		'late status failure must be ignored'
	);
	assert.strictEqual(v.weakDevice, true, 'late status failure must preserve state');
	assert.strictEqual(updates, 0, 'late startup failures must not update UI');
	assert.strictEqual(pollCalls, 1, 'failed disposed startup must not start another poll');
	console.log('fwlive-view fetch-budget: pagehide drops late startup failures OK');
}

async function testPersistedPagehideKeepsCoordinator() {
	const h = loadFwliveView();
	const v = h.view;
	v.loadRulesMap = function () { return Promise.resolve(); };
	v.loadLoggingStatus = function () { return Promise.resolve(); };
	await v.load();
	const handler = v.pagehideHandler;
	assert.ok(handler, 'load must bind pagehide');
	h.dispatchPagehide({ persisted: true });
	assert.strictEqual(v.pagehideHandler, handler, 'BFCache pagehide keeps the listener');
	assert.strictEqual(
		v.ensurePollCoordinator().getState().disposed,
		false,
		'BFCache pagehide must not dispose the coordinator'
	);
	h.dispatchPagehide({ persisted: false });
	assert.strictEqual(v.pagehideHandler, null, 'ordinary pagehide still disposes the view');
	assert.strictEqual(v.ensurePollCoordinator().getState().disposed, true);
	console.log('fwlive-view fetch-budget: persisted pagehide keeps coordinator OK');
}

async function testPagehideDuringHostnameResolution() {
	let release;
	const gate = new Promise(resolve => { release = resolve; });
	const h = loadFwliveView({ rpcMocks: {
		'fwlive.poll': async function () {
			return { log: [{ id: 914, time: 1717675742,
				msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.0.2.1 DST=198.51.100.1 PROTO=TCP SPT=49210 DPT=443' }] };
		},
		'fwlive.resolve': async function () { return gate; }
	} });
	const v = h.view;
	v.showHostnames = true;
	v.loadRulesMap = v.loadLoggingStatus = () => Promise.resolve();
	const loading = v.load();
	await waitFor(function () { return v.resolveInFlight === true; });
	assert.strictEqual(v.resolveInFlight, true, 'hostname work must be active before disposal');
	let updates = 0;
	v.scheduleRenderRows = v.updateAdaptiveBanner = () => { updates++; };
	h.dispatchPagehide();
	await loading;
	release({ names: { '192.0.2.1': 'late.example' } });
	await sleep(10);
	assert.strictEqual(v.hostnameCache.size, 0, 'late hostname result must not enter the cache');
	assert.strictEqual(updates, 0, 'late hostname result must not update the departed view');
	console.log('fwlive-view fetch-budget: pagehide during hostname resolution OK');
}

async function testRulesThrowKeepsGoodMap() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.rules': async function () {
				throw new Error('Object not found');
			}
		}
	});
	const v = h.view;
	v.rulesMap = { 'wan-drop': 'WAN drop' };
	v.firewallBackend = 'nft';
	v.lastRulesError = null;
	v.updateBackendUi = function () {};
	await v.loadRulesMap();
	assert.deepStrictEqual(v.rulesMap, { 'wan-drop': 'WAN drop' }, 'thrown rules RPC must keep a good map');
	assert.strictEqual(v.lastRulesError, 'rules_unavailable');
	assert.strictEqual(v.firewallBackend, 'nft', 'thrown rules RPC must not reset a known backend');
	console.log('fwlive-view fetch-budget: rules throw keeps good map OK');
}

async function testRulesThrowWipesEmptyMap() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.rules': async function () {
				throw new Error('Object not found');
			}
		}
	});
	const v = h.view;
	v.rulesMap = {};
	v.updateBackendUi = function () {};
	await v.loadRulesMap();
	assert.deepStrictEqual(v.rulesMap, {});
	assert.strictEqual(v.lastRulesError, 'rules_unavailable');
	console.log('fwlive-view fetch-budget: rules throw on empty map stays unavailable OK');
}

async function testPollRetriesRulesFailureAndRepaintsLabels() {
	let rulesCalls = 0;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.rules': async function () {
				rulesCalls++;
				return { rules: { 'wan-drop': 'WAN drop' }, backend: 'nft' };
			},
			'fwlive.poll': async function () {
				return { log: [], adaptive: 1 };
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	v.rulesMap = {};
	v.lastRulesError = 'rules_unavailable';
	v.tablePaused = false;
	v.summaryMode = false;
	v.entries = [{ id: '1', rule_hint: 'wan-drop', rule_label: 'wan drop' }];
	let painted = false;
	v.renderRows = function (force) {
		painted = !!force;
	};
	v.updateBackendUi = function () {};
	v.resolveHostnamesForEntries = async function () {};
	let refreshCalls = 0;
	const refreshLabels = v.refreshBufferedRuleLabels;
	v.refreshBufferedRuleLabels = function () {
		refreshCalls++;
		return refreshLabels.apply(this, arguments);
	};
	await v.runPollRequest(v.currentPollEpoch());
	assert.strictEqual(refreshCalls, 1, 'successful rules recovery must refresh labels exactly once');
	assert.strictEqual(rulesCalls, 1, 'poll must retry rules after a thrown failure');
	assert.strictEqual(v.lastRulesError, null, 'successful rules retry must clear the error');
	assert.strictEqual(v.entries[0].rule_label, 'WAN drop', 'retry must refresh buffered rule labels');
	assert.strictEqual(painted, true, 'label refresh must force a row paint');
	console.log('fwlive-view fetch-budget: poll retries thrown rules RPC OK');
}

async function testRulesSuccessRefreshesLabelsOnce() {
	for (const paused of [false, true]) {
		const h = loadFwliveView({ rpcMocks: {
			'fwlive.rules': async () => ({ rules: { 'wan-drop': 'WAN drop' }, backend: 'nft' })
		} });
		const v = h.view;
		v.tablePaused = paused;
		v.entries = [{ id: '1', rule_hint: 'wan-drop', rule_label: 'old label' }];
		let refreshCalls = 0;
		let paints = 0;
		const refresh = v.refreshBufferedRuleLabels;
		v.refreshBufferedRuleLabels = function () {
			refreshCalls++;
			return refresh.apply(this, arguments);
		};
		v.renderRows = () => { paints++; };
		v.updateBackendUi = () => {};
		await v.loadRulesMap();
		assert.strictEqual(refreshCalls, 1, 'successful rules load refreshes buffered labels once');
		assert.strictEqual(v.entries[0].rule_label, 'WAN drop');
		assert.strictEqual(paints, paused ? 0 : 1, 'paused rows stay current without painting');
	}
}

async function testRulesRetryBackoffIsCapped() {
	let now = 0;
	let rulesCalls = 0;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.rules': async function () {
				rulesCalls++;
				return { rules: {}, error: 'rules_unavailable' };
			},
			'fwlive.poll': async function () {
				return pollReply();
			}
		}
	});
	const v = h.view;
	v.nowMs = function () { return now; };
	v.lastRulesError = 'rules_unavailable';

	await v.fetchEntries();
	assert.strictEqual(rulesCalls, 1, 'the first eligible poll must retry rules');
	assert.strictEqual(v.nextRulesRetryAt, 5000, 'the first failure must wait five seconds');

	for (let expectedCalls = 1; expectedCalls <= 5; expectedCalls++) {
		const deadline = v.nextRulesRetryAt;
		now = deadline - 1;
		await v.fetchEntries();
		assert.strictEqual(rulesCalls, expectedCalls, 'retry must wait until its deadline');
		now = deadline;
		await v.fetchEntries();
		assert.strictEqual(rulesCalls, expectedCalls + 1, 'retry must run when due');
	}

	assert.strictEqual(v.rulesRetryAttempt, 6, 'the retry budget must stop at six failed calls');
	assert.strictEqual(v.nextRulesRetryAt, 0, 'exhausted retries must clear the next deadline');
	now += 60000;
	await v.fetchEntries();
	assert.strictEqual(rulesCalls, 6, 'an exhausted retry budget must not keep probing');
	console.log('fwlive-view fetch-budget: rules retry backoff and cap OK');
}

async function testRulesRetrySkipsPausedAndFailedPolls() {
	let pollFails = false;
	let rulesCalls = 0;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.rules': async function () {
				rulesCalls++;
				return { rules: {}, error: 'rules_unavailable' };
			},
			'fwlive.poll': async function () {
				return pollFails ? { log: [], error: 'filter_failed' } : pollReply();
			}
		}
	});
	const v = h.view;
	v.lastRulesError = 'rules_unavailable';
	v.nextRulesRetryAt = 0;
	v.tablePaused = true;
	await v.fetchEntries();
	assert.strictEqual(rulesCalls, 0, 'paused tables must not trigger rules retries');

	v.tablePaused = false;
	pollFails = true;
	await v.fetchEntries();
	assert.strictEqual(v.lastPollError, true, 'fixture must produce a failed poll');
	assert.strictEqual(rulesCalls, 0, 'failed polls must not trigger rules retries');
	console.log('fwlive-view fetch-budget: rules retry skips paused and failed polls OK');
}

async function main() {
	await testAutoAndManualBudgets();
	await testPollAndResolveWireArguments();
	await testManualSeeding();
	await testHashOrderAndAutoWriteThrough();
	await testFirstRpcUsesResolvedPreferences();
	await testStartupPollFinishesBeforeMetadata();
	await testBudgetControlsAndMetadata();
	await testMalformedEffectiveLimits();
	await testBudgetChangesRespectCadence();
	await testPausedBudgetChangesDoNotFetch();
	await testLimitChangeWhileHiddenUsesVisibleCatchup();
	await testLimitAndVisibilityDuringInFlightRequest();
	await testFillingStopRules();
	await testPagehideDisposesCoordinator();
	await testPagehideDropsLateStartupUi();
	await testPagehideDropsLateStartupFailures();
	await testPersistedPagehideKeepsCoordinator();
	await testPagehideDuringHostnameResolution();
	await testRulesThrowKeepsGoodMap();
	await testRulesThrowWipesEmptyMap();
	await testPollRetriesRulesFailureAndRepaintsLabels();
	await testRulesSuccessRefreshesLabelsOnce();
	await testRulesRetryBackoffIsCapped();
	await testRulesRetrySkipsPausedAndFailedPolls();
	console.log('fwlive-view fetch-budget tests passed');
}

main().catch(function (err) {
	console.error(err.stack || err);
	process.exit(1);
});
