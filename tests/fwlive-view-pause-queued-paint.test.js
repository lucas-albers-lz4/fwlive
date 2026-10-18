#!/usr/bin/env node
'use strict';

/**
 * #1279 — Pause must freeze displayed rows through queued automatic paints.
 */

const assert = require('node:assert/strict');
const { createFwliveView: loadFwliveView, waitFor } = require('./lib/load-fwlive-view');

function fail(msg) {
	console.error(msg);
	process.exit(1);
}

function tbody(h) {
	const el = h.document.getElementById('fwlive-table');
	return el && el.querySelector ? el.querySelector('tbody') : null;
}

function displayedIds(h) {
	const body = tbody(h);
	const ids = [];
	if (!body) return ids;
	for (let i = 0; i < (body.childNodes || []).length; i++) {
		const id = body.childNodes[i]._fwliveRowId;
		if (id != null) ids.push(String(id));
	}
	return ids;
}

function displayedKeys(h) {
	const body = tbody(h);
	const keys = [];
	if (!body) return keys;
	for (let i = 0; i < (body.childNodes || []).length; i++) {
		const key = body.childNodes[i]._fwliveRowKey;
		if (key != null) keys.push(String(key));
	}
	return keys;
}

function dropRow(id, src) {
	return {
		id: 'log:' + id,
		log_id: id,
		timestamp: 1717675740 + id,
		action: 'drop',
		action_raw: 'DROP',
		proto: 'TCP',
		src: src || '192.168.1.' + id,
		dst: '8.8.8.8',
		sport: '49210',
		dport: '443',
		interface_in: 'br-lan',
		interface_out: 'eth0',
		flags: '',
		rule_hint: 'fw4',
		rule_label: 'Firewall4'
	};
}

function pollLog(id) {
	return {
		id: id,
		time: 1717675742 + id,
		msg:
			'fw4: DROP IN=br-lan OUT=eth0 SRC=192.168.1.' +
			id +
			' DST=8.8.8.8 PROTO=TCP SPT=49210 DPT=443'
	};
}

async function testQueuedLivePollFrame() {
	let release;
	const gate = new Promise(function (r) {
		release = r;
	});
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				await gate;
				return { log: [pollLog(2)], adaptive: 1 };
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	v.updateStreamControlsUi = function () {};
	v.entries = [dropRow(1)];
	v.tablePaused = false;
	v.renderRows(true);
	const frozenIds = displayedIds(h);
	const frozenKeys = displayedKeys(h);
	assert.deepStrictEqual(frozenIds, ['log:1'], 'initial paint must show the first row');

	const pending = v.runPollRequest(v.currentPollEpoch());
	release();
	await pending;
	assert.ok(
		v.entries.some(function (e) {
			return String(e.log_id) === '2' || e.id === 'log:2';
		}),
		'poll must ingest the new row into the buffer'
	);
	assert.deepStrictEqual(displayedIds(h), frozenIds, 'queued frame must not paint before flush');

	v.onPauseClick();
	assert.strictEqual(v.tablePaused, true);
	h.flushFrames();
	assert.deepStrictEqual(
		displayedIds(h),
		frozenIds,
		'queued live-poll frame must not repaint after Pause'
	);
	assert.deepStrictEqual(displayedKeys(h), frozenKeys);
	console.log('fwlive-view pause: queued live-poll frame holds OK');
}

async function testQueuedHostnamePaint() {
	const ip = '192.0.2.10';
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return { log: [], adaptive: 1 };
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	v.updateStreamControlsUi = function () {};
	v.showHostnames = true;
	v.hostnameCache = new Map();
	v.entries = [dropRow(1, ip)];
	v.tablePaused = false;
	v.renderRows(true);
	const frozenIds = displayedIds(h);
	const frozenKeys = displayedKeys(h);
	assert.deepStrictEqual(frozenIds, ['log:1'], 'initial paint must show the address row');

	v.hostnameCache.set(ip, 'router.example');
	v.scheduleRenderRows(true);
	v.onPauseClick();
	assert.strictEqual(v.tablePaused, true);
	h.flushFrames();
	assert.deepStrictEqual(
		displayedIds(h),
		frozenIds,
		'queued hostname paint must not add rows after Pause'
	);
	assert.deepStrictEqual(
		displayedKeys(h),
		frozenKeys,
		'queued hostname paint must not rebuild the paused row'
	);
	assert.strictEqual(v.hostnameCache.get(ip), 'router.example');
	console.log('fwlive-view pause: queued hostname paint holds OK');
}

