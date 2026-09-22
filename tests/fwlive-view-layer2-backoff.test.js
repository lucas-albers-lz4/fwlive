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
	return new Promise(function (r) {
		setTimeout(r, ms);
	});
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

async function testWeakDeviceDisplayCap() {
	let rejectStatus = false;
	let status = { weak_device: true, ready: true, blockers: [], warnings: [] };
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.logging_status': async function () {
				if (rejectStatus) throw new Error('logging status unavailable');
				return status;
			}
		}
	});
	const v = h.view;
	v.updateBackendUi = function () {};
	v.updateLoggingToolbarUi = function () {};
	v.updateEmptyStateUi = function () {};
	v.applyRowLimit(2000);
	v.entries = Array.from({ length: 1000 }, function (_, i) {
		return { id: i + 1, msg: 'fw4: ACCEPT IN=wan SRC=192.0.2.1' };
	});
	await v.loadLoggingStatus();
	assert.strictEqual(v.weakDevice, true);
	assert.strictEqual(v.displayRowCap(), 250);
	assert.strictEqual(v.filteredRows().length, 250);
	assert.match(v.statusSuffix(), /Display limited to 250 rows on this device/);

	status = { weak_device: false, ready: true, blockers: [], warnings: [] };
	await v.loadLoggingStatus();
	assert.strictEqual(v.weakDevice, false);
	assert.strictEqual(v.displayRowCap(), 2000);
	assert.strictEqual(v.filteredRows().length, 1000);

	status = { ready: true, blockers: [], warnings: [] };
	await v.loadLoggingStatus();
	assert.strictEqual(v.weakDevice, false, 'missing weak-device flag must not enable the cap');
	assert.strictEqual(v.displayRowCap(), 2000);

	status = { weak_device: 'true', ready: true, blockers: [], warnings: [] };
	await v.loadLoggingStatus();
	assert.strictEqual(v.weakDevice, false, 'string weak-device flag must not enable the cap');
	assert.strictEqual(v.displayRowCap(), 2000);

	status = { weak_device: true, ready: true, blockers: [], warnings: [] };
	await v.loadLoggingStatus();
	assert.strictEqual(v.weakDevice, true);
	assert.strictEqual(v.displayRowCap(), 250);

	rejectStatus = true;
	await v.loadLoggingStatus();
	assert.strictEqual(v.weakDevice, true, 'status failure must preserve weak-device state');
	assert.strictEqual(v.displayRowCap(), 250, 'status failure must preserve the display cap');
	assert.strictEqual(v.filteredRows().length, 250);
	console.log('fwlive-view layer2: weak-device display cap OK');
}

async function testVisibilityStopsPoll() {
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
	v.ensurePollCoordinator().startPolling();
	v.setPollCadence(1);
	h.poll.clearOps();

	h.setHidden(true);
	const ops = h.poll.ops();
	assert.ok(
		ops.some(function (o) {
			return o.op === 'remove';
		}),
		'hidden must remove poll'
	);

	await v.requestPoll();
	assert.strictEqual(v.ensurePollCoordinator().getState().inFlight, false, 'hidden request is a no-op');

	h.poll.clearOps();
	h.setHidden(false);
	const ops2 = h.poll.ops();
	assert.ok(
		ops2.some(function (o) {
			return o.op === 'add';
		}),
		'visible must re-add poll'
	);
	console.log('fwlive-view layer2: visibility gate OK');
}

