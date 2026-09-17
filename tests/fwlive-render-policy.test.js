#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { loadFwliveModule } = require('./lib/load-fwlive-module');
const { loadFwliveView } = require('./lib/load-fwlive-view');

const policy = loadFwliveModule('render-policy');

function rows(ids) {
	return ids.map(function (id) {
		return { id: id };
	});
}

function displayRowCap(overrides) {
	return policy.displayRowCap(
		Object.assign(
			{ rowLimit: 2000, weakDevice: false, weakDeviceDisplayRowCap: 250 },
			overrides
		)
	);
}

function renderCost(overrides) {
	return policy.renderCost(
		Object.assign(
			{
				visibleRowCount: 0,
				visibleHeadId: '',
				lastRenderedRowCount: 0,
				lastRenderedHeadId: '',
				lastBatchNewIdCount: 0
			},
			overrides
		)
	);
}

assert.strictEqual(displayRowCap(), 2000);
assert.strictEqual(displayRowCap({ weakDevice: true }), 250);
assert.deepStrictEqual(
	displayRowCap({ rowLimit: 100, weakDevice: true }),
	100,
	'weak-device cap must not raise a lower user limit'
);

assert.strictEqual(
	renderCost({ visibleRowCount: 1, visibleHeadId: 'a' }),
	1,
	'first non-empty render has unit cost'
);
assert.strictEqual(
	renderCost({
		visibleRowCount: 1,
		visibleHeadId: 'a',
		lastRenderedRowCount: 1,
		lastRenderedHeadId: 'a'
	}),
	0,
	'unchanged rows cost nothing'
);
assert.strictEqual(
	renderCost({
		visibleRowCount: 2,
		visibleHeadId: 'a',
		lastRenderedRowCount: 1,
		lastRenderedHeadId: 'a',
		lastBatchNewIdCount: 7
	}),
	1,
	'growing visible count uses unit cost'
);
assert.strictEqual(
	renderCost({
		visibleRowCount: 0,
		visibleHeadId: '',
		lastRenderedRowCount: 1,
		lastRenderedHeadId: 'a',
		lastBatchNewIdCount: 7
	}),
	1,
	'clearing visible rows uses unit cost'
);
assert.strictEqual(
	renderCost({
		visibleRowCount: 1,
		visibleHeadId: 'a',
		lastRenderedRowCount: 2,
		lastRenderedHeadId: 'a',
		lastBatchNewIdCount: 7
	}),
	1,
	'shrinking visible count uses unit cost'
);
assert.strictEqual(
	renderCost({
		visibleRowCount: 1,
		visibleHeadId: 'b',
		lastRenderedRowCount: 1,
		lastRenderedHeadId: 'a',
		lastBatchNewIdCount: 7
	}),
	7,
	'new head with unchanged visible count charges the last batch count'
);
assert.strictEqual(
	renderCost({
		visibleRowCount: 1,
		visibleHeadId: 'b',
		lastRenderedRowCount: 1,
		lastRenderedHeadId: 'a',
		lastBatchNewIdCount: 0
	}),
	1,
	'new head always has a minimum cost of one'
);

const view = loadFwliveView().view;
view.rowLimit = 2000;
view.weakDevice = true;
assert.strictEqual(view.displayRowCap(), 250, 'view delegates the weak-device cap');
view.lastRenderedRowCount = 1;
view.lastRenderedHeadId = 'a';
view.lastBatchNewIdCount = 3;
assert.strictEqual(view.renderBudgetCost(rows(['b'])), 3, 'view delegates per-batch render cost');

console.log('fwlive render-policy tests passed');
