#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

const SAMPLE_ROW = {
	id: 77,
	time: 1780797240,
	msg: 'fw4: ACCEPT IN=wan SRC=192.0.2.1 DST=198.51.100.2 PROTO=TCP SPT=1234 DPT=443'
};

function makeEntry(i) {
	return {
		id: 'row-' + i,
		timestamp: i,
		timestamp_display: '',
		rule_hint: '',
		rule_label: '',
		action: 'ACCEPT',
		action_raw: 'ACCEPT',
		interface: 'wan',
		interface_in: 'wan',
		interface_out: '',
		direction: 'in',
		proto: 'TCP',
		src: '192.0.2.1',
		sport: '1234',
		dst: '198.51.100.' + (i % 250 + 1),
		dport: '443',
		flags: '',
		length: '',
		message: 'fw4: ACCEPT SRC=192.0.2.1'
	};
}

function testFilteredRowsCache() {
	const h = loadFwliveView();
	const view = h.view;
	view.tablePaused = true;
	view.entries = Array.from({ length: 320 }, function (_, i) { return makeEntry(i); });

	let matchCalls = 0;
	const matchesFilter = h.log.matchesFilter;
	h.log.matchesFilter = function (row, filters) {
		matchCalls++;
		return matchesFilter.call(this, row, filters);
	};

	const first = view.filteredRowsState();
	assert.equal(first.matchCount, 320);
	assert.equal(first.rows.length, 100, 'display rows must stay capped at the selected limit');
	assert.strictEqual(view.filteredRowsState(), first,
		'repeated reads for the same entries, filters, and cap must reuse the result');
	view.updateStatus(first);
	view.updateSummaryUi();
	view.filteredRows();
	assert.equal(matchCalls, 320,
		'status, summary, and render consumers must share one full-buffer filter pass');
	assert.match(h.document.getElementById('fwlive-status').textContent,
		/320 matching · 320\/100 stored/,
		'paused status must use the cached full-buffer match count');

	h.document.getElementById('fwlive-q').value = '192.0.2.1';
	const changedFilter = view.filteredRowsState();
	assert.notStrictEqual(changedFilter, first, 'a filter change must invalidate the cached result');
	assert.equal(matchCalls, 640, 'a changed filter must trigger one new pass');

	view.entries = view.entries.slice();
	const changedEntries = view.filteredRowsState();
	assert.notStrictEqual(changedEntries, changedFilter,
		'a new buffer array must invalidate the cached result');
	assert.equal(matchCalls, 960, 'a new buffer must trigger one new pass');
	view.rowLimit = 200;
	const changedCap = view.filteredRowsState();
	assert.equal(changedCap.rows.length, 200, 'a changed display cap must rebuild visible rows');
	assert.equal(matchCalls, 1280);
	const returnedRows = view.filteredRows();
	returnedRows.pop();
	assert.equal(view.filteredRowsState().rows.length, 200,
		'consumers must not mutate the cached array through filteredRows');

	h.document.getElementById('fwlive-q').value = 'renamed rule';
	assert.equal(view.filteredRowsState().matchCount, 0);
	view.entries[0].rule_hint = 'wan-accept';
	view.rulesMap = { 'wan-accept': 'renamed rule' };
	view.refreshBufferedRuleLabels();
	assert.equal(view.filteredRowsState().matchCount, 1,
		'an in-place rule label refresh must invalidate query matches');
	console.log('fwlive-view hot path: filtered row cache OK');
}

async function testOneFilterPassPerPoll() {
	for (const paused of [false, true]) {
		const h = loadFwliveView({
			rpcMocks: {
				'fwlive.poll': async function () { return { log: [SAMPLE_ROW] }; }
			}
		});
		const view = h.view;
		view.tablePaused = paused;
		h.document.getElementById('fwlive-q').value = '192.0.2.1';
		let calls = 0;
		const matchesFilter = h.log.matchesFilter;
		h.log.matchesFilter = function (row, filters) {
			calls++;
			return matchesFilter.call(this, row, filters);
		};
		await view.runPollRequest(view.currentPollEpoch());
		assert.equal(view.lastPollError, false, 'the poll must reach its render and resolve consumers');
		assert.equal(calls, 1, 'render/status and hostname resolution must share one filter pass');
		const first = view.filteredRowsState();
		await view.runPollRequest(view.currentPollEpoch());
		assert.notStrictEqual(view.filteredRowsState(), first,
			'equal-length poll replacements must invalidate the previous cycle');
		assert.equal(calls, 2, 'the next poll must perform exactly one new filter pass');
	}
	console.log('fwlive-view hot path: one filter pass per live/paused poll OK');
}

(async function main() {
	testFilteredRowsCache();
	await testOneFilterPassPerPoll();
})().catch(function (err) {
	console.error(err.stack || err);
	process.exitCode = 1;
});