async function testEpochDiscardsStale() {
	let release;
	const gate = new Promise(function (r) {
		release = r;
	});
	let calls = 0;
	const row = {
		id: 42,
		time: 1717675742,
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.168.1.150 DST=8.8.8.8 PROTO=TCP SPT=49210 DPT=443'
	};
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				calls++;
				await gate;
				return { log: [row], adaptive: 1 };
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	v.tablePaused = true;
	const p = v.requestPoll();
	assert.strictEqual(calls, 1);
	const epochAtStart = v.currentPollEpoch();
	v.ensurePollCoordinator().startPolling();
	h.setHidden(true);
	assert.notStrictEqual(v.currentPollEpoch(), epochAtStart);
	release();
	await p;
	assert.strictEqual(v.entries.length, 0, 'stale epoch must not apply rows');
	/* The stale request is still the only request, so its completion releases
	 * the coordinator. A later visible catch-up can then start normally. */
	assert.strictEqual(v.ensurePollCoordinator().getState().inFlight, false, 'completed stale poll must release the guard');

	/* Control: visible catch-up ingests. */
	h.setRpcMock('fwlive.poll', async function () {
		return { log: [row], adaptive: 1 };
	});
	h.setHidden(false);
	await sleep(30);
	assert.ok(v.entries.length >= 1, 'fresh epoch must apply rows');
	console.log('fwlive-view layer2: epoch discard OK');
}

async function testHideShowWhileInFlightNoOverlap() {
	let release1;
	let release2;
	const gate1 = new Promise(function (r) {
		release1 = r;
	});
	const gate2 = new Promise(function (r) {
		release2 = r;
	});
	let calls = 0;
	const row = {
		id: 99,
		time: 1717675742,
		msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.168.1.150 DST=8.8.8.8 PROTO=TCP SPT=49210 DPT=443'
	};
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				calls++;
				if (calls === 1) await gate1;
				else await gate2;
				return { log: [row], adaptive: 1 };
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	v.ensurePollCoordinator().startPolling();
	v.tablePaused = true;

	const first = v.requestPoll();
	assert.strictEqual(calls, 1);
	assert.strictEqual(v.ensurePollCoordinator().getState().inFlight, true);

	/* Hide while RPC outstanding — bumps epoch; stale must not clear catch-up guard. */
	h.setHidden(true);
	assert.ok(v.currentPollEpoch() >= 1);

	/* Show queues catch-up while the first request is still gated. */
	h.setHidden(false);
	await sleep(10);
	assert.strictEqual(calls, 1, 'resume catch-up must not overlap the hidden request');
	assert.strictEqual(v.ensurePollCoordinator().getState().inFlight, true, 'hidden request retains the in-flight guard');

	/* Stale first completes — the queued catch-up may now start. */
	release1();
	await first;
	assert.strictEqual(v.ensurePollCoordinator().getState().inFlight, true, 'queued catch-up owns the in-flight guard');
	assert.strictEqual(calls, 2, 'stale completion must start the queued catch-up');

	release2();
	await sleep(30);
	assert.strictEqual(v.ensurePollCoordinator().getState().inFlight, false, 'catch-up finally clears its own guard');
	assert.ok(v.entries.length >= 1);
	const ids = {};
	for (let i = 0; i < v.entries.length; i++) ids[v.entries[i].id] = true;
	assert.strictEqual(
		Object.keys(ids).length,
		1,
		'must not double-apply the same row from stale+catch-up'
	);
	console.log('fwlive-view layer2: hide/show while in-flight OK');
}

async function testRefreshTriggersSerialize() {
	const gates = [];
	const releases = [];
	for (let i = 0; i < 3; i++) {
		gates.push(
			new Promise(function (resolve) {
				releases.push(resolve);
			})
		);
	}
	let calls = 0;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				const n = calls++;
				await gates[n];
				return { log: [], adaptive: 1 };
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	v.updateStreamControlsUi = function () {};
	v.updateStatus = function () {};
	v.renderRows = function () {};
	v.updateHash = function () {};
	v.saveRowLimit = function () {};
	v.tablePaused = false;

	const first = v.requestPoll();
	v.onPauseClick();
	v.onRowLimitChange({ target: { value: '50' } });
	assert.strictEqual(calls, 1, 'Pause and Limit must not overlap the active request');

	releases[0]();
	await first;
	await sleep(10);
	assert.strictEqual(calls, 2, 'Pause and Limit must coalesce into one follow-up');

	/* Resume arrives while the queued follow-up is active. */
	v.onPauseClick();
	assert.strictEqual(calls, 2, 'Resume must also queue behind the active request');
	releases[1]();
	await sleep(10);
	assert.strictEqual(calls, 3, 'Resume must start only after the prior request completes');
	releases[2]();
	await sleep(20);
	assert.strictEqual(v.ensurePollCoordinator().getState().inFlight, false, 'all serialized requests must settle');

	/* Startup uses the same coordinator entry point. */
	const h2 = loadFwliveView();
	const v2 = h2.view;
	let startupRequests = 0;
	v2.loadRulesMap = function () {
		return Promise.resolve();
	};
	v2.loadLoggingStatus = function () {
		return Promise.resolve();
	};
	v2.requestPoll = function () {
		startupRequests++;
		return Promise.resolve();
	};
	await v2.load();
	assert.strictEqual(startupRequests, 1, 'startup must use the coordinator');
	console.log('fwlive-view layer2: refresh triggers serialize OK');
}

