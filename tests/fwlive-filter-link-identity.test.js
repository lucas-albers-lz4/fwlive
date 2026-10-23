#!/usr/bin/env node
'use strict';

/**
 * Detail IN/OUT filter-link focus identity (#1375).
 */

const assert = require('node:assert/strict');
const { loadFwliveModule } = require('./lib/load-fwlive-module');
const luciE = require('./lib/luci-e-harness');

const log = loadFwliveModule('log');
const hostname = loadFwliveModule('hostname');
const links = loadFwliveModule('links', { log: log, hostname: hostname, E: luciE.E });
const table = loadFwliveModule('table', { log: log, links: links, E: luciE.E });

function callbacks() {
	return {
		onRowClick: function () {},
		onFilterClick: function () {},
		actionRowTintClass: function () {
			return '';
		}
	};
}

function ifaceBySlot(root, slot) {
	const found = [];
	function walk(node) {
		if (
			node &&
			node.classList &&
			node.classList.contains('fwlive-filter-link') &&
			node._fwliveFilterSlot === slot
		)
			found.push(node);
		const kids = node.childNodes || [];
		for (let i = 0; i < kids.length; i++) walk(kids[i]);
	}
	walk(root);
	return found[0] || null;
}

{
	const clicks = [];
	const link = links.ifaceLink('br-lan', function (field, value) {
		clicks.push([field, value]);
	}, 'iface_out');
	assert.strictEqual(link._fwliveFilterField, 'interface');
	assert.strictEqual(link._fwliveFilterValue, 'br-lan');
	assert.strictEqual(link._fwliveFilterSlot, 'iface_out');
	link._fwliveRowId = '1';
	link._listeners.click[0]({});
	assert.deepStrictEqual(clicks, [['interface', 'br-lan']]);
}

{
	const src = links.addrFilterLink('src', '192.0.2.1', false, null, function () {});
	src._fwliveRowId = '1';
	assert.strictEqual(src._fwliveFilterSlot, undefined);
	const ident = links.filterLinkIdentity(src);
	assert.strictEqual(ident.field, 'src');
	assert.strictEqual(ident.slot, undefined);
}

{
	const rows = [
		{
			id: '1',
			timestamp: 1,
			action: 'drop',
			src: '192.0.2.1',
			dst: '198.51.100.1',
			interface_in: 'br-lan',
			interface_out: 'br-lan',
			proto: 'tcp',
			message: 'same iface'
		}
	];
	const body = luciE.E('tbody', {}, []);
	table.renderRows(
		body,
		{
			rows: rows,
			columns: ['iface_in', 'iface_out', 'src'],
			forceRender: true,
			viewMode: 'detailed',
			messageLayout: 'wrap',
			expandedRowId: null,
			rowTint: false,
			showHostnames: false,
			hostnameCache: null
		},
		callbacks()
	);
	const inLink = ifaceBySlot(body, 'iface_in');
	const outLink = ifaceBySlot(body, 'iface_out');
	assert.ok(inLink, 'IN link is present');
	assert.ok(outLink, 'OUT link is present');
	assert.notEqual(inLink, outLink);
	assert.strictEqual(inLink._fwliveFilterField, 'interface');
	assert.strictEqual(outLink._fwliveFilterField, 'interface');
	assert.strictEqual(inLink._fwliveFilterValue, 'br-lan');
	assert.strictEqual(outLink._fwliveFilterValue, 'br-lan');
	assert.strictEqual(inLink._fwliveRowId, '1');
	assert.strictEqual(outLink._fwliveRowId, '1');

	const outIdent = links.filterLinkIdentity(outLink);
	assert.strictEqual(outIdent.slot, 'iface_out');
	assert.strictEqual(links.findFilterLinkByIdentity(body, outIdent), outLink);

	const inIdent = links.filterLinkIdentity(inLink);
	assert.strictEqual(inIdent.slot, 'iface_in');
	assert.strictEqual(links.findFilterLinkByIdentity(body, inIdent), inLink);
}

console.log('fwlive filter-link identity tests passed');
