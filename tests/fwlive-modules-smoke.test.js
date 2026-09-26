#!/usr/bin/env node
'use strict';

/**
 * Smoke-load extracted fwlive modules (constants, links, chips, logging, table,
 * poll coordinator).
 * Stubs LuCI globals; exercises public APIs enough to catch extract regressions.
 */

const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { loadFwliveModule, fakeE, luciE } = require('./lib/load-fwlive-module');
const { collectInnerHTMLWrites } = luciE;

const PKG = path.join(__dirname, '..', 'openwrt-feed', 'luci-app-fwlive');

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
assert.deepStrictEqual(constants.ROW_TINT_OPTIONS, ['off', 'classic', 'accessible']);
assert.strictEqual(constants.DEFAULT_ROW_TINT, 'classic');
assert.ok(
	typeof constants.APP_VERSION === 'string' && /^\d+\.\d+\.\d+$/.test(constants.APP_VERSION)
);
const makefile = fs.readFileSync(path.join(PKG, 'Makefile'), 'utf8');
const mkVer = (makefile.match(/^PKG_VERSION:=(\S+)/m) || [])[1];
assert.strictEqual(
	constants.APP_VERSION,
	mkVer,
	'constants.APP_VERSION must match Makefile PKG_VERSION'
);
const luciDepends = (makefile.match(/^LUCI_DEPENDS:=(.*)$/m) || [])[1] || '';
assert.ok(/(^|\s)\+jsonfilter(\s|$)/.test(luciDepends), 'LUCI_DEPENDS must declare +jsonfilter');
const viewSrc = fs.readFileSync(
	path.join(PKG, 'htdocs/luci-static/resources/view/status/fwlive.js'),
	'utf8'
);
assert.ok(
	/autoFetchLines\(\)[\s\S]*?Math\.min\(Math\.max\(this\.rowLimit \* 4, 100\), constants\.FETCH_LINES_MAX\)/.test(
		viewSrc
	),
	'Auto poll must scale raw fetch with rowLimit and use FETCH_LINES_MAX as its paused compatibility budget'
);
assert.ok(
	/requestedFetchLines\(\)[\s\S]*?this\.tablePaused[\s\S]*?constants\.FETCH_LINES_MAX/.test(
		viewSrc
	),
	'poll must route fetch sizing through the budget decision helper'
);
assert.match(viewSrc, /\btablePaused\b/, 'view state must name the table rendering pause');
assert.doesNotMatch(
	viewSrc,
	/\bthis\.paused\b/,
	'view must not use the ambiguous paused state name'
);
assert.match(
	viewSrc,
	/\blastBatchNewIdCount\b/,
	'view must name the per-batch session-new ID count'
);
assert.doesNotMatch(
	viewSrc,
	/\blastPollNewEvents\b/,
	'view must not use the ambiguous poll-new-events state name'
);
assert.ok(
	!/expect:\s*\{\s*log:\s*\[\]\s*\}/.test(viewSrc),
	'callFwlivePoll must not use expect:{log:[]} (strips reply.error, #233)'
);
assert.ok(
	/expect:\s*\{\s*'':\s*\{\s*wan_zone: null,\s*wan_zone_candidates: \[\],\s*wan_log: false,\s*wan_log_limit: null,\s*nf_log_ipv4: false,\s*nf_log_ipv6: false,\s*ready: false,\s*weak_device: false,\s*blockers: \[\],\s*warnings: \[\]\s*\}\s*\}/.test(
		viewSrc
	),
	'callFwliveLoggingStatus expect must document the full reply shape incl. warnings (openwrt/luci#8992 round 5)'
);
assert.ok(
	/method: 'enable_wan_logging',\s*expect: \{ '': \{ ok: false, changed: false, wan_zone: null, wan_zone_candidates: \[\] \} \}/.test(
		viewSrc
	),
	'callFwliveEnableLogging empty-key expect must stay { ok:false, changed:false, wan_zone:null }'
);
assert.ok(
	/method: 'disable_wan_logging',\s*expect: \{ '': \{ ok: false, changed: false, wan_zone: null, wan_zone_candidates: \[\] \} \}/.test(
		viewSrc
	),
	'callFwliveDisableLogging empty-key expect must stay { ok:false, changed:false, wan_zone:null }'
);
assert.ok(
	/if\s*\(\s*reply\.error\s*\)/.test(viewSrc),
	'fetchEntries must set lastPollError when poll reply includes error'
);
assert.ok(
	/const raw = reply\.log/.test(viewSrc),
	'fetchEntries must read log array from the full poll reply object'
);
assert.match(
	viewSrc,
	/logging\.renderManualTestNodes\(testLi,\s*\{\s*firewallBackend:\s*this\.firewallBackend\s*\},\s*\{\}\)/,
	'manual test renderer must receive the detected firewall backend'
);
console.log('fwlive-modules smoke: constants OK');