async function testCadenceHysteresis() {
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
	const c = loadFwliveModule('constants');
	v.ensurePollCoordinator().startPolling();
	v.serverAdaptive = 1;
	v.setPollCadence(c.POLL_CADENCE_FAST_S);
	h.poll.clearOps();

	for (let i = 0; i < c.POLL_RTT_STREAK; i++) v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);

	assert.strictEqual(v.ensurePollCoordinator().getState().cadenceSec, c.POLL_CADENCE_SLOW_S);
	assert.strictEqual(v.degradedSampling, true);
	assert.ok(
		h.poll.ops().some(function (o) {
			return o.op === 'add' && o.interval === c.POLL_CADENCE_SLOW_S;
		})
	);

	v.resetRttHistory();
	for (let i = 0; i < c.POLL_RTT_STREAK; i++) v.notePollRtt(50, false);
	assert.strictEqual(v.ensurePollCoordinator().getState().cadenceSec, c.POLL_CADENCE_FAST_S);
	assert.strictEqual(v.degradedSampling, false);
	console.log('fwlive-view layer2: cadence hysteresis OK');
}

async function testAdaptiveOffDisablesBackoff() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return { log: [], adaptive: 0, truncated: 1, shed: { level: 'hot', limit: 250 } };
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	const c = loadFwliveModule('constants');
	v.ensurePollCoordinator().startPolling();
	await v.fetchEntries();
	assert.strictEqual(v.serverAdaptive, 0);
	assert.strictEqual(v.serverTruncated, 1);
	v.notePollRtt(5000, false);
	v.notePollRtt(5000, false);
	v.notePollRtt(5000, false);
	assert.strictEqual(v.ensurePollCoordinator().getState().cadenceSec, c.POLL_CADENCE_FAST_S, 'adaptive:0 keeps 1s');
	assert.strictEqual(v.degradedSampling, false);
	v.updateAdaptiveBanner();
	const el = h.document.getElementById('fwlive-adaptive');
	assert.ok(el);
	assert.strictEqual(el.style.display, 'block', 'adaptive:0 states protection is disabled');
	assert.match(el.textContent, /protection is disabled/i);
	console.log('fwlive-view layer2: adaptive:0 gate OK');
}

async function testResolveLoadShed() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return { log: [], adaptive: 1 };
			},
			'fwlive.resolve': async function () {
				return { names: {}, disabled: 'load' };
			}
		}
	});
	const v = h.view;
	v.showHostnames = true;
	v.hostnameCache = new Map();
	v.hostnameFailed = new Map();
	await v.resolveHostnamesForEntries([{ id: '1', src: '192.0.2.1', dst: '198.51.100.1' }]);
	assert.strictEqual(v.resolveLoadShed, true);
	assert.strictEqual(v.hostnameCache.size, 0, 'must not cache names on load shed');
	assert.strictEqual(v.hostnameFailed.size, 0, 'must not mark DNS fails on load shed');
	console.log('fwlive-view layer2: resolve disabled:load OK');
}

