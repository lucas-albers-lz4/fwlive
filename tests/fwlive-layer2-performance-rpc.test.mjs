#!/usr/bin/env node
/* SPDX-License-Identifier: GPL-2.0-only */

import assert from 'node:assert/strict';
import {
	fwliveMethodRequestIds,
	fwliveRpcReplyForRequest,
	isFwliveFixtureRequest
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

const wrongReply = JSON.stringify([
	{ jsonrpc: '2.0', id: 41, result: [0, { backend: 'nft' }] }
]);
assert.strictEqual(fwliveRpcReplyForRequest(wrongReply, ids), null);

console.log('fwlive layer2 performance RPC matching tests passed');
