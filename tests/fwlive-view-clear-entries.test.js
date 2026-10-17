#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { createFwliveView: loadFwliveView } = require('./lib/load-fwlive-view');

function collectText(node) {
	if (!node) return '';
	if (node.nodeType === 3) return String(node.textContent || '');
	const kids = node.childNodes || [];
	let out = '';
	for (let i = 0; i < kids.length; i++) out += collectText(kids[i]);
	return out;
}

function logLine(id, ip) {
	return {
		id: id,
		time: 1704067200 + id,
		msg: 'fw4: DROP IN=wan OUT= SRC=' + ip + ' DST=192.0.2.2 PROTO=TCP DPT=22'
	};
}

function applyPoll(view, logs, rtt = 20, summary = undefined) {
	view.applyPollReply(
		{
			rtt: rtt,
			reply: { log: logs, adaptive: 1, summary: summary }
		},
		{
			resumeMerge: false,
			pausedAtStart: false,
			fetchLines: 200,
			beforeLength: view.entries.length
		}
	);
}

function testClearButtonSitsBesidePause() {
	const h = loadFwliveView();
	const pause = h.document.getElementById('fwlive-pause');
	const clear = h.document.getElementById('fwlive-clear');
	assert.ok(pause, 'Pause button must render');
	assert.ok(clear, 'Clear button must render');
	assert.strictEqual(collectText(clear), 'Clear');
	assert.match(clear._attrs.title, /New events still appear/);
	const kids = pause.parentNode.childNodes.filter(function (n) {
		return n && n._attrs && n._attrs.id;
	});
	const ids = kids.map(function (n) {
		return n._attrs.id;
	});
	assert.deepStrictEqual(
		ids.slice(0, 2),
		['fwlive-pause', 'fwlive-clear'],
		'Clear must sit immediately to the right of Pause'
	);
	console.log('fwlive-view clear: button placement OK');
}

function testClearDropsRowsAndKeepsSeenHidden() {
	const h = loadFwliveView();
	const v = h.view;
	applyPoll(v, [logLine(1, '203.0.113.1'), logLine(2, '203.0.113.2')]);
	assert.ok(v.entries.length >= 2, 'fixture must populate the table');
	const before = v.entries.length;

	v.onClearEntriesClick();
	assert.strictEqual(v.entries.length, 0, 'Clear must empty the table');
	assert.ok(v.clearedEntryKeys instanceof Set);
	assert.strictEqual(v.expandedRowId, null);

	applyPoll(v, [logLine(1, '203.0.113.1'), logLine(2, '203.0.113.2')]);
	assert.strictEqual(
		v.entries.length,
		0,
		'already seen kernel log lines must not refill after Clear'
	);

	applyPoll(v, [logLine(3, '198.51.100.9')]);
	assert.strictEqual(v.entries.length, 1, 'a new event after Clear must appear');
	assert.notEqual(before, 1);
	console.log('fwlive-view clear: seen lines stay hidden, new lines appear OK');
}

function testClearLeavesSummaryMode() {
	const h = loadFwliveView();
	const v = h.view;
	applyPoll(v, [logLine(1, '203.0.113.1')]);
	v.enterSummaryMode({
		top_talkers: [{ value: '203.0.113.1', count: 1 }],
		top_drops: [],
		top_rules: []
	});
	assert.strictEqual(v.summaryMode, true);
	assert.strictEqual(h.document.getElementById('fwlive-summary').style.display, 'block');

	v.onClearEntriesClick();
	assert.strictEqual(v.summaryMode, false, 'Clear must leave summary mode');
	assert.strictEqual(v.entries.length, 0);
	assert.strictEqual(h.document.getElementById('fwlive-summary').style.display, 'none');
	console.log('fwlive-view clear: summary mode dismissed OK');
}

function testClearClickHandlerIsWired() {
	const h = loadFwliveView();
	const v = h.view;
	applyPoll(v, [logLine(1, '203.0.113.1')]);
	v.attachHandlers();
	const clear = h.document.getElementById('fwlive-clear');
	assert.ok(clear._listeners && clear._listeners.click && clear._listeners.click.length === 1);
	clear._listeners.click[0]({ type: 'click' });
	assert.strictEqual(v.entries.length, 0, 'wired Clear click must empty the table');
	assert.ok(v.clearedEntryKeys instanceof Set);
	console.log('fwlive-view clear: click handler wired OK');
}

