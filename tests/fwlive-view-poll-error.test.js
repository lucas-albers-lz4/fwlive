#!/usr/bin/env node
'use strict';

/**
 * View poll contract (#233 / #240 Tier 1.4): reply.error must reach lastPollError + status banner.
 */

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

const SAMPLE_ROW = {
	id: 1,
	time: 1704067200,
	msg: 'fw4: IN=wan OUT= SRC=192.0.2.1 DST=192.0.2.2 PROTO=TCP SPT=1234 DPT=443'
};

function fail(msg) {
	console.error(msg);
	process.exit(1);
}

async function testPollErrorField() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return { log: [], error: 'filter_failed' };
			}
		}
	});
	const view = h.view;

	await view.fetchEntries();
	assert.strictEqual(view.lastPollError, true, 'reply.error must set lastPollError');

	view.updateStatus();
	const status = h.document.getElementById('fwlive-status');
	assert.ok(status, 'fwlive-status must exist after render');
	assert.match(status.textContent, /Connection lost/i,
		'error reply must show connection-lost banner');
	console.log('fwlive-view poll-error: reply.error banner OK');
}

async function testPollHappyPath() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return { log: [SAMPLE_ROW] };
			}
		}
	});
	const view = h.view;

	await view.fetchEntries();
	assert.strictEqual(view.lastPollError, false, 'happy poll must clear lastPollError');
	assert.ok(view.entries.length >= 1, 'happy poll must populate entries');
	console.log('fwlive-view poll-error: happy path OK');
}

async function testPollBadShape() {
	for (const bad of [null, [], { log: null }]) {
		const h = loadFwliveView({
			rpcMocks: {
				'fwlive.poll': async function() { return bad; }
			}
		});
		await h.view.fetchEntries();
		assert.strictEqual(h.view.lastPollError, true,
			'bad poll shape must set lastPollError: ' + JSON.stringify(bad));
	}
	console.log('fwlive-view poll-error: bad shape OK');
}

async function testPollTransportThrow() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				throw new Error('network down');
			}
		}
	});
	await h.view.fetchEntries();
	assert.strictEqual(h.view.lastPollError, true, 'transport throw must set lastPollError');
	console.log('fwlive-view poll-error: transport throw OK');
}

async function testPollNonStringMsgSurvives() {
	const validMsg =
		'fw4: IN=wan OUT= SRC=192.0.2.1 DST=192.0.2.2 PROTO=TCP SPT=1234 DPT=443';
	const shapes = [42, { nested: true }, ['arr'], true];
	const log = [];
	const expectedIds = [];
	for (let i = 0; i < shapes.length; i++) {
		log.push({ id: 100 + i, msg: shapes[i] });
		log.push({ id: 200 + i, time: 1704067200, msg: validMsg });
		expectedIds.push('log:' + (200 + i));
	}

	const h = loadFwliveView();
	assert.doesNotThrow(() => h.view.normalizePollBatch(log));
	const batch = h.view.normalizePollBatch(log);
	assert.equal(batch.rows.length, shapes.length,
		'normalizePollBatch must keep one valid row after each non-string msg');
	assert.deepEqual(batch.rows.map((row) => row.id), expectedIds);

	const poll = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return { log: log };
			}
		}
	});
	await poll.view.fetchEntries();
	assert.strictEqual(poll.view.lastPollError, false,
		'mixed non-string msg batch must not fail the poll');
	assert.deepEqual(
		poll.view.entries.map((row) => row.id),
		expectedIds,
		'fetchEntries must keep the valid firewall rows after each non-string msg'
	);
	console.log('fwlive-view poll-error: non-string msg batch OK');
}

async function testSummaryPollErrorRefreshesStatus() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return { log: [], error: 'filter_failed' };
			}
		}
	});
	const view = h.view;
	view.summaryMode = true;
	view.summaryRowsShown = false;

	await view.runPollRequest(view.currentPollEpoch());
	const status = h.document.getElementById('fwlive-status');
	assert.match(status.textContent, /Connection lost/i,
		'summary-mode poll errors must refresh the status line');
	console.log('fwlive-view poll-error: summary error status OK');
}

(async function main() {
	try {
		await testPollErrorField();
		await testPollHappyPath();
		await testPollBadShape();
		await testPollTransportThrow();
		await testPollNonStringMsgSurvives();
		await testSummaryPollErrorRefreshesStatus();
		console.log('fwlive-view poll-error tests passed');
	} catch (e) {
		fail(e && e.stack ? e.stack : String(e));
	}
})();
