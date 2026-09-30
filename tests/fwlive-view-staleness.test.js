#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

const SAMPLE_ROW = {
	id: 77,
	time: 1780797240,
	msg: 'fw4: ACCEPT IN=wan SRC=192.0.2.1 DST=198.51.100.2 PROTO=TCP SPT=1234 DPT=443'
};

async function testEmptyBatchStalenessHint(emptyBatch, paused) {
	let now = 100000;
	const batches = [[SAMPLE_ROW], emptyBatch, emptyBatch, [SAMPLE_ROW]];
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function () {
				return { log: batches.shift() };
			}
		}
	});
	const view = h.view;
	view.tablePaused = !!paused;
	view.nowMs = function () { return now; };
	const threshold = h.constants.EMPTY_POLL_STALE_AFTER_MS;

	assert.equal(
		threshold,
		h.constants.POLL_CADENCE_SLOW_S * 3 * 1000,
		'the stale hint threshold must cover three slow adaptive polls'
	);

	await view.fetchEntries();
	assert.equal(view.lastNonEmptyBatchAt, now, 'a non-empty batch starts the age clock');
	assert.equal(view.entries.length, 1);

	now += threshold - 1;
	await view.fetchEntries();
	view.updateStatus();
	const status = h.document.getElementById('fwlive-status');
	assert.doesNotMatch(String(status.textContent), /No new firewall events/,
		'the hint must stay hidden before the threshold');
	assert.equal(view.entries.length, 1, 'an empty batch must retain the buffered row');

	now += 1;
	await view.fetchEntries();
	view.updateStatus();
	assert.match(String(status.textContent), /No new firewall events/,
		'the hint must appear at the three-slow-poll threshold');
	assert.match(String(status.textContent), /15s ago/,
		'the hint must show the age of the last non-empty batch');
	assert.equal(view.entries.length, 1, 'the stale hint must not clear retained rows');
	assert.equal(status.className.includes('fwlive-status-paused'), !!paused,
		'the receipt-age hint must preserve live/paused status styling');

	view.lastPollError = true;
	view.updateStatus();
	assert.match(String(status.textContent), /Connection lost/,
		'poll failure must take precedence over receipt age');
	assert.doesNotMatch(String(status.textContent), /No new firewall events/);
	view.lastPollErrorCode = 'timeout_missing';
	view.updateStatus();
	assert.match(String(status.textContent), /Installation is incomplete/,
		'typed poll errors must take precedence over receipt age');
	assert.doesNotMatch(String(status.textContent), /No new firewall events/);
	view.lastPollError = false;
	view.lastPollErrorCode = null;

	now += threshold;
	await view.fetchEntries();
	assert.equal(view.lastNonEmptyBatchAt, now,
		'a later non-empty batch must reset the age clock');
	assert.equal(view.lastSuccessfulBatchEmpty, false,
		'a later non-empty batch must clear the stale-poll state');
	view.updateStatus();
	assert.doesNotMatch(String(status.textContent), /No new firewall events/,
		'the hint must clear when new firewall rows arrive');
	console.log('fwlive-view hot path: empty-poll staleness hint OK');
}

function testHintBounds() {
	const h = loadFwliveView();
	const view = h.view;
	let now = 100000;
	view.nowMs = function () { return now; };
	view.lastSuccessfulBatchEmpty = true;
	assert.equal(view.stalenessHint(), '', 'a view without received rows must not show an age');
	view.entries = view.normalizePollBatch([SAMPLE_ROW]).rows;
	assert.equal(view.stalenessHint(), '', 'a missing last receipt time must not show an age');
	view.lastNonEmptyBatchAt = now;
	now += 120000;
	assert.match(view.stalenessHint(), /2m ago/);
	now += 3600000;
	assert.match(view.stalenessHint(), /1h ago/);
	now += 86400000;
	assert.match(view.stalenessHint(), /1d ago/);
	now = 0;
	assert.equal(view.stalenessHint(), '', 'a clock moving backwards must not show a negative age');
	console.log('fwlive-view staleness: age bounds and units OK');
}

(async function main() {
	for (const paused of [false, true]) {
		await testEmptyBatchStalenessHint([], paused);
		await testEmptyBatchStalenessHint([{ id: 99, time: 1780797240, msg: 'unrelated service message' }], paused);
	}
	testHintBounds();
})().catch(function (err) {
	console.error(err.stack || err);
	process.exitCode = 1;
});