async function testResolveReplyShapes() {
	const h = loadFwliveView();
	const v = h.view;
	assert.deepStrictEqual(
		v.resolveNamesFromReply({ names: { '192.0.2.1': 'router.example' } }),
		{ '192.0.2.1': 'router.example' }
	);
	assert.deepStrictEqual(
		v.resolveNamesFromReply({ '198.51.100.1': 'host.example' }),
		{ '198.51.100.1': 'host.example' }
	);
	assert.strictEqual(v.resolveNamesFromReply(null), null);
	assert.strictEqual(v.resolveNamesFromReply([]), null);
	console.log('fwlive-view layer2: resolve reply shapes OK');
}

async function testWarmHostnameTogglePaintsCache() {
	const h = loadFwliveView();
	const v = h.view;
	const ip = '192.0.2.1';
	const renders = [];
	let resolves = 0;
	v.entries = [{ id: 'warm', src: ip, dst: '198.51.100.1' }];
	v.hostnameCache = new Map([[ip, 'router.example']]);
	v.hostnameFailed = new Map();
	v.renderRows = function (force) { renders.push(force); };
	v.resolveHostnamesForEntries = function () {
		resolves++;
		return Promise.resolve();
	};

	v.onShowHostnamesChange({ target: { checked: false } });
	assert.deepStrictEqual(renders, [true], 'turning names off must repaint');
	renders.length = 0;
	v.onShowHostnamesChange({ target: { checked: true } });
	assert.deepStrictEqual(
		renders,
		[true],
		'turning names on must repaint immediately from the warm cache'
	);
	assert.strictEqual(resolves, 1, 'toggle-on must still resolve cache misses');
	console.log('fwlive-view layer2: warm hostname toggle paints cache OK');
}

async function testShedSurfacing() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return {
					log: [],
					adaptive: 1,
					truncated: 1,
					shed: { level: 'hot', limit: 250 }
				};
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
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

async function testSummaryFallbackAndRecovery() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return {
					log: [],
					adaptive: 1,
					summary: {
						scope: 'top of shown sample',
						top_talkers: [{ value: '203.0.113.1', count: 2 }],
						top_drops: [{ value: 'drop', count: 2 }],
						top_rules: []
					}
				};
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	let clock = 0;
	v.nowMs = function () {
		clock += 1601;
		return clock;
	};
	await v.fetchEntries();
	assert.strictEqual(v.summaryMode, true, 'first slow RTT must enter summary mode');
	assert.strictEqual(h.document.getElementById('fwlive-summary').style.display, 'block');
	assert.strictEqual(h.document.getElementById('fwlive-scroll').style.display, 'none');
	assert.ok(
		h.document.getElementById('fwlive-summary-body').textContent.indexOf('203.0.113.1') >= 0
	);

	let renders = 0;
	v.renderRows = function () {
		renders++;
	};
	v.entries = [{ id: '1', src: '203.0.113.1', dst: '198.51.100.1' }];
	const emptyEl = h.document.getElementById('fwlive-empty');
	emptyEl.style.display = 'none';
	v.tablePaused = true;
	for (let i = 0; i < 3; i++) v.notePollRtt(50, false);
	assert.strictEqual(v.summaryMode, false, 'three fast RTTs must restore rows');
	assert.strictEqual(renders, 0, 'summary recovery must not reveal rows while paused');
	assert.strictEqual(h.document.getElementById('fwlive-summary').style.display, 'none');
	assert.strictEqual(
		emptyEl.style.display,
		'none',
		'empty panel must stay hidden when filtered rows exist while paused'
	);
	console.log('fwlive-view layer2: summary fallback/recovery OK');
}

