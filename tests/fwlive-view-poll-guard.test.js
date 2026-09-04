#!/usr/bin/env node
'use strict';

/**
 * pollDataInFlight guard (#240 Tier 1.7): overlapping pollData() is a no-op.
 */

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

function fail(msg) {
	console.error(msg);
	process.exit(1);
}

function deferredPoll(reply) {
	let resolveFn;
	const promise = new Promise(function(resolve) {
		resolveFn = resolve;
	});
	let calls = 0;
	const mock = async function() {
		calls++;
		await promise;
		return reply || { log: [] };
	};
	mock.calls = function() { return calls; };
	mock.release = function() { resolveFn(); };
	return mock;
}

async function testPollDataInFlightGuard() {
	const pollMock = deferredPoll({ log: [] });
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': pollMock,
			'fwlive.resolve': async function() { return { names: {} }; }
		}
	});
	const view = h.view;
	view.paused = true;

	const first = view.pollData();
	assert.strictEqual(pollMock.calls(), 1, 'first pollData must invoke poll once');

	view.pollData();
	assert.strictEqual(pollMock.calls(), 1, 'second pollData while in-flight must not invoke poll');

	pollMock.release();
	await first;

	view.pollData();
	await new Promise(function(r) { setTimeout(r, 10); });
	assert.strictEqual(pollMock.calls(), 2, 'poll after first completes may proceed');
	console.log('fwlive-view poll-guard: in-flight guard OK');
}

(async function main() {
	try {
		await testPollDataInFlightGuard();
		console.log('fwlive-view poll-guard tests passed');
	} catch (e) {
		fail(e && e.stack ? e.stack : String(e));
	}
})();
