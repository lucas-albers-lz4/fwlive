#!/usr/bin/env node
'use strict';

/**
 * Hostname LRU + failure TTL helpers (issue #56 / #59 support).
 */

const assert = require('node:assert/strict');
const { loadFwliveModule } = require('./lib/load-fwlive-module');

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
testFailTtl();
testFailCap();
console.log('fwlive hostname cache tests passed');