async function testStreakResetOnAdaptiveOff() {
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
	const c = loadFwliveModule('constants');
	v.ensurePollCoordinator().startPolling();
	v.serverAdaptive = 1;
	v.setPollCadence(c.POLL_CADENCE_FAST_S);
	h.poll.clearOps();

	/* Two slow samples: below the N=3 streak, no trip. */
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	assert.strictEqual(v.ensurePollCoordinator().getState().cadenceSec, c.POLL_CADENCE_FAST_S);

	/* adaptive:0 window must drop the partial streak. */
	v.serverAdaptive = 0;
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	assert.strictEqual(v.rttStreakCount, 0);

	/* Re-enable: two slows must still not trip; the third does. */
	v.serverAdaptive = 1;
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	assert.strictEqual(v.ensurePollCoordinator().getState().cadenceSec, c.POLL_CADENCE_FAST_S);
	v.notePollRtt(c.POLL_RTT_SLOW_MS + 50, false);
	assert.strictEqual(v.ensurePollCoordinator().getState().cadenceSec, c.POLL_CADENCE_SLOW_S);
	console.log('fwlive-view layer2: adaptive:0 streak reset OK');
}

async function testResolveShedCooldown() {
	let calls = 0;
	let shed = true;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return { log: [], adaptive: 1 };
			},
			'fwlive.resolve': async function () {
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

async function testResolveRpcErrorNoFailMark() {
	for (const code of ['no_resolver', 'jshn_missing']) {
		const h = loadFwliveView({
			rpcMocks: {
				'fwlive.poll': async function () {
					return { log: [], adaptive: 1 };
				},
				'fwlive.resolve': async function () {
					return { names: {}, error: code };
				}
			}
		});
		const v = h.view;
		v.showHostnames = true;
		v.hostnameCache = new Map();
		v.hostnameFailed = new Map();
		await v.resolveHostnamesForEntries([{ id: '1', src: '192.0.2.1', dst: '198.51.100.1' }]);
		assert.strictEqual(v.resolveLoadShed, false, code + ': rpc error is not load shed');
		assert.strictEqual(
			v.hostnameFailed.size,
			0,
			code + ': must not mark DNS fails on rpc error'
		);
		assert.strictEqual(v.hostnameCache.size, 0, code + ': must not cache names on rpc error');
	}
	console.log('fwlive-view layer2: resolve rpc error OK');
}

async function testResolveTruncatedNoFailMark() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return { log: [], adaptive: 1 };
			},
			'fwlive.resolve': async function () {
				return {
					names: { '192.0.2.1': 'one.example', '198.51.100.1': '' },
					truncated: true
				};
			}
		}
	});
	const v = h.view;
	v.showHostnames = true;
	v.hostnameCache = new Map();
	v.hostnameFailed = new Map();
	await v.resolveHostnamesForEntries([
		{ id: '1', src: '192.0.2.1', dst: '198.51.100.1' },
		{ id: '2', src: '203.0.113.1', dst: '192.0.2.1' }
	]);
	assert.strictEqual(v.hostnameCache.get('192.0.2.1'), 'one.example');
	assert.strictEqual(
		v.hostnameFailed.has('198.51.100.1'),
		true,
		'truncated NXDOMAIN that was looked up must be fail-marked'
	);
	assert.strictEqual(
		v.hostnameFailed.has('203.0.113.1'),
		false,
		'truncated remainder must stay retryable'
	);
	assert.strictEqual(v.hostnameCache.has('198.51.100.1'), false);
	assert.strictEqual(v.hostnameCache.has('203.0.113.1'), false);
	console.log('fwlive-view layer2: resolve truncated reply OK');
}

async function testResumeStaleSkipsRender() {
	async function run(stale) {
		let release;
		const gate = new Promise(function (r) {
			release = r;
		});
		const h = loadFwliveView({
			rpcMocks: {
				'fwlive.poll': async function () {
					await gate;
					return { log: [], adaptive: 1 };
				},
				'fwlive.resolve': async function () {
					return { names: {} };
				}
			}
		});
		const v = h.view;
		v.updateStreamControlsUi = function () {};
		let renders = 0;
		v.renderRows = function () {
			renders++;
		};
		v.tablePaused = true;
		v.onPauseClick();
		v.ensurePollCoordinator().startPolling();
		if (stale) h.setHidden(true);
		release();
		await sleep(20);
		return renders;
	}
	assert.strictEqual(await run(true), 0, 'stale resume completion must not paint');
	assert.strictEqual(await run(false), 1, 'fresh resume completion must paint');
	console.log('fwlive-view layer2: stale resume render guard OK');
}

