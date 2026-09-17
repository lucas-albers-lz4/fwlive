#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { loadFwliveModule } = require('./lib/load-fwlive-module');

const pollCoordinator = loadFwliveModule('poll-coordinator');

function setup() {
	let hidden = false;
	const visibilityHandlers = [];
	const pollOps = [];
	const runs = [];
	const epochs = [];
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
		isHidden: function () { return hidden; },
		run: function (epoch) {
			let release;
			const promise = new Promise(function (resolve) {
				release = resolve;
			});
			runs.push({ epoch: epoch, release: release });
			return promise;
		},
		onEpochChange: function (epoch) { epochs.push(epoch); },
		onVisible: function () { visible.push(true); },
		initialCadence: 1
	});

	return {
		coordinator: coordinator,
		epochs: epochs,
		hide: function () {
			hidden = true;
			visibilityHandlers.slice().forEach(function (handler) { handler(); });
		},
		pollOps: pollOps,
		runs: runs,
		setVisible: function () {
			hidden = false;
			visibilityHandlers.slice().forEach(function (handler) { handler(); });
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
	assert.strictEqual(h.runs.length, 1);
	assert.strictEqual(c.getState().queued, true);

	h.runs[0].release('first');
	assert.strictEqual(await first, 'first');
	assert.strictEqual(h.runs.length, 2, 'one queued request must follow the active request');
	h.runs[1].release('queued');
	assert.strictEqual(await queued, 'queued');
	assert.strictEqual(c.getState().inFlight, false);
	console.log('poll coordinator: coalescing OK');
}

async function testVisibilityCatchup() {
	const h = setup();
	const c = h.coordinator;
	c.bind();
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
	await new Promise(function (resolve) { setImmediate(resolve); });
	assert.strictEqual(c.getState().inFlight, false);
	console.log('poll coordinator: visibility catch-up and epochs OK');
}

async function testCadenceRegistration() {
	const h = setup();
	const c = h.coordinator;
	c.bind();
	c.startPolling();
	c.setCadence(5);
	assert.deepStrictEqual(
		h.pollOps.map(function (op) { return [op.op, op.interval]; }),
		[['add', 1], ['remove', undefined], ['add', 5]]
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
	c.dispose();
	await active;
	await queued;
	assert.deepStrictEqual(c.getState(), {
		epoch: 1,
		cadenceSec: 1,
		inFlight: false,
		disposed: true,
		queued: false,
		pollFn: null
	});
	h.runs[0].release({ late: true });
	await new Promise(function (resolve) { setImmediate(resolve); });
	assert.strictEqual(h.runs.length, 1, 'late completion must not start follow-up work');
	await c.requestPoll();
	assert.strictEqual(h.runs.length, 1, 'disposed requests must not start work');
	console.log('poll coordinator: disposal settles and discards OK');
}

(async function main() {
	await testCoalescing();
	await testVisibilityCatchup();
	await testCadenceRegistration();
	await testDisposeSettlesAndDiscards();
	console.log('poll coordinator tests passed');
})().catch(function (err) {
	console.error(err.stack || err);
	process.exit(1);
});
