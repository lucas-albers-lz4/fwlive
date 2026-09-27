#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

function run() {
	const root = path.join(__dirname, '..');
	const core = path.join(root, 'core', 'fwlive-log.js');
	const fixture = path.join(__dirname, 'fixtures', 'logread-mixed.json');

	const statsOut = execFileSync(process.execPath, [ core, 'stats', fixture ], { encoding: 'utf8' });
	const stats = JSON.parse(statsOut);
	assert.equal(stats.firewall, 5);
	assert.equal(stats.noise, 3);

	const filterOut = execFileSync(process.execPath, [ core, 'filter', fixture ], { encoding: 'utf8' });
	const rows = JSON.parse(filterOut);
	assert.equal(rows.length, 5);
	assert.equal(rows[0].src || rows[0].dst ? 1 : 0, 1);

	const pipeOut = execFileSync(process.execPath, [ core, 'filter' ], {
		encoding: 'utf8',
		input: fs.readFileSync(fixture, 'utf8')
	});
	const piped = JSON.parse(pipeOut);
	assert.equal(piped.length, 5);

	const large = path.join(__dirname, 'fixtures', 'logread-2000.json');
	const largeStats = JSON.parse(execFileSync(process.execPath, [ core, 'stats', large ], { encoding: 'utf8' }));
	assert.equal(largeStats.total, 2000);
	assert.equal(largeStats.firewall, 1250);
	assert.equal(largeStats.noise, 750);
	const freshDir = fs.mkdtempSync(path.join(os.tmpdir(), 'fwlive-logread-2000-'));
	try {
		const fresh = path.join(freshDir, 'logread-2000.json');
		execFileSync('bash', [ path.join(root, 'scripts', 'gen-logread-fixture.sh') ], {
			env: { ...process.env, FWLIVE_LOGREAD_FIXTURE_OUT: fresh }
		});
		assert.equal(fs.readFileSync(fresh, 'utf8'), fs.readFileSync(large, 'utf8'));
	} finally {
		fs.rmSync(freshDir, { recursive: true, force: true });
	}

	console.log('fwlive CLI pipeline tests passed');
}

run();
