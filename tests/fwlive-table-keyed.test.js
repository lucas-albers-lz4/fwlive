#!/usr/bin/env node
'use strict';

/**
 * Keyed tbody reuse (#784): expand/resolve must rebuild only changed rows.
 */

const assert = require('node:assert/strict');
const { loadFwliveModule } = require('./lib/load-fwlive-module');
const luciE = require('./lib/luci-e-harness');

const log = loadFwliveModule('log');
const hostname = loadFwliveModule('hostname');
const links = loadFwliveModule('links', { log: log, hostname: hostname, E: luciE.E });
const table = loadFwliveModule('table', { log: log, links: links, E: luciE.E });

function row(id, src) {
	return {
		id: String(id),
		timestamp: id,
		action: 'drop',
		src: src || '192.0.2.' + id,
		dst: '198.51.100.1',
		proto: 'tcp',
		message: 'row ' + id
	};
}

function callbacks() {
	return {
		onRowClick: function () {},
		onFilterClick: function () {},
		actionRowTintClass: function () {
			return '';
		}
	};
}

function baseState(rows, extra) {
	return Object.assign(
		{
			rows: rows,
			columns: ['src', 'dst', 'action'],
			forceRender: false,
			viewMode: 'simple',
			messageLayout: 'wrap',
			expandedRowId: null,
			rowTint: false,
			showHostnames: false,
			hostnameCache: null
		},
		extra || {}
	);
}

function newChildCount(before, host) {
	const prior = new Set(before);
	let n = 0;
	for (let i = 0; i < host.childNodes.length; i++) {
		if (!prior.has(host.childNodes[i])) n++;
	}
	return n;
}

function findElementByClass(root, className) {
	if (!root) return null;
	if (root.nodeType === 1 && root.classList && root.classList.contains(className)) return root;
	const kids = root.childNodes || [];
	for (let i = 0; i < kids.length; i++) {
		const found = findElementByClass(kids[i], className);
		if (found) return found;
	}
	return null;
}

{
	const rows = [row(1), row(2), row(3), row(4), row(5)];
	const body = luciE.E('tbody', {}, []);
	const cb = callbacks();
	table.renderRows(body, baseState(rows), cb);
	assert.strictEqual(body.childNodes.length, 5);
	const before = Array.prototype.slice.call(body.childNodes);
	const reused = before.find(function (n) {
		return n._fwliveRowId === '2';
	});

	table.renderRows(body, baseState(rows, { expandedRowId: '1' }), cb);
	assert.ok(newChildCount(before, body) <= 3, 'row expand must rebuild at most 3 tr nodes');
	const still = Array.prototype.slice.call(body.childNodes).find(function (n) {
		return n._fwliveRowId === '2';
	});
	assert.strictEqual(still, reused, 'unexpanded rows stay in place');
}

{
	const rows = [row(1, '192.0.2.1'), row(2, '192.0.2.2'), row(3, '192.0.2.3')];
	const cache = new Map();
	const body = luciE.E('tbody', {}, []);
	const cb = callbacks();
	const state = baseState(rows, { showHostnames: true, hostnameCache: cache });
	table.renderRows(body, state, cb);
	const before = Array.prototype.slice.call(body.childNodes);
	const untouched = before[1];

	cache.set('192.0.2.1', 'one.example');
	table.renderRows(body, state, cb);
	assert.ok(newChildCount(before, body) <= 1, 'one resolved name rebuilds only that row');
	assert.strictEqual(body.childNodes[1], untouched, 'rows without a new name are reused');
	assert.notEqual(body.childNodes[0], before[0], 'resolved row is rebuilt');
	const rebuiltSrc = findElementByClass(body.childNodes[0], 'fwlive-filter-link');
	assert.ok(rebuiltSrc, 'rebuilt row still has a source filter link');
	assert.strictEqual(rebuiltSrc._fwliveFilterField, 'src');
	assert.strictEqual(rebuiltSrc._fwliveFilterValue, '192.0.2.1');
	assert.strictEqual(rebuiltSrc._fwliveRowId, '1');
}

{
	const rows = [
		{
			id: '1',
			timestamp: 1,
			action: 'drop',
			src: '192.0.2.1',
			dst: '198.51.100.1',
			interface_in: 'wan',
			interface_out: 'br-lan',
			proto: 'tcp',
			message: 'row 1'
		}
	];
	const cache = new Map();
	const body = luciE.E('tbody', {}, []);
	const cb = callbacks();
	const state = baseState(rows, {
		columns: ['iface_in', 'iface_out', 'src'],
		viewMode: 'detailed',
		showHostnames: true,
		hostnameCache: cache
	});
	table.renderRows(body, state, cb);
	function ifaceByValue(root, value) {
		const links = [];
		function walk(node) {
			if (
				node &&
				node.classList &&
				node.classList.contains('fwlive-filter-link') &&
				node._fwliveFilterField === 'interface'
			)
				links.push(node);
			const kids = node.childNodes || [];
			for (let i = 0; i < kids.length; i++) walk(kids[i]);
		}
		walk(root);
		return links.find(function (link) {
			return link._fwliveFilterValue === value;
		});
	}
	assert.strictEqual(ifaceByValue(body, 'wan')._fwliveFilterField, 'interface');
	assert.strictEqual(ifaceByValue(body, 'br-lan')._fwliveFilterField, 'interface');
	cache.set('192.0.2.1', 'one.example');
	table.renderRows(body, state, cb);
	const outLink = ifaceByValue(body, 'br-lan');
	assert.ok(outLink, 'OUT interface link survives a hostname rebuild');
	assert.strictEqual(outLink._fwliveFilterValue, 'br-lan');
	assert.notEqual(ifaceByValue(body, 'wan'), outLink, 'IN and OUT keep distinct click values');
}

