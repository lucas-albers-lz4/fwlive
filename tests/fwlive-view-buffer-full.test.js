#!/usr/bin/env node
'use strict';

/**
 * #1333 — "buffer full" and stored ratio must reflect pause ingest cap, not live trim.
 */

const assert = require('node:assert/strict');
const { createFwliveView: loadFwliveView } = require('./lib/load-fwlive-view');

const h = loadFwliveView({});
const v = h.view;
const ROW = 100;
const MAX = h.constants.FETCH_LINES_MAX;

v.rowLimit = ROW;
v.entries = new Array(ROW).fill(null).map(function (_, i) {
	return { id: 'log:' + i, log_id: i, timestamp: i };
});

const filtered = { rows: v.entries.slice(0, 1), matchCount: ROW };

v.tablePaused = false;
assert.doesNotMatch(
	v.statusSuffix(),
	/buffer full/,
	'live mode at row limit must not show buffer full'
);
assert.match(
	v.compactCountText(filtered),
	new RegExp('· ' + ROW + '/' + ROW + ' stored'),
	'live stored ratio must use rowLimit'
);

v.tablePaused = true;
assert.match(
	v.compactCountText(filtered),
	new RegExp('· ' + ROW + '/' + MAX + ' stored'),
	'paused stored ratio must use ingest cap'
);

v.entries = new Array(MAX).fill(null).map(function (_, i) {
	return { id: 'log:' + i, log_id: i, timestamp: i };
});
const pausedFiltered = { rows: v.entries.slice(0, 1), matchCount: MAX };
assert.match(
	v.statusSuffix(),
	/buffer full/,
	'paused mode at ingest cap must show buffer full'
);
assert.match(
	v.compactCountText(pausedFiltered),
	new RegExp('· ' + MAX + '/' + MAX + ' stored'),
	'paused at cap must show ingest cap as denominator'
);

console.log('fwlive-view buffer full (#1333) OK');
