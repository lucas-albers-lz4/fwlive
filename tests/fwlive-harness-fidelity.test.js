'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { loadFwliveView } = require('./lib/load-fwlive-view');

function testPollAddKeepsEveryCallback() {
	const harness = loadFwliveView();
	const seen = [];
	const before = harness.poll._entries.length;
	harness.poll.add(function() { seen.push('a'); }, 5);
	harness.poll.add(function() { seen.push('b'); }, 3);
	assert.equal(harness.poll._entries.length, before + 2);
	harness.poll._entries.forEach(function(entry) {
		if (typeof entry.fn === 'function')
			entry.fn();
	});
	assert.ok(seen.indexOf('a') !== -1 && seen.indexOf('b') !== -1);
}

function testLoadersReimposeUseStrict() {
	const files = [
		'tests/lib/load-fwlive-module.js',
		'tests/lib/load-fwlive-view.js',
		'tests/fixtures/luci-view-boot.js'
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

testPollAddKeepsEveryCallback();
testLoadersReimposeUseStrict();
console.log('fwlive harness fidelity (#837 #836) passed');