{
	const rows = [row(1), row(2)];
	const body = luciE.E('tbody', {}, []);
	const cb = callbacks();
	let toggles = 0;
	let stopped = 0;
	cb.onRowClick = function (id) {
		assert.strictEqual(id, '1');
		toggles++;
	};
	table.renderRows(body, baseState(rows, { columns: ['action', 'time'] }), cb);

	let firstRow = body.childNodes[0];
	let button = findElementByClass(firstRow, 'fwlive-row-expand');
	assert.ok(button, 'Simple-view action cell has a native expansion button');
	assert.strictEqual(button.tagName, 'button');
	assert.strictEqual(button.getAttribute('type'), 'button');
	assert.strictEqual(button.getAttribute('aria-label'), 'Show full message');
	assert.strictEqual(button.getAttribute('aria-expanded'), 'false');
	assert.strictEqual(
		button.getAttribute('aria-controls'),
		null,
		'collapsed controls have no dangling panel id'
	);
	assert.strictEqual(button.parentNode.tagName, 'td', 'button stays inside a native cell');
	assert.strictEqual(firstRow.tagName, 'tr');
	assert.strictEqual(firstRow.getAttribute('role'), null, 'row keeps native table semantics');
	assert.strictEqual(firstRow.getAttribute('tabindex'), null, 'row does not become a button');
	button._listeners.click[0]({
		currentTarget: button,
		stopPropagation: function () {
			stopped++;
		}
	});
	assert.strictEqual(stopped, 1, 'button click does not bubble to the row click path');
	assert.strictEqual(toggles, 1, 'button activation calls the row callback once');

	table.renderRows(
		body,
		baseState(rows, { columns: ['action', 'time'], expandedRowId: '1' }),
		cb
	);
	firstRow = body.childNodes[0];
	button = findElementByClass(firstRow, 'fwlive-row-expand');
	const expansion = body.childNodes[1];
	const message = findElementByClass(expansion, 'fwlive-msg-expand-body');
	assert.strictEqual(button.getAttribute('aria-label'), 'Hide full message');
	assert.strictEqual(button.getAttribute('aria-expanded'), 'true');
	assert.strictEqual(button.getAttribute('aria-controls'), 'fwlive-expanded-message');
	assert.strictEqual(message.getAttribute('id'), button.getAttribute('aria-controls'));
	assert.strictEqual(message.childNodes[0].textContent, rows[0].message);

	const detailBody = luciE.E('tbody', {}, []);
	table.renderRows(
		detailBody,
		baseState(rows, { viewMode: 'detailed', columns: ['action', 'time'] }),
		cb
	);
	assert.strictEqual(
		findElementByClass(detailBody, 'fwlive-row-expand'),
		null,
		'Detail view does not add Simple expansion controls'
	);
}

{
	const rows = [{
		id: '1',
		timestamp: 1,
		action: 'unknown',
		rule_hint: 'Kids-Bedtime',
		rule_label: 'Kids-Bedtime',
		rule_target: 'REJECT',
		src: '192.0.2.1',
		dst: '198.51.100.1',
		proto: 'tcp',
		message: 'Kids-Bedtime: IN=br-lan OUT=eth0 SRC=192.0.2.1 DST=198.51.100.1 PROTO=TCP'
	}];
	const body = luciE.E('tbody', {}, []);
	const cb = callbacks();
	const state = baseState(rows, { columns: ['rule', 'action'] });
	table.renderRows(body, state, cb);
	const span = findElementByClass(body, 'fwlive-rule-target');
	assert.ok(span, 'rule cell paints a target suffix span');
	assert.strictEqual(span.tagName, 'span');
	assert.strictEqual(span.childNodes.length, 1);
	assert.strictEqual(span.childNodes[0].nodeType, 3, 'target is a text node');
	assert.strictEqual(span.childNodes[0].textContent, 'REJECT');
	assert.deepEqual(span._innerHTMLWrites, [], 'target must not use an HTML sink');
	assert.ok(!span.classList.contains('fwlive-filter-link'), 'target suffix is not a filter link');
	const td = span.parentNode;
	assert.ok(td && td.classList.contains('fwlive-rule'));
	const sep = td.childNodes[1];
	assert.ok(sep && sep.nodeType === 3 && sep.textContent === ' · ',
		'name and target are separated by a text node');
	const actionTd = findElementByClass(body.childNodes[0], 'fwlive-action');
	assert.ok(actionTd, 'Action cell stays on the action column');
	assert.ok(actionTd.classList.contains('fwlive-unknown'),
		'target suffix must not change Action coloring');
	assert.ok(!actionTd.classList.contains('fwlive-deny'));
	assert.strictEqual(findElementByClass(actionTd, 'fwlive-rule-target'), null);
	const key1 = body.childNodes[0]._fwliveRowKey;
	rows[0].rule_target = 'DROP';
	table.renderRows(body, state, cb);
	const key2 = body.childNodes[0]._fwliveRowKey;
	assert.notEqual(key1, key2, 'rowRenderKey must include rule_target');
	assert.strictEqual(
		findElementByClass(body, 'fwlive-rule-target').childNodes[0].textContent,
		'DROP'
	);
}

console.log('fwlive table keyed reuse tests passed');