/* --- poll coordinator --- */
const pollCoordinator = loadFwliveModule('poll-coordinator');
assert.strictEqual(typeof pollCoordinator.create, 'function');
console.log('fwlive-modules smoke: poll coordinator OK');

/* --- log (needed by links/chips/table) --- */
const log = loadFwliveModule('log');
assert.strictEqual(typeof log.formatCell, 'function');
assert.strictEqual(typeof log.parseFilterValue, 'function');
assert.strictEqual(typeof log.formatFilterChipLabel, 'function');
assert.strictEqual(typeof log.filterFieldLabel, 'function');

/* --- links --- */
const links = loadFwliveModule('links', { log: log });
assert.strictEqual(links.firewallZonesPath(), 'admin/network/firewall/zones');
assert.ok(String(links.luciUrl('admin/status/fwlive')).indexOf('luci') >= 0);
const clicks = [];
const fl = links.filterLink('proto', 'TCP', null, function (f, v) {
	clicks.push([f, v]);
});
assert.strictEqual(fl.tag, 'a');
fl.attrs.click({ preventDefault: function () {} });
assert.deepStrictEqual(clicks[0], ['proto', 'TCP']);
assert.strictEqual(links.ruleAdminPath(), 'admin/network/firewall/rules');
console.log('fwlive-modules smoke: links OK');

/* --- chips --- */
const chips = loadFwliveModule('chips', { log: log });
assert.strictEqual(typeof chips.renderFilterChips, 'function');

function renderChips(filters) {
	const chipHost = {
		className: '',
		style: { display: '' },
		children: [],
		appendChild: function (n) {
			this.children.push(n);
		}
	};
	chips.renderFilterChips(
		chipHost,
		{
			filters: filters || { action: 'drop', proto: '!tcp' },
			chipFields: [
				{ key: 'action', label: 'action' },
				{ key: 'proto', label: 'proto' }
			]
		},
		{
			onInvert: function () {},
			onClear: function () {},
			onClearAll: function () {}
		}
	);
	return chipHost;
}

const chipHost = renderChips();
assert.strictEqual(chipHost.style.display, 'flex');
assert.ok(chipHost.children.length >= 1);
assert.strictEqual(chipHost.className, 'fwlive-chips fwlive-chips-labels');
const includeChip = chipHost.children[0];
const excludeChip = chipHost.children[1];
assert.ok(String(includeChip.attrs.class).indexOf('fwlive-chip-include') >= 0);
assert.ok(String(excludeChip.attrs.class).indexOf('fwlive-chip-negated') >= 0);
assert.ok(String(excludeChip.children[0].attrs.class).indexOf('fwlive-chip-sym') >= 0);
console.log('fwlive-modules smoke: chips OK');

/* --- logging --- */
const logging = loadFwliveModule('logging', {
	links: links,
	E: luciE.E,
	document: luciE.document
});
assert.strictEqual(typeof logging.renderToolbar, 'function');
assert.strictEqual(typeof logging.renderEmptyState, 'function');
assert.strictEqual(typeof logging.renderManualTestNodes, 'function');
const manualNftHost = luciE.E('li', { 'id': 'fwlive-manual-test' }, []);
logging.renderManualTestNodes(manualNftHost, { firewallBackend: 'nft' }, {});
const manualNftText = collectText(manualNftHost);
assert.ok(manualNftText.indexOf('nft insert rule') >= 0, 'nft backend uses an nft manual test');
assert.ok(manualNftText.indexOf('iptables') < 0, 'nft backend must not emit iptables');
assert.strictEqual(
	manualNftHost._innerHTMLWrites.length,
	1,
	'nft host clear is the only innerHTML write'
);
assert.strictEqual(manualNftHost._innerHTMLWrites[0], '', 'nft host clear is not a payload');

const manualIptablesHost = luciE.E('li', { 'id': 'fwlive-manual-test' }, []);
logging.renderManualTestNodes(manualIptablesHost, { firewallBackend: 'iptables' }, {});
const manualIptablesText = collectText(manualIptablesHost);
assert.ok(
	manualIptablesText.indexOf('nft insert rule') >= 0,
	'injected iptables backend still uses the nft-only manual test'
);
assert.ok(
	manualIptablesText.indexOf('iptables') < 0,
	'manual test must not emit iptables (rpcd never reports that backend)'
);

