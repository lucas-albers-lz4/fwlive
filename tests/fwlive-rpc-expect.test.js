#!/usr/bin/env node
'use strict';

/**
 * Contract tests for the shared LuCI rpc.declare expect unwrap helper.
 * The Node helper and browser fixture must agree on wrong-type coercion and
 * empty-key passthrough semantics.
 */

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { applyExpect: nodeApplyExpect } = require('./lib/rpc-expect');

const fixturePath = path.join(__dirname, 'fixtures', 'rpc-expect.js');
const fixtureSource = fs.readFileSync(fixturePath, 'utf8');
const browserWindow = {};
vm.runInNewContext(fixtureSource, { window: browserWindow });
const browserApplyExpect = browserWindow.FwliveRpcExpect.applyExpect;

const defaultReply = { ok: false, changed: false, wan_zone: null, wan_zone_candidates: [] };
const wrongTypes = [null, undefined, 'bad', 7, []];

function runContract(label, applyExpect) {
	for (const reply of wrongTypes)
		assert.deepEqual(
			applyExpect(reply, { '': defaultReply }),
			defaultReply,
			label + ': wrong-type empty-key reply must use the default object'
		);

	const errorReply = { ok: false, error: 'nf_log_missing' };
	assert.deepEqual(
		applyExpect(errorReply, { '': defaultReply }),
		errorReply,
		label + ': valid object must preserve extra error properties'
	);

	const logReply = { log: [{ id: 1 }] };
	assert.deepEqual(
		applyExpect(logReply, { log: [] }),
		logReply.log,
		label + ': non-empty expect must unwrap the named key'
	);
	assert.deepEqual(
		applyExpect({ log: 'wrong' }, { log: [] }),
		[],
		label + ': named expect must coerce a wrong-type value'
	);
	assert.deepEqual(
		applyExpect({}, { log: [] }),
		[],
		label + ': named expect must use the default when the key is absent'
	);
}

runContract('node helper', nodeApplyExpect);
runContract('browser fixture', browserApplyExpect);
assert.deepEqual(
	nodeApplyExpect(null, { '': defaultReply }),
	browserApplyExpect(null, { '': defaultReply }),
	'Node and browser expect helpers must agree'
);

console.log('fwlive rpc-expect tests passed');
