#!/usr/bin/env node
'use strict';

/**
 * #306 Layer 2 — visibility pause, poll epoch discard, RTT cadence hysteresis,
 * adaptive:0 gate, resolve disabled:load.
 */

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');
const { loadFwliveModule } = require('./lib/load-fwlive-module');

function fail(msg) {
	console.error(msg);
	process.exit(1);
}

function sleep(ms) {
	return new Promise(function(r) { setTimeout(r, ms); });
}

async function testRttKindHelpers() {
	const h = loadFwliveView();
	const v = h.view;
	const c = loadFwliveModule('constants');
	assert.strictEqual(v.rttKindFromMs(100, false), 'fast');
	assert.strictEqual(v.rttKindFromMs(c.POLL_RTT_FAST_MS, false), 'mid');
	assert.strictEqual(v.rttKindFromMs(c.POLL_RTT_SLOW_MS, false), 'mid');
	assert.strictEqual(v.rttKindFromMs(c.POLL_RTT_SLOW_MS + 1, false), 'slow');
	assert.strictEqual(v.rttKindFromMs(10, true), 'slow');
	assert.strictEqual(v.cadenceForKind('fast'), c.POLL_CADENCE_FAST_S);
	assert.strictEqual(v.cadenceForKind('mid'), c.POLL_CADENCE_MID_S);
	assert.strictEqual(v.cadenceForKind('slow'), c.POLL_CADENCE_SLOW_S);
	console.log('fwlive-view layer2: rtt helpers OK');
}

async function testVisibilityStopsPoll() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() { return { log: [], adaptive: 1 }; },
			'fwlive.resolve': async function() { return { names: {} }; }
		}
	});
	const v = h.view;
	v.bindVisibility();
	v.pollFn = v.pollData.bind(v);
	v.setPollCadence(1);
	h.poll.clearOps();

	h.setHidden(true);
	const ops = h.poll.ops();
	assert.ok(ops.some(function(o) { return o.op === 'remove'; }), 'hidden must remove poll');

	await v.pollData();
	assert.strictEqual(v.pollDataInFlight, false, 'hidden pollData is a no-op');

	h.poll.clearOps();
	h.setHidden(false);
	const ops2 = h.poll.ops();
	assert.ok(ops2.some(function(o) { return o.op === 'add'; }), 'visible must re-add poll');
	console.log('fwlive-view layer2: visibility gate OK');
}

async function testEpochDiscardsStale() {
	let release;
	const gate = new Promise(function(r) { release = r; });
	let calls = 0;
	const row = {
		id: 42,
		time: 1717675742,
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.168.1.150 DST=8.8.8.8 PROTO=TCP SPT=49210 DPT=443'
	};
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				calls++;
				await gate;
				return { log: [row], adaptive: 1 };
			},
			'fwlive.resolve': async function() { return { names: {} }; }
		}
	});
	const v = h.view;
	v.paused = true;
	const p = v.pollData();
	assert.strictEqual(calls, 1);
	const epochAtStart = v.pollEpoch;
	v.bumpPollEpoch();
	assert.notStrictEqual(v.pollEpoch, epochAtStart);
	release();
	await p;
	assert.strictEqual(v.entries.length, 0, 'stale epoch must not apply rows');
	/* Stale finally must NOT clear the guard — resume owns that. */
	assert.strictEqual(v.pollDataInFlight, true, 'stale poll must leave in-flight set');

	/* Control: resume clears the guard then catch-up ingests. */
	h.setRpcMock('fwlive.poll', async function() {
		return { log: [row], adaptive: 1 };
	});
	v.resumePollingAfterVisible();
	await sleep(30);
	assert.ok(v.entries.length >= 1, 'fresh epoch must apply rows');
	console.log('fwlive-view layer2: epoch discard OK');
}