function testClearWhilePausedDoesNotResume() {
	const h = loadFwliveView();
	const v = h.view;
	applyPoll(v, [logLine(1, '203.0.113.1'), logLine(2, '203.0.113.2')]);
	v.tablePaused = true;
	v.fillingBuffer = true;
	v.pauseBufferLoading = true;
	v.lastBatchNewIdCount = 2;
	v.expandedRowId = '1';

	v.onClearEntriesClick();
	assert.strictEqual(v.tablePaused, true, 'Clear must not Resume');
	assert.strictEqual(v.fillingBuffer, false);
	assert.strictEqual(v.pauseBufferLoading, false);
	assert.strictEqual(v.lastBatchNewIdCount, 0);
	assert.strictEqual(v.expandedRowId, null);
	assert.strictEqual(v.entries.length, 0);
	assert.ok(v.clearedEntryKeys instanceof Set);

	applyPoll(v, [logLine(1, '203.0.113.1'), logLine(2, '203.0.113.2')]);
	assert.strictEqual(v.entries.length, 0, 'paused Clear still hides already seen lines');
	assert.strictEqual(v.tablePaused, true);
	console.log('fwlive-view clear: paused Clear does not resume OK');
}

function testClearKeepsFiltersAndHelp() {
	const h = loadFwliveView();
	const v = h.view;
	h.document.getElementById('fwlive-src').value = '203.0.113.1';
	h.document.getElementById('fwlive-q').value = 'DROP';
	applyPoll(v, [logLine(1, '203.0.113.1')]);
	v.onClearEntriesClick();
	const filters = v.readFilters();
	assert.strictEqual(filters.src, '203.0.113.1', 'Clear must keep the source filter');
	assert.strictEqual(filters.q, 'DROP', 'Clear must keep the search filter');
	assert.match(
		collectText(h.document.getElementById('fwlive-help')),
		/Clear empties the table/
	);
	assert.strictEqual(h.localStorage.getItem('fwlive-diag'), null);
	console.log('fwlive-view clear: filters and Help OK');
}

function testClearSurvivesWiderLookbacksAndRepeatedClear() {
	const h = loadFwliveView();
	const v = h.view;
	const window = (first, last) => Array.from({ length: last - first + 1 },
		(_, i) => logLine(first + i, '203.0.113.1'));
	applyPoll(v, window(1901, 2000));
	applyPoll(v, window(1, 2000));
	v.onClearEntriesClick();
	applyPoll(v, window(2, 2001));
	assert.deepStrictEqual(v.entries.map(row => row.id), ['log:2001']);
	applyPoll(v, window(2, 2001));
	assert.deepStrictEqual(v.entries.map(row => row.id), ['log:2001'],
		'repeated windows must not resurrect cleared events after counter-cache eviction');
	assert.strictEqual(v.lastBatchNewIdCount, 0, 'suppressed events do not consume the render budget');
	v.onClearEntriesClick();
	applyPoll(v, window(3, 2002));
	applyPoll(v, window(3, 2002));
	assert.deepStrictEqual(v.entries.map(row => row.id), ['log:2002'],
		'a second Clear must retain all cleared identities still in the ring');
	for (let first = 2003; first <= 6003; first += 100)
		applyPoll(v, window(first, first + 99));
	v.onClearEntriesClick();
	applyPoll(v, window(4103, 6102));
	assert.strictEqual(v.entries.length, 0, 'cleared rows stay hidden after observation-cache rollover');
	assert.ok(v.recentEntryKeys.size <= 2000, 'observation retention stays bounded');
	assert.ok(v.clearedEntryKeys.size <= 2100, 'Clear snapshot plus buffer stays bounded');
	console.log('fwlive-view clear: bounded rollover, wide lookback and repeated Clear OK');
}

function testClearAdmitsReusedIdsAndTimePrecision() {
	const h = loadFwliveView();
	const v = h.view;
	const before = { ...logLine(1, '203.0.113.1'), time: 1704067200001 };
	applyPoll(v, [before]);
	v.onClearEntriesClick();
	applyPoll(v, [before]);
	assert.strictEqual(v.entries.length, 0);
	applyPoll(v, [{ ...before, time: 1704067200002 }]);
	assert.strictEqual(v.entries.length, 1, 'a reused ID with a new raw time is a new event');
	v.onClearEntriesClick();
	applyPoll(v, [{ ...before, time: 1704067200002, msg: before.msg + ' LEN=64' }]);
	assert.strictEqual(v.entries.length, 1, 'a reused ID with a new message is a new event');
	console.log('fwlive-view clear: reused log IDs and raw timestamp precision OK');
}