function collectText(node) {
	if (!node) return '';
	if (node.nodeType === 3) return String(node.textContent || '');
	const kids = node.childNodes || [];
	let out = '';
	for (let i = 0; i < kids.length; i++) out += collectText(kids[i]);
	return out;
}

const bar = luciE.E('span', { 'id': 'fwlive-logging-bar', 'class': 'fwlive-logging-bar' }, []);
bar.style = {};
logging.renderToolbar(
	bar,
	{
		loggingStatus: { wan_log: true, wan_log_limit: null, blockers: [] },
		loggingBusy: false,
		loggingNotice: ''
	},
	{ onEnable: function () {}, onDisable: function () {} }
);
assert.strictEqual(bar.style.display, 'contents');
assert.strictEqual(bar.childNodes.length, 1, 'merged on-control is one button');
assert.strictEqual(bar.childNodes[0].tagName, 'button');
assert.ok(String(bar.childNodes[0]._attrs['class']).indexOf('fwlive-log-merged') >= 0);
const onText = collectText(bar.childNodes[0]);
assert.ok(onText.indexOf('WAN logging on') >= 0);
assert.ok(onText.indexOf('default 10/minute') >= 0);
assert.strictEqual(bar.childNodes[0]._innerHTMLWrites.length, 0, 'merged control uses text nodes');

logging.renderToolbar(
	bar,
	{
		loggingStatus: { wan_log: false, wan_log_limit: null, blockers: [] },
		loggingBusy: false,
		loggingNotice: ''
	},
	{ onEnable: function () {}, onDisable: function () {} }
);
assert.strictEqual(bar.style.display, 'contents');
assert.strictEqual(bar.childNodes.length, 1, 'off state is Enable CTA only');
assert.ok(collectText(bar.childNodes[0]).indexOf('Enable logging') >= 0);

let disableCalled = false;
logging.renderToolbar(
	bar,
	{
		loggingStatus: {
			wan_log: true,
			wan_log_limit: 10,
			blockers: ['nf_log_ipv4_missing']
		},
		loggingBusy: false,
		loggingNotice: ''
	},
	{
		onEnable: function () {},
		onDisable: function () {
			disableCalled = true;
		}
	}
);
assert.strictEqual(bar.style.display, 'contents');
assert.strictEqual(bar.childNodes.length, 2, 'blocker status + merged disable control');
const blockedStatus = bar.childNodes[0];
const blockedDisable = bar.childNodes[1];
assert.strictEqual(blockedStatus.tagName, 'span');
assert.ok(String(blockedStatus._attrs['class']).indexOf('fwlive-logging-status') >= 0);
assert.ok(collectText(blockedStatus).indexOf('missing kernel log modules') >= 0);
assert.strictEqual(blockedDisable.tagName, 'button');
assert.ok(String(blockedDisable._attrs['class']).indexOf('fwlive-log-merged') >= 0);
assert.ok(collectText(blockedDisable).indexOf('WAN logging on') >= 0);
assert.ok(blockedDisable._listeners.click && blockedDisable._listeners.click.length === 1);
blockedDisable._listeners.click[0]();
assert.strictEqual(disableCalled, true, 'blocked-but-enabled toolbar must wire onDisable');

logging.renderToolbar(
	bar,
	{
		loggingStatus: {
			wan_log: false,
			wan_log_limit: null,
			blockers: ['weird_new_gate'],
			ready: true
		},
		loggingBusy: false,
		loggingNotice: ''
	},
	{ onEnable: function () {}, onDisable: function () {} }
);
assert.strictEqual(bar.style.display, 'contents');
assert.strictEqual(bar.childNodes.length, 1, 'unknown blocker is status only');
const unknownStatus = bar.childNodes[0];
assert.strictEqual(unknownStatus.tagName, 'span');
assert.ok(String(unknownStatus._attrs['class']).indexOf('fwlive-logging-status') >= 0);
assert.ok(collectText(unknownStatus).indexOf('WAN logging unavailable') >= 0);
assert.ok(
	bar.childNodes.every(function (n) {
		return n.tagName !== 'button';
	}),
	'unknown blocker must not render Enable CTA'
);

