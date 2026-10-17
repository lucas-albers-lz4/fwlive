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

function applyPoll(view, logs) {
	view.applyPollReply(
		{
			rtt: 20,
			reply: { log: logs, adaptive: 1 }
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
	assert.strictEqual(v.suppressSeenIngest, true);
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

function main() {
	testClearButtonSitsBesidePause();
	testClearDropsRowsAndKeepsSeenHidden();
	testClearLeavesSummaryMode();
	console.log('fwlive-view clear-entries tests passed');
}

main();