async function testResumeMergeSurvivesVisibilityRace() {
	async function run(staleFirst) {
		let releaseResume;
		let releaseCatchup;
		const resumeGate = new Promise(function (r) {
			releaseResume = r;
		});
		const catchupGate = new Promise(function (r) {
			releaseCatchup = r;
		});
		let calls = 0;
		const h = loadFwliveView({
			rpcMocks: {
				'fwlive.poll': async function () {
					calls++;
					if (calls === 1) await resumeGate;
					else await catchupGate;
					return {
						log: [
							{
								id: calls,
								time: 1717675742 + calls,
								msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.168.1.150 DST=8.8.8.8 PROTO=TCP SPT=49210 DPT=443'
							}
						],
						adaptive: 1
					};
				},
				'fwlive.resolve': async function () {
					return { names: {} };
				}
			}
		});
		const v = h.view;
		v.updateStreamControlsUi = function () {};
		v.entries = [{ id: 'pause-only', log_id: 0, timestamp: 1 }];
		v.tablePaused = true;
		v.ensurePollCoordinator().startPolling();

		/* Resume starts the first request with the pause-buffer merge obligation. */
		v.onPauseClick();
		assert.strictEqual(calls, 1);
		assert.strictEqual(v.resumeMerge, true);

		/* Hide/show abandons the first epoch and queues catch-up behind it. */
		h.setHidden(true);
		h.setHidden(false);
		await sleep(10);
		assert.strictEqual(calls, 1, 'visibility catch-up must not overlap resume request');

		releaseResume();
		await sleep(20);
		assert.strictEqual(calls, 2, 'queued visibility catch-up must start after resume request');
		assert.strictEqual(v.resumeMerge, true, 'stale completion must preserve merge obligation');
		releaseCatchup();

		await sleep(30);
		assert.strictEqual(
			v.resumeMerge,
			false,
			'current catch-up clears applied merge obligation'
		);
		assert.ok(
			v.entries.some(function (e) {
				return e.id === 'pause-only';
			}),
			'successful resume/catch-up must retain pause-only rows'
		);
	}

	await run(true);
	await run(false);
	console.log('fwlive-view layer2: resume merge visibility race OK');
}

async function testUnpauseDuringPausedPollRetainsBuffer() {
	let releaseFirst;
	let releaseCatchup;
	const firstGate = new Promise(function (r) {
		releaseFirst = r;
	});
	const catchupGate = new Promise(function (r) {
		releaseCatchup = r;
	});
	let calls = 0;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				calls++;
				if (calls === 1) await firstGate;
				if (calls === 2) await catchupGate;
				return {
					log: [
						{
							id: calls,
							time: 1717675742 + calls,
							msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.168.1.150 DST=8.8.8.8 PROTO=TCP SPT=49210 DPT=443'
						}
					],
					adaptive: 1
				};
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	v.updateStreamControlsUi = function () {};
	v.rowLimit = 2;
	v.entries = [
		{ id: 'pause-only-old', log_id: 0, timestamp: 1 },
		{ id: 'pause-only-new', log_id: 1, timestamp: 2 }
	];
	v.tablePaused = true;
	v.ensurePollCoordinator().startPolling();

	const first = v.requestPoll();
	await sleep(10);
	assert.strictEqual(calls, 1, 'paused poll must be active before unpause');

	v.onPauseClick();
	assert.strictEqual(v.tablePaused, false, 'unpause must change the table state immediately');
	releaseFirst();
	await first;
	await sleep(20);
	assert.strictEqual(calls, 2, 'unpause must leave one queued catch-up poll');
	assert.ok(
		v.entries.some(function (e) {
			return e.id === 'pause-only-new';
		}),
		'poll started while paused must retain its buffer rows after unpause'
	);
	assert.ok(v.entries.length <= v.rowLimit, 'live row limit must apply after unpause');

	releaseCatchup();
	await sleep(20);
	assert.strictEqual(v.resumeMerge, false, 'catch-up poll must clear resumeMerge');
	assert.ok(
		v.entries.some(function (e) {
			return e.id === 'log:2';
		}),
		'catch-up poll must apply its live rows'
	);
	console.log('fwlive-view layer2: unpause during paused poll retains buffer OK');
}