async function testSchedulerRafCallback() {
	const h = loadFwliveView();
	const v = h.view;
	v.updateStreamControlsUi = function () {};
	v.entries = [dropRow(1)];
	v.tablePaused = false;
	v.renderRows(true);
	const frozenIds = displayedIds(h);
	assert.deepStrictEqual(frozenIds, ['log:1']);

	v.entries = [dropRow(1), dropRow(2)];
	v.scheduleRenderRows(true);
	v.tablePaused = true;
	h.flushFrames();
	assert.deepStrictEqual(
		displayedIds(h),
		frozenIds,
		'scheduler rAF callback must honor Pause'
	);
	console.log('fwlive-view pause: scheduler rAF callback holds OK');
}

async function testResumeThenPauseBeforeRpc() {
	let release;
	const gate = new Promise(function (r) {
		release = r;
	});
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				await gate;
				return { log: [pollLog(2)], adaptive: 1 };
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	v.updateStreamControlsUi = function () {};
	v.entries = [dropRow(1)];
	v.tablePaused = true;
	v.renderRows(true);
	const frozenIds = displayedIds(h);
	assert.deepStrictEqual(frozenIds, ['log:1']);

	v.onPauseClick();
	assert.strictEqual(v.tablePaused, false, 'Resume must unpause immediately');
	v.onPauseClick();
	assert.strictEqual(v.tablePaused, true, 'Pause again before RPC returns');
	release();
	await waitFor(function () {
		return !v.ensurePollCoordinator().getState().inFlight;
	});
	h.flushFrames();
	assert.deepStrictEqual(
		displayedIds(h),
		frozenIds,
		'Resume completion must not paint if Pause was pressed again'
	);
	console.log('fwlive-view pause: Resume-then-Pause before RPC holds OK');
}

async function testPausedShowHostnamesTogglePaints() {
	const ip = '192.0.2.10';
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return { log: [], adaptive: 1 };
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	v.updateStreamControlsUi = function () {};
	v.showHostnames = false;
	v.hostnameCache = new Map([[ip, 'router.example']]);
	v.entries = [dropRow(1, ip)];
	v.tablePaused = true;
	v.renderRows(true);
	const keysBefore = displayedKeys(h);

	v.onShowHostnamesChange({ target: { checked: true } });
	const keysAfter = displayedKeys(h);
	assert.notDeepStrictEqual(keysAfter, keysBefore, 'show-hostnames toggle must repaint while paused');
	assert.ok(
		keysAfter.some(function (key) {
			return String(key).indexOf('router.example') >= 0;
		}),
		'repaint must include cached hostname in the painted row key'
	);
	console.log('fwlive-view pause: show-hostnames toggle paints while paused OK');
}

async function testPausedDisplayControlStillPaints() {
	const h = loadFwliveView();
	const v = h.view;
	v.updateStreamControlsUi = function () {};
	v.entries = [dropRow(1), dropRow(2), dropRow(3)];
	v.tablePaused = true;
	v.renderRows(true);
	const ids = displayedIds(h);
	const keys = displayedKeys(h);
	assert.deepStrictEqual(ids, ['log:3', 'log:2', 'log:1']);

	v.setMessageLayout('oneline');
	assert.deepStrictEqual(displayedIds(h), ids, 'paused layout change keeps the same rows');
	assert.notDeepStrictEqual(
		displayedKeys(h),
		keys,
		'paused message-layout change must still rebuild displayed rows'
	);
	console.log('fwlive-view pause: display-control repaint while paused OK');
}

(async function main() {
	try {
		await testQueuedLivePollFrame();
		await testQueuedHostnamePaint();
		await testSchedulerRafCallback();
		await testResumeThenPauseBeforeRpc();
		await testPausedShowHostnamesTogglePaints();
		await testPausedDisplayControlStillPaints();
		console.log('fwlive-view pause queued paint tests passed');
	} catch (e) {
		fail(e && e.stack ? e.stack : String(e));
	}
})();