const unknownEmptyHost = luciE.E('div', {}, []);
logging.renderEmptyState(
	unknownEmptyHost,
	{
		loggingStatus: {
			wan_log: false,
			wan_log_limit: null,
			blockers: ['weird_new_gate'],
			ready: true
		},
		loggingBusy: false,
		loggingNotice: ''
	},
	{ onEnable: function () {}, onDisable: function () {} }
);
const unknownEmptyText = collectText(unknownEmptyHost);
assert.ok(unknownEmptyText.indexOf('WAN logging unavailable') >= 0);
assert.ok(unknownEmptyText.indexOf('does not recognize') >= 0);
assert.ok(
	unknownEmptyHost.childNodes.every(function (n) {
		return n.tagName !== 'button';
	}),
	'unknown-blocker empty state must not render buttons'
);
assert.ok(
	unknownEmptyText.indexOf('Before you enable logging') === -1,
	'unknown-blocker empty state must not render consent panel'
);

const emptyHost = luciE.E('div', {}, []);
logging.renderEmptyState(
	emptyHost,
	{
		loggingStatus: { wan_log: false, blockers: [] },
		loggingBusy: false,
		loggingNotice: ''
	},
	{ onEnable: function () {} }
);
assert.ok(emptyHost.childNodes.length > 0);
console.log('fwlive-modules smoke: logging OK');

/* --- table --- */
const table = loadFwliveModule('table', { log: log, links: links });
assert.strictEqual(typeof table.renderThead, 'function');
assert.strictEqual(typeof table.renderRows, 'function');

const theadHost = {
	_colgroup: null,
	_tr: { innerHTML: '', appendChild: function () {} },
	querySelector: function (sel) {
		if (sel === 'thead tr') return this._tr;
		if (sel === 'colgroup') return this._colgroup;
		return null;
	},
	insertBefore: function (node) {
		this._colgroup = node;
		this._colgroup.innerHTML = '';
		this._colgroup.appendChild = function () {};
	},
	firstChild: null
};
table.renderThead(theadHost, { columns: ['action', 'time', 'flow'] }, {});
assert.ok(theadHost._colgroup);
assert.strictEqual(theadHost._tr.innerHTML, '');