async function testPauseDuringLivePollRetainsBuffer() {
	let releaseFirst;
	let releaseCatchup;
	const firstGate = new Promise(function (r) {
		releaseFirst = r;
	});
	const catchupGate = new Promise(function (r) {
		releaseCatchup = r;
	});
	let calls = 0;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				calls++;
				if (calls === 1) await firstGate;
				if (calls === 2) await catchupGate;
				return {
					log: [
						{
							id: calls,
							time: 1717675742 + calls,
							msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=192.168.1.150 DST=8.8.8.8 PROTO=TCP SPT=49210 DPT=443'
						}
					],
					adaptive: 1
				};
			},
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const v = h.view;
	v.updateStreamControlsUi = function () {};
	v.entries = [{ id: 'live-only', log_id: 0, timestamp: 1 }];
	v.tablePaused = false;
	v.ensurePollCoordinator().startPolling();

	const first = v.requestPoll();
	await sleep(10);
	assert.strictEqual(calls, 1, 'live poll must be active before pause');

	v.onPauseClick();
	assert.strictEqual(v.tablePaused, true, 'pause must change the table state immediately');
	releaseFirst();
	await first;
	await sleep(20);
	assert.strictEqual(calls, 2, 'pause must leave one queued catch-up poll');
	assert.ok(
		v.entries.some(function (e) {
			return e.id === 'live-only';
		}),
		'poll started while live must retain its existing rows after pause'
	);
	assert.ok(
		v.entries.some(function (e) {
			return e.id === 'log:1';
		}),
		'poll started while live must apply its new rows after pause'
	);

	releaseCatchup();
	await sleep(20);
	console.log('fwlive-view layer2: pause during live poll retains buffer OK');
}

