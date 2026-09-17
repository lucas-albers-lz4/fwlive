#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { loadFwliveModule } = require('./lib/load-fwlive-module');

const pollCoordinator = loadFwliveModule('poll-coordinator');

function setup(options = {}) {
	let hidden = !!options.hidden;
	const visibilityHandlers = [];
	const pollOps = [];
	const runs = [];
	const visible = [];
	const coordinator = pollCoordinator.create({
		poll: {
			add: function (fn, interval) {
				pollOps.push({ op: 'add', fn: fn, interval: interval });
			},
			remove: function (fn) {
				pollOps.push({ op: 'remove', fn: fn });
			}
		},
		visibility: {
			add: function (fn) {
				visibilityHandlers.push(fn);
			},
			remove: function (fn) {
				const i = visibilityHandlers.indexOf(fn);
				if (i >= 0) visibilityHandlers.splice(i, 1);
			}
		},
		isHidden: function () {
			return hidden;
		},
		run:
			options.run ||
			function (epoch) {
				let release;
				const promise = new Promise(function (resolve) {
					release = resolve;
				});
				runs.push({ epoch: epoch, release: release });
				return promise;
			},
		onVisible: function () {
			visible.push(true);
		},
		initialCadence: options.initialCadence || 1
	});

	return {
		coordinator: coordinator,
		visibilityHandlers: visibilityHandlers,
		hide: function () {
			hidden = true;
			visibilityHandlers.slice().forEach(function (handler) {
				handler();
			});
		},
		pollOps: pollOps,
		runs: runs,
		setVisible: function () {
			hidden = false;
			visibilityHandlers.slice().forEach(function (handler) {
				handler();
			});
		},
		visible: visible
	};
}

async function testCoalescing() {
	const h = setup();
	const c = h.coordinator;
	c.startPolling();
	const first = c.requestPoll();
	const queued = c.requestPoll();
	const alsoQueued = c.requestPoll();
	assert.strictEqual(h.runs.length, 1);
	assert.strictEqual(c.getState().queued, true);

	h.runs[0].release('first');
	assert.strictEqual(await first, 'first');
	assert.strictEqual(h.runs.length, 2, 'one queued request must follow the active request');
	h.runs[1].release('queued');
	assert.strictEqual(await queued, 'queued');
	assert.strictEqual(await alsoQueued, 'queued');
	assert.strictEqual(h.runs.length, 2, 'all queued callers share one follow-up');
	assert.strictEqual(c.getState().inFlight, false);
	console.log('poll coordinator: coalescing OK');
}

async function testVisibilityCatchup() {
	const h = setup();
	const c = h.coordinator;
	c.startPolling();
	const first = c.requestPoll();
	h.hide();
	assert.strictEqual(h.runs[0].epoch, 0);
	assert.strictEqual(c.getState().epoch, 1);
	h.setVisible();
	assert.strictEqual(h.runs.length, 1, 'visible catch-up must wait for the hidden request');
	assert.deepStrictEqual(h.visible, [true]);

	h.runs[0].release();
	await first;
	assert.strictEqual(h.runs.length, 2, 'visible catch-up must start once');
	assert.strictEqual(h.runs[1].epoch, 2);
	h.runs[1].release();
	await new Promise(function (resolve) {
		setImmediate(resolve);
	});
	assert.strictEqual(c.getState().inFlight, false);
	console.log('poll coordinator: visibility catch-up and epochs OK');
}

async function testCadenceRegistration() {
	const h = setup();
	const c = h.coordinator;
	c.startPolling();
	c.setCadence(5);
	assert.deepStrictEqual(
		h.pollOps.map(function (op) {
			return [op.op, op.interval];
		}),
		[
			['add', 1],
			['remove', undefined],
			['add', 5]
		]
	);
	h.hide();
	c.setCadence(10);
	assert.strictEqual(h.pollOps.length, 4, 'hidden cadence changes must not register polling');
	h.setVisible();
	assert.strictEqual(h.pollOps[h.pollOps.length - 1].interval, 10);
	console.log('poll coordinator: cadence registration OK');
}

async function testDisposeSettlesAndDiscards() {
	const h = setup();
	const c = h.coordinator;
	c.startPolling();
	const active = c.requestPoll();
	const queued = c.requestPoll();
	const lateVisibility = h.visibilityHandlers[0];
	c.dispose();
	await active;
	await queued;
	assert.deepStrictEqual(c.getState(), {
		epoch: 1,
		cadenceSec: 1,
		inFlight: false,
		disposed: true,
		queued: false
	});
	h.runs[0].release({ late: true });
	await new Promise(function (resolve) {
		setImmediate(resolve);
	});
	assert.strictEqual(h.runs.length, 1, 'late completion must not start follow-up work');
	await c.requestPoll();
	assert.strictEqual(h.runs.length, 1, 'disposed requests must not start work');
	assert.strictEqual(h.visibilityHandlers.length, 0, 'disposal removes the visibility listener');
	const state = c.getState();
	const ops = h.pollOps.length;
	c.dispose();
	c.startPolling();
	c.setCadence(10);
	h.hide();
	lateVisibility();
	h.setVisible();
	lateVisibility();
	assert.deepStrictEqual(c.getState(), state, 'all late lifecycle calls must be inert');
	assert.strictEqual(h.pollOps.length, ops, 'disposal must be terminal');
	assert.strictEqual(h.visibilityHandlers.length, 0, 'startup must not rebind after disposal');
	console.log('poll coordinator: disposal settles and discards OK');
}

