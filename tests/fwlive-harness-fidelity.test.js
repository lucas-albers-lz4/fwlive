'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { createHarnessDocument, loadFwliveView, waitFor } = require('./lib/load-fwlive-view');

async function testPollAddKeepsEveryCallback() {
	const harness = loadFwliveView();
	await harness.view.load();
	const seen = [];
	const before = harness.poll._entries.length;
	assert.ok(before >= 1, 'the loaded view must register a poll callback');
	harness.poll.add(function() { seen.push('a'); }, 5);
	harness.poll.add(function() { seen.push('b'); }, 3);
	assert.equal(harness.poll._entries.length, before + 2);
	const data = { log: [] };
	const res = { ok: true };
	harness.poll._entries.forEach(function(entry) {
		if (typeof entry.fn === 'function')
			entry.fn(data, res);
	});
	assert.ok(seen.indexOf('a') !== -1 && seen.indexOf('b') !== -1);
}

function testSelectorSupportIsExplicit() {
	const { document } = createHarnessDocument();
	assert.throws(() => document.querySelector('#missing > tbody'), /unsupported harness selector/);
	assert.throws(() => document.querySelector('div.example'), /unsupported harness selector/);
	assert.equal(document.querySelector('#missing tbody'), null);
}

async function testWaitForRetainsPredicateFailure() {
	await assert.rejects(waitFor(() => { throw new Error('row count unavailable'); }, 1),
		(err) => /row count unavailable/.test(err.message) && err.cause.message === 'row count unavailable');
}

function testLoadersReimposeUseStrict() {
	const files = [
		'tests/lib/load-fwlive-module.js',
		'tests/lib/load-fwlive-view.js',
		'tests/fixtures/luci-view-boot.js',
		'tests/fwlive-theme-tint.test.js',
		'tests/fwlive-theme-css.test.js'
	];
	const root = path.join(__dirname, '..');
	for (let i = 0; i < files.length; i++) {
		const src = fs.readFileSync(path.join(root, files[i]), 'utf8');
		assert.ok(
			src.indexOf("'use strict';\\n\"") !== -1,
			files[i] + ' must prepend use strict to extracted bodies'
		);
	}
}

async function main() {
	await testPollAddKeepsEveryCallback();
	testSelectorSupportIsExplicit();
	await testWaitForRetainsPredicateFailure();
	testLoadersReimposeUseStrict();
	console.log('fwlive harness fidelity (#837 #836) passed');
}
main().catch((err) => { console.error(err); process.exitCode = 1; });