async function testHideShowWhileInFlightNoOverlap() {
	let release1;
	let release2;
	const gate1 = new Promise(function(r) { release1 = r; });
	const gate2 = new Promise(function(r) { release2 = r; });
	let calls = 0;
	const row = {
		id: 99,
		time: 1717675742,
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.168.1.150 DST=8.8.8.8 PROTO=TCP SPT=49210 DPT=443'
	};
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				calls++;
				if (calls === 1) await gate1;
				else await gate2;
				return { log: [row], adaptive: 1 };
			},
			'fwlive.resolve': async function() { return { names: {} }; }
		}
	});
	const v = h.view;
	v.bindVisibility();
	v.pollFn = v.pollData.bind(v);
	v.paused = true;

	const first = v.pollData();
	assert.strictEqual(calls, 1);
	assert.strictEqual(v.pollDataInFlight, true);

	/* Hide while RPC outstanding — bumps epoch; stale must not clear catch-up guard. */
	h.setHidden(true);
	assert.ok(v.pollEpoch >= 1);

	/* Show starts catch-up (2nd poll) while first still gated. */
	h.setHidden(false);
	await sleep(10);
	assert.strictEqual(calls, 2, 'resume catch-up must start a second poll');
	assert.strictEqual(v.pollDataInFlight, true, 'catch-up owns the in-flight guard');

	/* Stale first completes — must not drop catch-up's guard or start another poll. */
	release1();
	await first;
	assert.strictEqual(v.pollDataInFlight, true, 'stale finally must leave catch-up guard set');
	assert.strictEqual(calls, 2, 'stale completion must not start a third poll');

	release2();
	await sleep(30);
	assert.strictEqual(v.pollDataInFlight, false, 'catch-up finally clears its own guard');
	assert.ok(v.entries.length >= 1);
	const ids = {};
	for (let i = 0; i < v.entries.length; i++) ids[v.entries[i].id] = true;
	assert.strictEqual(Object.keys(ids).length, 1, 'must not double-apply the same row from stale+catch-up');
	console.log('fwlive-view layer2: hide/show while in-flight OK');
}

async function testCadenceHysteresis() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() { return { log: [], adaptive: 1 }; },
			'fwlive.resolve': async function() { return { names: {} }; }
		}
	});
	const v = h.view;
	const c = loadFwliveModule('constants');
	v.pollFn = v.pollData.bind(v);
	v.serverAdaptive = 1;
	v.setPollCadence(c.POLL_CADENCE_FAST_S);
	h.poll.clearOps();

	for (let i = 0; i < c.POLL_RTT_STREAK; i++)
		v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);

	assert.strictEqual(v.pollCadenceSec, c.POLL_CADENCE_SLOW_S);
	assert.strictEqual(v.degradedSampling, true);
	assert.ok(h.poll.ops().some(function(o) {
		return o.op === 'add' && o.interval === c.POLL_CADENCE_SLOW_S;
	}));

	v.resetRttHistory();
	for (let i = 0; i < c.POLL_RTT_STREAK; i++)
		v.notePollRtt(50, false);
	assert.strictEqual(v.pollCadenceSec, c.POLL_CADENCE_FAST_S);
	assert.strictEqual(v.degradedSampling, false);
	console.log('fwlive-view layer2: cadence hysteresis OK');
}

async function testAdaptiveOffDisablesBackoff() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return { log: [], adaptive: 0, truncated: 1, shed: { level: 'hot', limit: 250 } };
			},
			'fwlive.resolve': async function() { return { names: {} }; }
		}
	});
	const v = h.view;
	const c = loadFwliveModule('constants');
	v.pollFn = v.pollData.bind(v);
	await v.fetchEntries();
	assert.strictEqual(v.serverAdaptive, 0);
	assert.strictEqual(v.serverTruncated, 1);
	v.notePollRtt(5000, false);
	v.notePollRtt(5000, false);
	v.notePollRtt(5000, false);
	assert.strictEqual(v.pollCadenceSec, c.POLL_CADENCE_FAST_S, 'adaptive:0 keeps 1s');
	assert.strictEqual(v.degradedSampling, false);
	v.updateAdaptiveBanner();
	const el = h.document.getElementById('fwlive-adaptive');
	assert.ok(el);
	assert.strictEqual(el.style.display, 'none', 'adaptive:0 hides banner');
	console.log('fwlive-view layer2: adaptive:0 gate OK');
}