async function testQueuedCompletionWhileHidden() {
	let budget = 100;
	const budgets = [];
	let release;
	const gate = new Promise((resolve) => {
		release = resolve;
	});
	const h = setup({
		run: function () {
			budgets.push(budget);
			return gate;
		}
	});
	const c = h.coordinator;
	c.startPolling();
	const first = c.requestPoll();
	budget = 2000;
	const queued = c.requestPoll();
	h.hide();
	release();
	await first;
	await c.requestPoll();
	assert.deepStrictEqual(budgets, [100], 'hidden completion must retain the queued intent');
	h.setVisible();
	h.setVisible();
	await queued;
	assert.deepStrictEqual(budgets, [100, 2000], 'one catch-up reads the latest request context');
	console.log('poll coordinator: queued Limit intent survives hidden completion OK');
}

async function testRegistrationAndInitialHidden() {
	const h = setup({ hidden: true, initialCadence: 3 });
	const c = h.coordinator;
	c.setCadence(5);
	c.startPolling();
	c.startPolling();
	await c.requestPoll();
	assert.strictEqual(h.visibilityHandlers.length, 1);
	assert.strictEqual(h.pollOps.length, 0);
	assert.strictEqual(h.runs.length, 0, 'initially hidden startup must not run');
	h.setVisible();
	assert.strictEqual(h.runs.length, 1);
	c.startPolling();
	c.setCadence(5);
	assert.strictEqual(
		h.pollOps.length,
		1,
		'unchanged cadence and repeated startup do not register twice'
	);
	for (const invalid of [0, -1, NaN, Infinity, '5']) c.setCadence(invalid);
	assert.deepStrictEqual(
		h.pollOps.map((op) => [op.op, op.interval]),
		[
			['add', 5],
			['remove', undefined],
			['add', 3]
		],
		'fallback uses the injected cadence'
	);
	assert.strictEqual(h.runs.length, 1, 'cadence changes must not initiate requests');
	h.runs[0].release();
	c.dispose();
	console.log('poll coordinator: idempotent registration and injected cadence OK');
}

async function testRunnerFailuresAndRecovery() {
	for (const throws of [false, true]) {
		let calls = 0;
		const h = setup({
			run: function () {
				calls++;
				if (calls > 1) return 'recovered';
				if (throws) throw new Error('runner threw');
				return Promise.reject(new Error('runner rejected'));
			}
		});
		const c = h.coordinator;
		const failed = c.requestPoll();
		const queued = c.requestPoll();
		assert.strictEqual(await failed, undefined);
		assert.strictEqual(await queued, 'recovered');
		assert.strictEqual(c.getState().inFlight, false);
		assert.strictEqual(await c.requestPoll(), 'recovered');
		assert.strictEqual(calls, 3, 'failure releases the queue and allows future work');
	}
	console.log('poll coordinator: throwing/rejecting runner recovery OK');
}

async function testSynchronousReentryAndDisposal() {
	let calls = 0;
	let queued;
	const h = setup({
		run: function () {
			calls++;
			if (calls === 1) queued = h.coordinator.requestPoll();
			return calls;
		}
	});
	const first = h.coordinator.requestPoll();
	assert.strictEqual(calls, 1, 'runner reentry must queue instead of overlapping');
	assert.strictEqual(await first, 1);
	assert.strictEqual(await queued, 2);
	assert.strictEqual(calls, 2);

	const departing = setup({
		run: function () {
			departing.coordinator.dispose();
			return 'late';
		}
	});
	assert.strictEqual(
		await departing.coordinator.requestPoll(),
		undefined,
		'synchronous disposal must settle the already-owned batch'
	);
	assert.strictEqual(departing.coordinator.getState().inFlight, false);
	console.log('poll coordinator: synchronous reentry and disposal OK');
}

(async function main() {
	await testCoalescing();
	await testVisibilityCatchup();
	await testCadenceRegistration();
	await testDisposeSettlesAndDiscards();
	await testQueuedCompletionWhileHidden();
	await testRegistrationAndInitialHidden();
	await testRunnerFailuresAndRecovery();
	await testSynchronousReentryAndDisposal();
	console.log('poll coordinator tests passed');
})().catch(function (err) {
	console.error(err.stack || err);
	process.exit(1);
});
