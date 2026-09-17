#!/usr/bin/env node
'use strict';

/**
 * Request guard (#240 Tier 1.7): refreshes coalesce behind the active request.
 */

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

function fail(msg) {
	console.error(msg);
	process.exit(1);
}

function deferredPoll(reply) {
	let resolveFn;
	const promise = new Promise(function (resolve) {
		resolveFn = resolve;
	});
	let calls = 0;
	const mock = async function () {
		calls++;
		await promise;
		return reply || { log: [] };
	};
	mock.calls = function () {
		return calls;
	};
	mock.release = function () {
		resolveFn();
	};
	return mock;
}

async function testRequestCoalescing() {
	const pollMock = deferredPoll({ log: [] });
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': pollMock,
			'fwlive.resolve': async function () {
				return { names: {} };
			}
		}
	});
	const view = h.view;
	view.tablePaused = true;

	const first = view.requestPoll();
	assert.strictEqual(pollMock.calls(), 1, 'first request must invoke poll once');

	const queued = view.requestPoll();
	assert.strictEqual(pollMock.calls(), 1, 'second request while in-flight must not overlap');

	pollMock.release();
	await first;
	assert.strictEqual(pollMock.calls(), 2, 'queued refresh must start after the first completes');
	pollMock.release();
	await queued;

	view.requestPoll();
	await new Promise(function (r) {
		setTimeout(r, 10);
	});
	assert.strictEqual(pollMock.calls(), 3, 'poll after the queued refresh completes may proceed');
	console.log('fwlive-view poll-guard: in-flight guard OK');
}

(async function main() {
	try {
		await testRequestCoalescing();
		console.log('fwlive-view poll-guard tests passed');
	} catch (e) {
		fail(e && e.stack ? e.stack : String(e));
	}
})();
