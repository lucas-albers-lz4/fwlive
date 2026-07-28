#!/usr/bin/env node
'use strict';

/**
 * Smoke-load extracted fwlive modules (constants, links, chips, logging, table).
 * Stubs LuCI globals; exercises public APIs enough to catch extract regressions.
 */

const assert = require('assert');
const { loadFwliveModule, fakeE } = require('./lib/load-fwlive-module');

function fail(msg) {
	console.error(msg);
	process.exit(1);
}

/* --- constants --- */
const constants = loadFwliveModule('constants');
assert.strictEqual(constants.DEFAULT_ROW_LIMIT, 100);
assert.ok(Array.isArray(constants.ROW_LIMIT_OPTIONS));
assert.ok(constants.COLUMN_SETS.simple.indexOf('flow') >= 0);
assert.ok(constants.COLUMN_SETS.detailed.indexOf('message') >= 0);
console.log('fwlive-modules smoke: constants OK');

/* --- log (needed by links/chips/table) --- */
const log = loadFwliveModule('log');
assert.strictEqual(typeof log.formatCell, 'function');
assert.strictEqual(typeof log.parseFilterValue, 'function');
assert.strictEqual(typeof log.formatFilterChipLabel, 'function');

/* --- links --- */
const links = loadFwliveModule('links', { log: log });
assert.strictEqual(links.firewallZonesPath(), 'admin/network/firewall/zones');
assert.ok(String(links.luciUrl('admin/status/fwlive')).indexOf('luci') >= 0);
const clicks = [];
const fl = links.filterLink('proto', 'TCP', null, function(f, v) { clicks.push([f, v]); });
assert.strictEqual(fl.tag, 'a');
fl.attrs.click({ preventDefault: function() {} });
assert.deepStrictEqual(clicks[0], ['proto', 'TCP']);
assert.strictEqual(links.ruleAdminPath('fw4', 'nft'), 'admin/network/firewall/rules');
console.log('fwlive-modules smoke: links OK');

/* --- chips --- */
const chips = loadFwliveModule('chips', { log: log });
assert.strictEqual(chips.normalizeChipStyle('bogus'), 'labels');
assert.strictEqual(chips.normalizeChipStyle('symbols'), 'symbols');
assert.strictEqual(chips.normalizeChipStyle('tone'), 'tone');

function renderChips(style, filters) {
	const chipHost = {
		className: '',
		style: { display: '' },
		children: [],
		appendChild: function(n) { this.children.push(n); }
	};
	chips.renderFilterChips(chipHost, {
		filters: filters || { action: 'drop', proto: '!tcp' },
		chipFields: [
			{ key: 'action', label: 'action' },
			{ key: 'proto', label: 'proto' }
		],
		chipStyle: style
	}, {
		onInvert: function() {},
		onClear: function() {},
		onClearAll: function() {}
	});
	return chipHost;
}

const chipHost = renderChips('labels');
assert.strictEqual(chipHost.style.display, 'flex');
assert.ok(chipHost.children.length >= 1);
assert.strictEqual(chipHost.className, 'fwlive-chips fwlive-chips-labels');
const includeChip = chipHost.children[0];
const excludeChip = chipHost.children[1];
assert.ok(String(includeChip.attrs.class).indexOf('fwlive-chip-include') >= 0);
assert.ok(String(excludeChip.attrs.class).indexOf('fwlive-chip-negated') >= 0);
assert.ok(String(excludeChip.children[0].attrs.class).indexOf('fwlive-chip-sym') >= 0);

const symHost = renderChips('symbols');
assert.strictEqual(symHost.className, 'fwlive-chips fwlive-chips-symbols');
assert.ok(String(symHost.children[0].children[0].attrs.class).indexOf('fwlive-chip-sym') >= 0);

const toneHost = renderChips('tone');
assert.strictEqual(toneHost.className, 'fwlive-chips fwlive-chips-tone');
console.log('fwlive-modules smoke: chips OK');

/* --- logging --- */
const logging = loadFwliveModule('logging', { links: links });
assert.strictEqual(typeof logging.renderToolbar, 'function');
assert.strictEqual(typeof logging.renderEmptyState, 'function');
assert.strictEqual(typeof logging.renderManualTestNodes, 'function');

const bar = {
	style: { display: '' },
	innerHTML: 'x',
	appendChild: function() {}
};
logging.renderToolbar(bar, {
	loggingStatus: { wan_log: true, wan_log_limit: null, blockers: [] },
	loggingBusy: false,
	entriesLength: 0,
	loggingNotice: ''
}, { onEnable: function() {}, onDisable: function() {} });
assert.strictEqual(bar.style.display, 'flex');
assert.strictEqual(bar.innerHTML, '');

const emptyHost = { innerHTML: 'x', appendChild: function() {} };
logging.renderEmptyState(emptyHost, {
	loggingStatus: { wan_log: false, blockers: [] },
	loggingBusy: false,
	entriesLength: 0,
	loggingNotice: ''
}, { onEnable: function() {} });
assert.strictEqual(emptyHost.innerHTML, '');
console.log('fwlive-modules smoke: logging OK');

/* --- table --- */
const table = loadFwliveModule('table', { log: log, links: links });
assert.strictEqual(typeof table.renderThead, 'function');
assert.strictEqual(typeof table.renderRows, 'function');

const theadHost = {
	_colgroup: null,
	_tr: { innerHTML: '', appendChild: function() {} },
	querySelector: function(sel) {
		if (sel === 'thead tr')
			return this._tr;
		if (sel === 'colgroup')
			return this._colgroup;
		return null;
	},
	insertBefore: function(node) { this._colgroup = node; this._colgroup.innerHTML = ''; this._colgroup.appendChild = function() {}; },
	firstChild: null
};
table.renderThead(theadHost, { columns: ['action', 'time', 'flow'] }, {});
assert.ok(theadHost._colgroup);
assert.strictEqual(theadHost._tr.innerHTML, '');

const body = {
	innerHTML: 'rows',
	appendChild: function() { this._n = (this._n || 0) + 1; },
	_n: 0
};
const row = {
	id: 'r1',
	action: 'drop',
	timestamp: '2026-01-01T00:00:00Z',
	message: 'DROP IN=wan',
	interface_in: 'wan',
	proto: 'TCP',
	src: '1.2.3.4',
	dst: '5.6.7.8',
	sport: '1234',
	dport: '80',
	rule_hint: 'fw4',
	rule_label: 'wan'
};
table.renderRows(body, {
	rows: [row],
	columns: ['action', 'time', 'flow', 'proto'],
	viewMode: 'detailed',
	messageLayout: 'wrap',
	expandedRowId: null,
	rowTint: false,
	showHostnames: false,
	hostnameCache: null,
	firewallBackend: 'nft'
}, {
	onRowClick: function() {},
	onFilterClick: function() {},
	actionRowTintClass: function() { return ''; }
});
assert.strictEqual(body.innerHTML, '');
assert.ok(body._n >= 1);
console.log('fwlive-modules smoke: table OK');

/* --- buffer --- */
const buffer = loadFwliveModule('buffer');
assert.strictEqual(typeof buffer.applyFetchedEntries, 'function');
assert.strictEqual(buffer.ingestCap(true, 100, 2000), 2000);
assert.strictEqual(buffer.ingestCap(false, 100, 2000), 100);
console.log('fwlive-modules smoke: buffer OK');

console.log('fwlive modules smoke tests passed');