const body = {
	innerHTML: 'rows',
	appendChild: function () {
		this._n = (this._n || 0) + 1;
	},
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
table.renderRows(
	body,
	{
		rows: [row],
		columns: ['action', 'time', 'flow', 'proto'],
		viewMode: 'detailed',
		messageLayout: 'wrap',
		expandedRowId: null,
		rowTint: false,
		showHostnames: false,
		hostnameCache: null
	},
	{
		onRowClick: function () {},
		onFilterClick: function () {},
		actionRowTintClass: function () {
			return '';
		}
	}
);
assert.strictEqual(body.innerHTML, '');
assert.ok(body._n >= 1);

const simpleBody = {
	innerHTML: 'rows',
	children: [],
	appendChild: function (n) {
		this.children.push(n);
		this.innerHTML = '';
	}
};
table.renderRows(
	simpleBody,
	{
		rows: [row],
		columns: ['time', 'action'],
		viewMode: 'simple',
		messageLayout: 'wrap',
		expandedRowId: null,
		rowTint: false,
		showHostnames: false,
		hostnameCache: null
	},
	{
		onRowClick: function () {},
		onFilterClick: function () {},
		actionRowTintClass: function () {
			return '';
		}
	}
);
assert.ok(simpleBody.children.length >= 1);
const simpleTr = simpleBody.children[0];
assert.strictEqual(simpleTr.tag, 'tr');
const timeTd = simpleTr.children.find(function (c) {
	return c.tag === 'td' && c.attrs && c.attrs.class === 'fwlive-time';
});
assert.ok(timeTd, 'simple view should render a time cell');
assert.strictEqual(String(timeTd.attrs.title), 'Click a row for the full message');

const outboundOnlyBody = {
	innerHTML: 'rows',
	children: [],
	appendChild: function (n) {
		this.children.push(n);
		this.innerHTML = '';
	}
};
table.renderRows(
	outboundOnlyBody,
	{
		rows: [
			Object.assign({}, row, { interface_in: '', interface_out: 'eth0', interface: 'eth0' })
		],
		columns: ['iface'],
		viewMode: 'simple',
		messageLayout: 'wrap',
		expandedRowId: null,
		rowTint: false,
		showHostnames: false,
		hostnameCache: null
	},
	{
		onRowClick: function () {},
		onFilterClick: function () {},
		actionRowTintClass: function () {
			return '';
		}
	}
);
assert.match(
	JSON.stringify(outboundOnlyBody.children[0]),
	/eth0/,
	'simple view should show OUT-only interface'
);

const keyedTable = loadFwliveModule('table', {
	log: log,
	links: links,
	E: luciE.E
});
const keyedBody = luciE.E('tbody', {}, []);
const keyedState = {
	rows: [row],
	columns: ['action', 'time', 'flow', 'proto'],
	forceRender: false,
	viewMode: 'detailed',
	messageLayout: 'wrap',
	expandedRowId: null,
	rowTint: false,
	showHostnames: false,
	hostnameCache: null
};
const keyedCallbacks = {
	onRowClick: function () {},
	onFilterClick: function () {},
	actionRowTintClass: function () {
		return '';
	}
};
keyedTable.renderRows(keyedBody, keyedState, keyedCallbacks);
const retainedRow = keyedBody.childNodes[0];
const newerRow = Object.assign({}, row, {
	id: 'r2',
	timestamp: '2026-01-01T00:00:01Z'
});
keyedTable.renderRows(
	keyedBody,
	Object.assign({}, keyedState, { rows: [newerRow, row] }),
	keyedCallbacks
);
assert.strictEqual(keyedBody.childNodes[1], retainedRow, 'unchanged poll rows are reused');
keyedTable.renderRows(
	keyedBody,
	Object.assign({}, keyedState, { forceRender: true }),
	keyedCallbacks
);
assert.notStrictEqual(keyedBody.childNodes[0], retainedRow, 'forced renders rebuild rows');

function assertSinkOnlyTbodyClear(host, payload) {
	assert.deepStrictEqual(
		collectInnerHTMLWrites(host),
		[''],
		'message render may only clear the tbody; it must never write payload HTML'
	);
	for (const html of collectInnerHTMLWrites(host)) {
		if (html && payload && html.indexOf(payload) >= 0)
			assert.fail('payload reached innerHTML: ' + html);
	}
}

function findMessageTd(host) {
	const tr = host.childNodes[0];
	assert.ok(tr, 'message row must render');
	return (tr.childNodes || []).find(function (c) {
		return (
			c.tagName === 'td' && c._attrs && String(c._attrs.class).indexOf('fwlive-message') >= 0
		);
	});
}

function hasMessageWrapDiv(td) {
	return (td.childNodes || []).some(function (c) {
		return c.tagName === 'div' && c._attrs && c._attrs.class === 'fwlive-message-wrap';
	});
}

function findExpansionPre(host) {
	const tr = (host.childNodes || []).find(function (c) {
		return c.tagName === 'tr' && c._attrs && c._attrs.class === 'fwlive-msg-expand';
	});
	if (!tr) return null;
	const td = (tr.childNodes || [])[0];
	if (!td) return null;
	return (td.childNodes || []).find(function (c) {
		return c.tagName === 'pre' && c._attrs && c._attrs.class === 'fwlive-msg-expand-body';
	});
}

function renderMessageRow(message, layout, extra) {
	const tbl = loadFwliveModule('table', { log: log, links: links, E: luciE.E });
	const body = luciE.E('tbody', {}, []);
	tbl.renderRows(
		body,
		Object.assign(
			{
				rows: [Object.assign({}, row, { id: 'sink', message: message })],
				columns: ['message'],
				forceRender: true,
				viewMode: 'simple',
				messageLayout: layout,
				expandedRowId: layout === 'wrap' ? 'sink' : null,
				rowTint: false,
				showHostnames: false,
				hostnameCache: null
			},
			extra || {}
		),
		keyedCallbacks
	);
	return body;
}

const hostileMessage = '<img src=x onerror=alert(1)> \u202e DROP';
const wrapHostile = renderMessageRow(hostileMessage, 'wrap');
assert.ok(
	collectText(wrapHostile).indexOf(hostileMessage) >= 0,
	'hostile log text must remain visible as text'
);
assert.ok(hasMessageWrapDiv(findMessageTd(wrapHostile)), 'wrap layout uses the wrap div');
assertSinkOnlyTbodyClear(wrapHostile, '<img');

const onelineHostile = renderMessageRow(hostileMessage, 'oneline');
assert.ok(
	collectText(onelineHostile).indexOf(hostileMessage) >= 0,
	'oneline hostile text must remain visible'
);
assert.ok(!hasMessageWrapDiv(findMessageTd(onelineHostile)), 'oneline layout must not wrap');
assertSinkOnlyTbodyClear(onelineHostile, '<img');

const ansiHostile = '\u001b[31mDROP\u001b[0m ' + hostileMessage;
const ansiBody = renderMessageRow(ansiHostile, 'wrap');
const ansiText = collectText(ansiBody);
assert.ok(ansiText.indexOf('DROP') >= 0, 'ANSI message must keep DROP as text');
assert.ok(ansiText.indexOf(hostileMessage) >= 0, 'ANSI+hostile must stay visible as text');
assertSinkOnlyTbodyClear(ansiBody, '<img');

const overlongRaw = 'DROP ' + 'x'.repeat(320);
const wrapShown = log.formatMessageDisplay(overlongRaw, 'wrap');
const onelineShown = log.formatMessageDisplay(overlongRaw, 'oneline');
assert.ok(wrapShown.endsWith('…'), 'wrap overlong must ellipsize');
assert.strictEqual(wrapShown.length, 238, 'wrap cap is 237 chars plus ellipsis');
assert.ok(
	!onelineShown.endsWith('…') || onelineShown.length > 238,
	'oneline keeps the full string'
);
assert.ok(onelineShown.indexOf('x'.repeat(40)) >= 0);

const wrapLong = renderMessageRow(overlongRaw, 'wrap', { expandedRowId: null });
assert.ok(collectText(wrapLong).indexOf(wrapShown) >= 0, 'wrap cell shows truncated text');
assert.ok(
	collectText(wrapLong).indexOf('x'.repeat(300)) < 0,
	'wrap cell must not show the full tail'
);
assertSinkOnlyTbodyClear(wrapLong, '<img');

const wrapExpanded = renderMessageRow(overlongRaw, 'wrap');
const expansionPre = findExpansionPre(wrapExpanded);
assert.ok(expansionPre, 'wrap layout with expandedRowId renders an expansion row');
const expansionText = collectText(expansionPre);
assert.strictEqual(expansionText, onelineShown, 'expansion shows the full uncapped message');
assert.ok(!expansionText.endsWith('…'), 'expansion must not ellipsize');
assert.ok(expansionText.length > 240, 'expansion keeps the full length');
assert.ok(expansionText.indexOf('x'.repeat(300)) >= 0, 'expansion includes the overlong tail');
assert.strictEqual(
	expansionPre.childNodes[0] && expansionPre.childNodes[0].nodeType,
	3,
	'expansion message is a text node'
);
const wrapExpandedTd = findMessageTd(wrapExpanded);
assert.ok(
	collectText(wrapExpandedTd).indexOf(wrapShown) >= 0,
	'wrap cell stays truncated when expanded'
);
assert.ok(
	collectText(wrapExpandedTd).indexOf('x'.repeat(300)) < 0,
	'wrap cell must not show the full tail when expanded'
);
assertSinkOnlyTbodyClear(wrapExpanded, '<img');

const onelineLong = renderMessageRow(overlongRaw, 'oneline');
assert.ok(
	collectText(onelineLong).indexOf(onelineShown) >= 0,
	'oneline cell shows the full string'
);
assert.ok(!hasMessageWrapDiv(findMessageTd(onelineLong)), 'overlong oneline has no wrap div');
assertSinkOnlyTbodyClear(onelineLong, '<img');
console.log('fwlive-modules smoke: table OK');

/* --- buffer --- */
const buffer = loadFwliveModule('buffer');
assert.strictEqual(typeof buffer.applyFetchedEntries, 'function');
assert.strictEqual(buffer.ingestCap(true, 100, 2000), 2000);
assert.strictEqual(buffer.ingestCap(false, 100, 2000), 100);
console.log('fwlive-modules smoke: buffer OK');

/* --- hostname cache --- */
const hostname = loadFwliveModule('hostname');
const cache = new Map();
hostname.lruSet(cache, 'a', 'one', 2);
hostname.lruSet(cache, 'b', 'two', 2);
hostname.lruSet(cache, 'c', 'three', 2);
assert.strictEqual(cache.has('a'), false);
assert.strictEqual(cache.get('c'), 'three');
const failed = new Map();
hostname.failMark(failed, '10.0.0.1', 1000);
assert.strictEqual(hostname.failIsHot(failed, '10.0.0.1', 1000 + 1000, 60000), true);
assert.strictEqual(hostname.failIsHot(failed, '10.0.0.1', 1000 + 70000, 60000), false);
console.log('fwlive-modules smoke: hostname OK');

console.log('fwlive modules smoke tests passed');