async function testStaleAnimationFrameIsDropped() {
	const frames = [];
	const h = loadFwliveView({
		requestAnimationFrame: function (fn) {
			frames.push(fn);
			return frames.length;
		},
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
	let renders = 0;
	v.renderRows = function () {
		renders++;
	};

	v.scheduleRenderRows(true);
	assert.strictEqual(frames.length, 1);
	v.ensurePollCoordinator().startPolling();
	h.setHidden(true);
	frames.shift()();
	assert.strictEqual(renders, 0, 'old visibility epoch must not paint');

	/* A current-epoch request after the stale callback still gets a frame. */
	v.scheduleRenderRows(true);
	assert.strictEqual(frames.length, 1);
	frames.shift()();
	assert.strictEqual(renders, 1, 'current epoch must still paint');

	/* If the new request arrives before the old callback, requeue it. */
	v.scheduleRenderRows(true);
	h.setHidden(false);
	v.scheduleRenderRows(false);
	frames.shift()();
	assert.strictEqual(renders, 1, 'stale callback must not paint queued rows');
	assert.strictEqual(frames.length, 1, 'current request must be requeued');
	frames.shift()();
	assert.strictEqual(renders, 2);
	v.scheduleRenderRows(true);
	v.disposeView();
	frames.shift()();
	assert.strictEqual(renders, 2, 'disposed view must drop pending paint');
	console.log('fwlive-view layer2: stale animation frame guard OK');
}

async function testAnimationFrameAdaptersPreserveWindowReceiver() {
	const frames = [];
	let requestReceiver = null;
	let cancelReceiver = null;
	const h = loadFwliveView({
		requestAnimationFrame: function (fn) {
			requestReceiver = this;
			frames.push(fn);
			return 42;
		},
		cancelAnimationFrame: function (id) {
			cancelReceiver = this;
			assert.strictEqual(id, 42);
		}
	});

	h.view.scheduleRenderRows(true);
	h.view.disposeView();
	assert.strictEqual(
		requestReceiver,
		h.window,
		'requestAnimationFrame must keep window as receiver'
	);
	assert.strictEqual(
		cancelReceiver,
		h.window,
		'cancelAnimationFrame must keep window as receiver'
	);
	assert.strictEqual(frames.length, 1);
	console.log('fwlive-view layer2: animation-frame adapters preserve window receiver OK');
}

async function testLimitRefreshPreservesQueuedForce() {
	const frames = [];
	const h = loadFwliveView({ requestAnimationFrame: (fn) => {
		frames.push(fn);
		return frames.length;
	} });
	const v = h.view;
	const renders = [];
	v.renderRows = (force) => renders.push(force);
	v.requestPoll = () =>
		Promise.resolve().then(() => {
			/* Model hostname resolution queuing a forced repaint before the
			 * refresh completion cleanup runs. */
			v.scheduleRenderRows(true);
		});

	v.scheduleRenderRows(false);
	v.onRowLimitChange({ target: { value: '500' } });
	assert.deepStrictEqual(renders, [true], 'Limit paints the current buffer immediately');
	await sleep(0);
	assert.deepStrictEqual(renders, [true, true], 'Limit paints again after refresh');
	frames.shift()();
	assert.deepStrictEqual(
		renders,
		[true, true, true],
		'Limit cleanup cannot erase a force queued before cleanup'
	);
	console.log('fwlive-view layer2: Limit preserves queued force OK');
}

async function testLimitPaintDoesNotWaitForHostnames() {
	const frames = [];
	const h = loadFwliveView({ requestAnimationFrame: (fn) => {
		frames.push(fn);
		return frames.length;
	} });
	const v = h.view;
	const renders = [];
	let releaseNames;
	let resolving = false;
	const names = new Promise(resolve => { releaseNames = resolve; });
	v.fetchEntries = async () => {};
	v.resolveHostnamesForEntries = () => {
		resolving = true;
		return names;
	};
	v.renderRows = (force) => renders.push(force);
	const requestPoll = v.requestPoll.bind(v);
	let refresh;
	v.requestPoll = () => { refresh = requestPoll(); return refresh; };

	v.onRowLimitChange({ target: { value: '500' } });
	await Promise.resolve();
	assert.strictEqual(resolving, true, 'poll must be waiting for hostname resolution');
	assert.strictEqual(frames.length, 1, 'fresh rows have a frame before names return');
	frames.shift()();
	assert.deepStrictEqual(renders, [true, true], 'Limit refresh bypasses throttle before names return');
	releaseNames();
	await refresh;
	await Promise.resolve();
	assert.deepStrictEqual(renders, [true, true, true], 'completion preserves the final forced paint');
	console.log('fwlive-view layer2: Limit paints before hostname completion OK');
}

(async function main() {
	try {
		await testRttKindHelpers();
		await testWeakDeviceDisplayCap();
		await testVisibilityStopsPoll();
		await testEpochDiscardsStale();
		await testHideShowWhileInFlightNoOverlap();
		await testRefreshTriggersSerialize();
		await testCadenceHysteresis();
		await testAdaptiveOffDisablesBackoff();
		await testResolveLoadShed();
		await testResolveReplyShapes();
		await testWarmHostnameTogglePaintsCache();
		await testShedSurfacing();
		await testSummaryFallbackAndRecovery();
		await testStreakResetOnAdaptiveOff();
		await testResolveShedCooldown();
		await testResolveRpcErrorNoFailMark();
		await testResolveTruncatedNoFailMark();
		await testResumeStaleSkipsRender();
		await testResumeMergeSurvivesVisibilityRace();
		await testUnpauseDuringPausedPollRetainsBuffer();
		await testPauseDuringLivePollRetainsBuffer();
		await testStaleAnimationFrameIsDropped();
		await testAnimationFrameAdaptersPreserveWindowReceiver();
		await testLimitRefreshPreservesQueuedForce();
		await testLimitPaintDoesNotWaitForHostnames();
		await sleep(20);
		console.log('fwlive-view layer2 backoff tests passed');
	} catch (e) {
		fail(e && e.stack ? e.stack : String(e));
	}
})();
