#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { replay } = require('../tests/lib/poll-coordinator-mbt');

const root = path.resolve(__dirname, '..');
const out = path.resolve(process.argv[2] || '');
assert.ok(process.argv[2], 'diagnostics output directory required');
fs.mkdirSync(out, { recursive: true });
const model = path.join(root, 'formal/poll-coordinator/poll-coordinator.qnt');
const quint = path.join(root, 'node_modules/.bin/quint');
const source = path.join(root, 'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/poll-coordinator.js');
const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const inputPaths = ['formal/poll-coordinator/poll-coordinator.qnt',
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive/poll-coordinator.js',
	'tests/lib/load-fwlive-module.js', 'tests/lib/poll-coordinator-mbt.js',
	'scripts/formal-quint-replay.js', 'scripts/formal-quint.sh', 'package-lock.json'];
const seeds = ['1322', '953', '306'];
const manifest = {
	quint: '0.33.0', apalache: '0.62.1', node: process.version,
	inputs: Object.fromEntries(inputPaths.map(file => [file, sha(path.join(root, file))])),
	modelSha256: sha(model), sourceSha256: sha(source),
	driverSha256: sha(path.join(root, 'tests/lib/poll-coordinator-mbt.js')),
	runnerSha256: sha(__filename), lockSha256: sha(path.join(root, 'package-lock.json')),
	seeds, samplesPerSeed: 100, eventsPerSample: 30,
	exhaustiveEventBound: 5, directedTraces: 7,
	checkedOutHead: spawnSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).stdout?.trim()
};
fs.writeFileSync(path.join(out, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');

function generate(name, extra) {
	const result = spawnSync(quint, ['run', model, '--backend', 'typescript', '--mbt',
		'--invariant', 'invariant', '--verbosity', '0', '--out-itf', path.join(out, name), ...extra],
		{ cwd: root, encoding: 'utf8', timeout: 30_000, killSignal: 'SIGKILL', maxBuffer: 8 * 1024 * 1024 });
	fs.writeFileSync(path.join(out, name + '.log'), (result.stdout || '') + (result.stderr || ''));
	assert.ifError(result.error);
	assert.equal(result.status, 0, `Quint generation ${name} failed`);
}

function mutatedModule(old, replacement) {
	let text = fs.readFileSync(source, 'utf8');
	assert.equal(text.split(old).length - 1, 1, 'mutation site drift');
	text = text.replace(old, replacement).replace(/^'require [^']+';[^\n]*\n/gm, '');
	return new Function('baseclass', text)({ extend: x => x });
}

async function main() {
	const traces = [];
	for (let edge = 0; edge < 7; edge++) {
		const name = `edge-${edge}.itf.json`;
		generate(name, ['--seed', '1322', '--step', `edge${edge}`, '--max-samples', '1', '--max-steps', '8']);
		traces.push(path.join(out, name));
	}
	for (const seed of seeds) {
		generate(`seed-${seed}-{seq}.itf.json`, ['--seed', seed, '--max-samples', '100', '--n-traces', '100', '--max-steps', '30']);
		for (let i = 0; i < 100; i++) traces.push(path.join(out, `seed-${seed}-${i}.itf.json`));
	}
	let events = 0;
	for (const file of traces) {
		try { events += await replay(JSON.parse(fs.readFileSync(file, 'utf8'))); }
		catch (error) {
			fs.writeFileSync(path.join(out, 'failure.json'), JSON.stringify({ file, error: error.stack }, null, 2));
			throw error;
		}
	}
	const controls = [
		['queue', 0, 'if (!pending) pending = createBatch();', 'pending = createBatch();'],
		['epoch', 2, '\t\tepoch++;\n\t\tif (hidden)', '\t\tepoch += 0;\n\t\tif (hidden)'],
		['disposal', 4, 'if (active) active.resolve();', '/* deliberately lose caller settlement */']
	];
	const mutations = [];
	for (const [name, edge, old, replacement] of controls) {
		const trace = JSON.parse(fs.readFileSync(path.join(out, `edge-${edge}.itf.json`), 'utf8'));
		const module = mutatedModule(old, replacement);
		let failure;
		try { await replay(trace, module); }
		catch (error) { failure = error.message; }
		assert.ok(failure, `${name} mutation was not detected`);
		assert.match(failure, { queue: /batch promise identity/, epoch: /epoch:/, disposal: /batch 1 settlement/ }[name]);
		mutations.push({ name, failure });
	}
	const summary = { traces: traces.length, events, mutations, result: 'pass' };
	fs.writeFileSync(path.join(out, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
	console.log(`Quint MBT: ${traces.length} traces, ${events} events, ${mutations.length} mutations rejected`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