async function testResolveLoadShed() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() { return { log: [], adaptive: 1 }; },
			'fwlive.resolve': async function() {
				return { names: {}, disabled: 'load' };
			}
		}
	});
	const v = h.view;
	v.showHostnames = true;
	v.hostnameCache = new Map();
	v.hostnameFailed = new Map();
	await v.resolveHostnamesForEntries([
		{ id: '1', src: '192.0.2.1', dst: '198.51.100.1' }
	]);
	assert.strictEqual(v.resolveLoadShed, true);
	assert.strictEqual(v.hostnameCache.size, 0, 'must not cache names on load shed');
	assert.strictEqual(v.hostnameFailed.size, 0, 'must not mark DNS fails on load shed');
	console.log('fwlive-view layer2: resolve disabled:load OK');
}

async function testShedSurfacing() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return {
					log: [],
					adaptive: 1,
					truncated: 1,
					shed: { level: 'hot', limit: 250 }
				};
			},
			'fwlive.resolve': async function() { return { names: {} }; }
		}
	});
	const v = h.view;
	await v.fetchEntries();
	assert.strictEqual(v.serverTruncated, 1);
	assert.strictEqual(v.serverShed.limit, 250);
	v.degradedSampling = true;
	v.updateAdaptiveBanner();
	const el = h.document.getElementById('fwlive-adaptive');
	assert.strictEqual(el.style.display, 'block');
	assert.ok(String(el.textContent).indexOf('250') >= 0, 'banner must show the shed limit');
	console.log('fwlive-view layer2: shed surfacing OK');
}

async function testStreakResetOnAdaptiveOff() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() { return { log: [], adaptive: 1 }; },
			'fwlive.resolve': async function() { return { names: {} }; }
		}
	});
	const v = h.view;
	const c = loadFwliveModule('constants');
	v.pollFn = v.pollData.bind(v);
	v.serverAdaptive = 1;
	v.setPollCadence(c.POLL_CADENCE_FAST_S);
	h.poll.clearOps();

	/* Two slow samples: below the N=3 streak, no trip. */
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	assert.strictEqual(v.pollCadenceSec, c.POLL_CADENCE_FAST_S);

	/* adaptive:0 window must drop the partial streak. */
	v.serverAdaptive = 0;
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	assert.strictEqual(v.rttStreakCount, 0);

	/* Re-enable: two slows must still not trip; the third does. */
	v.serverAdaptive = 1;
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	assert.strictEqual(v.pollCadenceSec, c.POLL_CADENCE_FAST_S);
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	assert.strictEqual(v.pollCadenceSec, c.POLL_CADENCE_SLOW_S);
	console.log('fwlive-view layer2: adaptive:0 streak reset OK');
}


async function testResolveShedCooldown() {
	let calls = 0;
	let shed = true;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() { return { log: [], adaptive: 1 }; },
			'fwlive.resolve': async function() {
				calls++;
				return shed ? { names: {}, disabled: 'load' } : { names: {} };
			}
		}
	});
	const v = h.view;
	v.showHostnames = true;
	v.hostnameCache = new Map();
	v.hostnameFailed = new Map();
	const entries = [{ id: '1', src: '192.0.2.1', dst: '198.51.100.1' }];
	await v.resolveHostnamesForEntries(entries);
	assert.strictEqual(v.resolveLoadShed, true);
	assert.strictEqual(calls, 1);

	/* Cooldown: same poll must not re-ask while the router sheds load. */
	await v.resolveHostnamesForEntries(entries);
	assert.strictEqual(calls, 1, 'shed cooldown must skip resolve retry');

	/* After cooldown with a healthy reply, shed clears. */
	shed = false;
	v.resolveShedUntil = Date.now() - 1;
	await v.resolveHostnamesForEntries(entries);
	assert.strictEqual(calls, 2);
	assert.strictEqual(v.resolveLoadShed, false);
	console.log('fwlive-view layer2: resolve shed cooldown OK');
}


(async function main() {
	try {
		await testRttKindHelpers();
		await testVisibilityStopsPoll();
		await testEpochDiscardsStale();
		await testHideShowWhileInFlightNoOverlap();
		await testCadenceHysteresis();
		await testAdaptiveOffDisablesBackoff();
		await testResolveLoadShed();
		await testShedSurfacing();
		await testStreakResetOnAdaptiveOff();
		await testResolveShedCooldown();
		await sleep(20);
		console.log('fwlive-view layer2 backoff tests passed');
	} catch (e) {
		fail(e && e.stack ? e.stack : String(e));
	}
})();
