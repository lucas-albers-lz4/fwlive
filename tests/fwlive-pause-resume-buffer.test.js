#!/usr/bin/env node
'use strict';

/**
 * Pause→resume buffer apply (#43): merge on resume, do not replace.
 */

const assert = require('node:assert/strict');
const { loadFwliveModule } = require('./lib/load-fwlive-module');

const buffer = loadFwliveModule('buffer');
const ROW = 100;
const MAX = 2000;

function row(id, ts) {
	return { id: String(id), log_id: id, timestamp: ts || id };
}

function ids(entries) {
	return entries.map(function(e) { return e.id; });
}

/* Live replace path still replaces. */
assert.deepStrictEqual(
	ids(buffer.applyFetchedEntries(
		[ row(1), row(2) ],
		[ row(10), row(11) ],
		{ paused: false, resumeMerge: false, rowLimit: ROW, fetchLinesMax: MAX }
	)),
	[ '10', '11' ]
);

/* Paused: merge and grow toward fetchLinesMax. */
const pausedBuf = [];
for (let i = 1; i <= 150; i++)
	pausedBuf.push(row(i));
const afterPausePoll = buffer.applyFetchedEntries(
	pausedBuf,
	[ row(151), row(152) ],
	{ paused: true, resumeMerge: false, rowLimit: ROW, fetchLinesMax: MAX }
);
assert.strictEqual(afterPausePoll.length, 152);
assert.deepStrictEqual(ids(afterPausePoll.slice(-3)), [ '150', '151', '152' ]);

/* Bug #43 scenario: large pause buffer + resume must keep recent pause rows. */
const big = [];
for (let i = 1; i <= 500; i++)
	big.push(row(i));
/* Poll returns only a short recent window that overlaps the end. */
const poll = [ row(490), row(491), row(492), row(500), row(501) ];

const brokenReplace = buffer.applyFetchedEntries(big, poll, {
	paused: false,
	resumeMerge: false,
	rowLimit: ROW,
	fetchLinesMax: MAX
});
assert.deepStrictEqual(ids(brokenReplace), [ '490', '491', '492', '500', '501' ],
	'replace path (pre-fix) loses pause-only rows');

const fixed = buffer.applyFetchedEntries(big, poll, {
	paused: false,
	resumeMerge: true,
	rowLimit: ROW,
	fetchLinesMax: MAX
});
assert.strictEqual(fixed.length, ROW);
assert.ok(ids(fixed).indexOf('402') >= 0, 'keeps pause-only row before poll window');
assert.ok(ids(fixed).indexOf('501') >= 0, 'includes new poll row');
assert.deepStrictEqual(ids(fixed).slice(-5), [ '497', '498', '499', '500', '501' ]);
assert.deepStrictEqual(ids(fixed)[0], '402');

/* Empty poll on resume still keeps trimmed pause buffer. */
const keep = buffer.applyFetchedEntries(big, [], {
	paused: false,
	resumeMerge: true,
	rowLimit: ROW,
	fetchLinesMax: MAX
});
assert.strictEqual(keep.length, ROW);
assert.deepStrictEqual(ids(keep)[0], '401');
assert.deepStrictEqual(ids(keep)[ROW - 1], '500');

assert.strictEqual(buffer.ingestCap(true, ROW, MAX), MAX);
assert.strictEqual(buffer.ingestCap(false, ROW, MAX), ROW);

console.log('fwlive pause/resume buffer tests passed');
