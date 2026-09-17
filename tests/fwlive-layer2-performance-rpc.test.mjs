#!/usr/bin/env node
/* SPDX-License-Identifier: GPL-2.0-only */

import assert from 'node:assert/strict';
import {
	fwliveAutoFetchLines,
	fwliveMethodRequestIds,
	fwlivePollBudgetMatches,
	fwlivePollRequestCount,
	fwlivePollRequestedLines,
	fwlivePerformanceHash,
	fwliveRpcReplyForRequest,
	isFwliveFixtureRequest,
	isSuccessfulFwliveRpcReply
} from './lib/fwlive-perf-rpc.mjs';

const requests = JSON.stringify([
	{ jsonrpc: '2.0', id: 41, method: 'call', params: ['session', 'fwlive', 'rules', {}] },
	{
		jsonrpc: '2.0',
		id: 42,
		method: 'call',
		params: ['session', 'fwlive', 'logging_status', {}]
	}
]);
const ids = fwliveMethodRequestIds(requests, 'logging_status');
assert.deepStrictEqual(ids, [42]);
assert.strictEqual(isFwliveFixtureRequest(JSON.stringify({
	jsonrpc: '2.0',
	id: 43,
	method: 'call',
	params: ['session', 'fwlive', 'logging_status', {}]
})), true);
assert.strictEqual(isFwliveFixtureRequest(requests), true);
assert.strictEqual(isFwliveFixtureRequest(JSON.stringify({
	jsonrpc: '2.0',
	id: 44,
	method: 'call',
	params: ['session', 'fwlive', 'rules', {}]
})), false);
assert.equal(fwlivePollRequestCount(JSON.stringify([
	{
		jsonrpc: '2.0',
		id: 51,
		method: 'call',
		params: ['session', 'fwlive', 'poll', {}]
	},
	{
		jsonrpc: '2.0',
		id: 52,
		method: 'call',
		params: ['session', 'fwlive', 'poll']
	}
])), 2);
assert.deepStrictEqual(fwlivePollRequestedLines(JSON.stringify([
	{
		jsonrpc: '2.0',
		id: 45,
		method: 'call',
		params: ['session', 'fwlive', 'poll', { addresses: ['500'] }]
	},
	{
		jsonrpc: '2.0',
		id: 46,
		method: 'call',
		params: ['session', 'fwlive', 'rules', {}]
	},
	{
		jsonrpc: '2.0',
		id: 47,
		method: 'call',
		params: ['session', 'fwlive', 'poll', { addresses: ['1000'] }]
	},
])), ['500', '1000']);
assert.deepStrictEqual(fwlivePollRequestedLines(JSON.stringify({
	jsonrpc: '2.0',
	id: 48,
	method: 'call',
	params: ['session', 'fwlive', 'poll', {}]
})), []);
assert.deepStrictEqual(fwlivePollRequestedLines(JSON.stringify({
	jsonrpc: '2.0',
	id: 49,
	method: 'call',
	params: ['session', 'fwlive', 'poll', { addresses: [] }]
})), []);
assert.deepStrictEqual(fwlivePollRequestedLines({
	jsonrpc: '2.0',
	id: 50,
	method: 'call',
	params: ['session', 'fwlive', 'poll', { addresses: [500] }]
}), ['500']);
assert.deepStrictEqual(fwlivePollRequestedLines({
	jsonrpc: '2.0',
	id: 53,
	method: 'call',
	params: ['session', 'fwlive', 'poll', { addresses: ['malformed'] }]
}), ['malformed']);
assert.deepStrictEqual(fwlivePollRequestedLines({
	jsonrpc: '2.0',
	id: 54,
	method: 'call',
	params: ['session', 'fwlive', 'poll', { addresses: [-1] }]
}), ['-1']);
assert.deepStrictEqual(fwlivePollRequestedLines('{not-json'), []);
assert.equal(fwliveAutoFetchLines(25), 100);
assert.equal(fwliveAutoFetchLines(500), 2000);
assert.equal(fwliveAutoFetchLines(100, 500), 400);
assert.equal(fwlivePerformanceHash(2000), 'limit=2000');
assert.equal(
	fwlivePerformanceHash(500, 'auto'),
	'limit=500&poll=auto'
);
assert.equal(
	fwlivePerformanceHash(500, 'manual', 250),
	'limit=500&poll=manual&maxraw=250'
);
assert.equal(fwlivePollBudgetMatches(['500', '500'], 500, 2), true);
assert.equal(fwlivePollBudgetMatches(['500', '1000'], 500, 2), false);
assert.equal(fwlivePollBudgetMatches(['500'], 500, 2), false);
assert.equal(fwlivePollBudgetMatches(['bad'], 500, 1), false);

const singleReply = JSON.stringify({
	jsonrpc: '2.0',
	id: '42',
	result: [0, { weak_device: true }]
});
assert.deepStrictEqual(fwliveRpcReplyForRequest(singleReply, ids).result[1], {
	weak_device: true
});

const reorderedReplies = JSON.stringify([
	{ jsonrpc: '2.0', id: 42, result: [0, { weak_device: true }] },
	{ jsonrpc: '2.0', id: 41, result: [0, { backend: 'nft' }] }
]);
assert.deepStrictEqual(fwliveRpcReplyForRequest(reorderedReplies, ids).result[1], {
	weak_device: true
});
assert.equal(isSuccessfulFwliveRpcReply(fwliveRpcReplyForRequest(
	JSON.stringify({ jsonrpc: '2.0', id: 42, result: [0, { log: [] }] }), ids
)), true);
assert.equal(isSuccessfulFwliveRpcReply(fwliveRpcReplyForRequest(
	JSON.stringify({ jsonrpc: '2.0', id: 42, result: [6, { error: 'denied' }] }), ids
)), false);

const wrongReply = JSON.stringify([
	{ jsonrpc: '2.0', id: 41, result: [0, { backend: 'nft' }] }
]);
assert.strictEqual(fwliveRpcReplyForRequest(wrongReply, ids), null);

console.log('fwlive layer2 performance RPC matching tests passed');
