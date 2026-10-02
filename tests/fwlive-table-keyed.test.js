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

console.log('fwlive table keyed reuse tests passed');
