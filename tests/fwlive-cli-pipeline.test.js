#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

function run() {
	const root = path.join(__dirname, '..');
	const core = path.join(root, 'core', 'fwlive-log.js');
	const fixture = path.join(__dirname, 'fixtures', 'logread-mixed.json');

	const statsOut = execFileSync(process.execPath, [ core, 'stats', fixture ], { encoding: 'utf8' });
	const stats = JSON.parse(statsOut);
	assert.equal(stats.firewall, 4);
	assert.equal(stats.noise, 3);

	const filterOut = execFileSync(process.execPath, [ core, 'filter', fixture ], { encoding: 'utf8' });
	const rows = JSON.parse(filterOut);
	assert.equal(rows.length, 4);
	assert.equal(rows[0].src || rows[0].dst ? 1 : 0, 1);

	const pipeOut = execFileSync(process.execPath, [ core, 'filter' ], {
		encoding: 'utf8',
		input: fs.readFileSync(fixture, 'utf8')
	});
	const piped = JSON.parse(pipeOut);
	assert.equal(piped.length, 4);

	console.log('fwlive CLI pipeline tests passed');
}

run();