function testClearIdentityStaysOutOfQuickSearch() {
	const h = loadFwliveView();
	const v = h.view;
	applyPoll(v, [{ ...logLine(1, '203.0.113.1'), time: 1704067200001 }]);
	h.document.getElementById('fwlive-q').value = '1704067200001';
	assert.strictEqual(v.filteredRows().length, 0,
		'private raw-time identity must not extend normalized-field quick search');
	h.document.getElementById('fwlive-q').value = '203.0.113.1';
	assert.strictEqual(v.filteredRows().length, 1, 'event fields remain searchable');
	v.onClearEntriesClick();
	applyPoll(v, [{ ...logLine(1, '203.0.113.1'), time: 1704067200001 }]);
	assert.strictEqual(v.entries.length, 0, 'non-enumerable identities still support Clear');
	console.log('fwlive-view clear: private identities stay out of quick search OK');
}

function testClearDoesNotRepublishServerSummary() {
	const h = loadFwliveView();
	const v = h.view;
	const logs = [logLine(1, '203.0.113.1')];
	const summary = { top_talkers: [{ value: '203.0.113.1', count: 1 }],
		top_drops: [{ value: '203.0.113.1', count: 1 }], top_rules: [] };
	applyPoll(v, logs, 1600, summary);
	assert.strictEqual(v.summaryMode, true);
	v.onClearEntriesClick();
	applyPoll(v, logs, 1600, summary);
	assert.strictEqual(v.entries.length, 0);
	assert.strictEqual(v.summaryMode, false, 'an unchanged slow sample cannot republish cleared summary');
	assert.strictEqual(h.document.getElementById('fwlive-summary').style.display, 'none');
	applyPoll(v, logs.concat(logLine(2, '198.51.100.1')), 1600, summary);
	assert.deepStrictEqual(v.entries.map(row => row.id), ['log:2']);
	assert.strictEqual(v.summaryMode, false);
	assert.strictEqual(v.degradedSampling, true, 'post-Clear rows keep cadence backoff');
	console.log('fwlive-view clear: slow replies preserve Clear while new events appear OK');
}

async function testClearDuringInflightPoll() {
	let finish;
	const h = loadFwliveView({ rpcMocks: { 'fwlive.poll': () => new Promise(resolve => { finish = resolve; }) } });
	const v = h.view;
	applyPoll(v, [logLine(1, '203.0.113.1')]);
	const pending = v.fetchEntries();
	assert.strictEqual(typeof finish, 'function');
	v.onClearEntriesClick();
	finish({ adaptive: 1, log: [logLine(1, '203.0.113.1'), logLine(2, '198.51.100.1')] });
	await pending;
	assert.deepStrictEqual(v.entries.map(row => row.id), ['log:2']);
	v.tablePaused = true;
	v.onClearEntriesClick();
	applyPoll(v, [logLine(2, '198.51.100.1'), logLine(3, '198.51.100.2')]);
	assert.strictEqual(v.tablePaused, true);
	assert.deepStrictEqual(v.entries.map(row => row.id), ['log:3']);
	v.tablePaused = false;
	applyPoll(v, [logLine(2, '198.51.100.1'), logLine(3, '198.51.100.2')]);
	assert.deepStrictEqual(v.entries.map(row => row.id), ['log:3']);
	console.log('fwlive-view clear: in-flight, paused and resumed replies respect Clear OK');
}

async function main() {
	testClearButtonSitsBesidePause();
	testClearDropsRowsAndKeepsSeenHidden();
	testClearLeavesSummaryMode();
	testClearClickHandlerIsWired();
	testClearWhilePausedDoesNotResume();
	testClearKeepsFiltersAndHelp();
	testClearSurvivesWiderLookbacksAndRepeatedClear();
	testClearAdmitsReusedIdsAndTimePrecision();
	testClearIdentityStaysOutOfQuickSearch();
	testClearDoesNotRepublishServerSummary();
	await testClearDuringInflightPoll();
	console.log('fwlive-view clear-entries tests passed');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
