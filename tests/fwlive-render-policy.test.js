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

function decide(overrides) {
	return policy.decide(
		Object.assign(
			{
				rowLimit: 2000,
				weakDevice: false,
				weakDeviceDisplayRowCap: 250,
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

assert.deepStrictEqual(decide(), { visibleRowCap: 2000, renderCost: 0 });
assert.deepStrictEqual(decide({ weakDevice: true }), { visibleRowCap: 250, renderCost: 0 });
assert.deepStrictEqual(
	decide({ rowLimit: 100, weakDevice: true }),
	{ visibleRowCap: 100, renderCost: 0 },
	'weak-device cap must not raise a lower user limit'
);

assert.strictEqual(
	decide({ visibleRowCount: 1, visibleHeadId: 'a' }).renderCost,
	1,
	'first non-empty render has unit cost'
);
assert.strictEqual(
	decide({
		visibleRowCount: 1,
		visibleHeadId: 'a',
		lastRenderedRowCount: 1,
		lastRenderedHeadId: 'a'
	}).renderCost,
	0,
	'unchanged rows cost nothing'
);
assert.strictEqual(
	decide({
		visibleRowCount: 2,
		visibleHeadId: 'a',
		lastRenderedRowCount: 1,
		lastRenderedHeadId: 'a'
	}).renderCost,
	1,
	'visible-count changes use unit cost'
);
assert.strictEqual(
	decide({
		visibleRowCount: 1,
		visibleHeadId: 'b',
		lastRenderedRowCount: 1,
		lastRenderedHeadId: 'a',
		lastBatchNewIdCount: 7
	}).renderCost,
	7,
	'new head with unchanged visible count charges the last batch count'
);
assert.strictEqual(
	decide({
		visibleRowCount: 1,
		visibleHeadId: 'b',
		lastRenderedRowCount: 1,
		lastRenderedHeadId: 'a',
		lastBatchNewIdCount: 0
	}).renderCost,
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
