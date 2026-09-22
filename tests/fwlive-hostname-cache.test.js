#!/usr/bin/env node
'use strict';

/**
 * Hostname LRU + failure TTL helpers (issue #56 / #59 support).
 */

const assert = require('node:assert/strict');
const { loadFwliveModule } = require('./lib/load-fwlive-module');
const luciE = require('./lib/luci-e-harness');

const hostname = loadFwliveModule('hostname');

function testLruEviction() {
	const map = new Map();
	for (let i = 0; i < 5; i++)
		hostname.lruSet(map, 'ip' + i, 'h' + i, 3);
	assert.strictEqual(map.size, 3);
	assert.strictEqual(map.has('ip0'), false);
	assert.strictEqual(map.has('ip1'), false);
	assert.strictEqual(map.get('ip4'), 'h4');
}

function testLruGetTouches() {
	const map = new Map();
	hostname.lruSet(map, 'a', '1', 2);
	hostname.lruSet(map, 'b', '2', 2);
	hostname.lruGet(map, 'a');
	hostname.lruSet(map, 'c', '3', 2);
	assert.strictEqual(map.has('b'), false);
	assert.strictEqual(map.get('a'), '1');
	assert.strictEqual(map.get('c'), '3');
}

function testDisplayReadTouchesLru() {
	const log = loadFwliveModule('log');
	const links = loadFwliveModule('links', { log: log, hostname: hostname, E: luciE.E });
	const map = new Map();
	hostname.lruSet(map, 'a', 'one.example', 2);
	hostname.lruSet(map, 'b', 'two.example', 2);
	const link = links.addrFilterLink('src', 'a', true, map, function () {});
	assert.strictEqual(
		link.childNodes[0].textContent,
		'one.example',
		'display must use the cached hostname'
	);
	hostname.lruSet(map, 'c', 'three.example', 2);
	assert.strictEqual(map.has('b'), false, 'display reads must refresh the visible entry');
}

function testAddressCellUsesWarmHostname() {
	const log = loadFwliveModule('log');
	const links = loadFwliveModule('links', { log: log, hostname: hostname, E: luciE.E });
	const table = loadFwliveModule('table', { log: log, links: links, E: luciE.E });
	const body = luciE.E('tbody', {}, []);
	table.renderRows(
		body,
		{
			rows: [{ id: 'warm', src: '192.0.2.1' }],
			columns: ['src'],
			forceRender: true,
			viewMode: 'detailed',
			messageLayout: 'wrap',
			expandedRowId: null,
			rowTint: false,
			showHostnames: true,
			hostnameCache: new Map([['192.0.2.1', 'router.example']])
		},
		{
			onRowClick: function () {},
			onFilterClick: function () {},
			actionRowTintClass: function () { return ''; }
		}
	);
	const linkText = body.childNodes[0].childNodes[0].childNodes[0].childNodes[0].textContent;
	assert.strictEqual(linkText, 'router.example', 'address cell must render the warm hostname');
}

function testFailTtl() {
	const failed = new Map();
	hostname.failMark(failed, '192.0.2.1', 10_000);
	assert.equal(hostname.failIsHot(failed, '192.0.2.1', 10_000 + 30_000), true);
	assert.equal(hostname.failIsHot(failed, '192.0.2.1', 10_000 + 60_000), false);
	assert.equal(failed.has('192.0.2.1'), false);
}

function testFailCap() {
	const failed = new Map();
	for (let i = 0; i < 5; i++)
		hostname.failMark(failed, 'ip' + i, i, 3);
	assert.strictEqual(failed.size, 3);
	assert.strictEqual(failed.has('ip0'), false);
}

testLruEviction();
testLruGetTouches();
testDisplayReadTouchesLru();
testAddressCellUsesWarmHostname();
testFailTtl();
testFailCap();
console.log('fwlive hostname cache tests passed');
