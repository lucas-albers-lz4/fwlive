#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const core = require('../core/fwlive-log.js');

function run() {
	assert.equal(core.toggleFilterNegation('pass'), '!pass');
	assert.equal(core.toggleFilterNegation('!pass'), 'pass');
	assert.equal(core.toggleFilterNegation('192.168.1.1'), '!192.168.1.1');
	assert.equal(core.toggleFilterNegation('!192.168.1.1'), '192.168.1.1');
	assert.equal(core.toggleFilterNegation(''), '');
	assert.equal(core.toggleFilterNegation('   '), '   ');

	console.log('fwlive filter negate tests passed');
}

run();
