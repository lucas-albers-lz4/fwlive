#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const core = require('../core/fwlive-log.js');
const { loadFwliveModule } = require('./lib/load-fwlive-module');

function run() {
	assert.equal(core.toggleFilterNegation('pass'), '!pass');
	assert.equal(core.toggleFilterNegation('!pass'), 'pass');
	assert.equal(core.toggleFilterNegation('192.168.1.1'), '!192.168.1.1');
	assert.equal(core.toggleFilterNegation('!192.168.1.1'), '192.168.1.1');
	assert.equal(core.toggleFilterNegation(''), '');
	assert.equal(core.toggleFilterNegation('   '), '   ');

	const luciLog = loadFwliveModule('log');
	const prefixRow = { src: '10.0.0.10', dst: '10.0.0.10' };
	assert.equal(
		core.matchesFilter(prefixRow, { src: '10.0.0.1' }),
		true,
		'core src 10.0.0.1 keeps 10.0.0.10'
	);
	assert.equal(
		core.matchesFilter(prefixRow, { dst: '10.0.0.1' }),
		true,
		'core dst 10.0.0.1 keeps 10.0.0.10'
	);
	assert.equal(
		luciLog.matchesFilter(prefixRow, { src: '10.0.0.1' }),
		true,
		'luci src 10.0.0.1 keeps 10.0.0.10'
	);
	assert.equal(
		luciLog.matchesFilter(prefixRow, { dst: '10.0.0.1' }),
		true,
		'luci dst 10.0.0.1 keeps 10.0.0.10'
	);
	assert.equal(core.matchesFilter({ src: '10.0.0.2' }, { src: '10.0.0.1' }), false);
	assert.equal(luciLog.matchesFilter({ src: '10.0.0.2' }, { src: '10.0.0.1' }), false);

	console.log('fwlive filter negate tests passed');
}

run();
