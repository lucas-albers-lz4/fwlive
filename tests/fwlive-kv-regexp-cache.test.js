#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const core = require('../core/fwlive-log.js');
const { loadFwliveView } = require('./lib/load-fwlive-view');

const NativeRegExp = RegExp;
let constructed = 0;

function CountingRegExp(pattern, flags) {
	constructed++;
	return new NativeRegExp(pattern, flags);
}
CountingRegExp.prototype = NativeRegExp.prototype;

function testKvHasParity(coreLog, shippedLog) {
	const cases = [
		{ msg: 'SRC=', key: 'SRC', expect: true },
		{ msg: 'prefix SRC=', key: 'SRC', expect: true },
		{ msg: 'XSRC=', key: 'SRC', expect: false },
		{ msg: '_SRC=', key: 'SRC', expect: false },
		{ msg: 'SRCX=', key: 'SRC', expect: false },
		{ msg: 'src=', key: 'SRC', expect: false },
		/* Direct callers retain the original raw-RegExp interpolation behavior. */
		{ msg: 'SxC=', key: 'S.C', expect: true }
	];

	for (let i = 0; i < cases.length; i++) {
		const sample = cases[i];
		assert.strictEqual(coreLog.kvHas(sample.msg, sample.key), sample.expect,
			'core kvHas ' + JSON.stringify(sample));
		assert.strictEqual(shippedLog.kvHas(sample.msg, sample.key), sample.expect,
			'shipped kvHas ' + JSON.stringify(sample));
	}

	for (const log of [coreLog, shippedLog]) {
		assert.strictEqual(log.kvHas('SRC=', 'SRC'), true,
			'repeated lookup must keep matching the same static key');
		assert.strictEqual(log.kvHas('XSRC=', 'SRC'), false,
			'repeated lookup must keep enforcing the left key boundary');
		assert.strictEqual(log.kvHas('SRC=', 'SRC'), true,
			'static key presence includes an empty value');
	}
}

function main() {
	const previousRegExp = global.RegExp;
	global.RegExp = CountingRegExp;
	try {
		/* This loads the actual shipped log module through the normal view hot path. */
		const h = loadFwliveView();
		const initializationConstructions = constructed;
		constructed = 0;

		const rows = [];
		for (let i = 0; i < 2000; i++) {
			rows.push({
				id: i + 1,
				time: 1717675740,
				msg: 'fw4: DROP IN=br-lan OUT=eth0 SRC=10.0.0.2 DST=1.1.1.1 PROTO=TCP SPT=49999 DPT=443'
			});
		}

		const iterations = 25;
		let batch;
		const cachedKvHas = h.log.kvHas;
		h.log.kvHas = function (msg, key) {
			return new RegExp('(^|[^A-Za-z0-9_])' + key + '=').test(msg);
		};
		for (let i = 0; i < 5; i++)
			batch = h.view.normalizePollBatch(rows);
		const legacyWarmupConstructions = constructed;
		constructed = 0;
		let started = process.hrtime.bigint();
		for (let i = 0; i < iterations; i++)
			batch = h.view.normalizePollBatch(rows);
		const legacyElapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
		const legacyConstructions = constructed;

		h.log.kvHas = cachedKvHas;
		constructed = 0;
		for (let i = 0; i < 5; i++)
			batch = h.view.normalizePollBatch(rows);
		const cachedWarmupConstructions = constructed;
		constructed = 0;
		started = process.hrtime.bigint();
		for (let i = 0; i < iterations; i++)
			batch = h.view.normalizePollBatch(rows);
		const cachedElapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
		const cachedConstructions = constructed;

		assert.equal(batch.rows.length, 2000, 'the representative firewall batch keeps all rows');
		assert.equal(legacyWarmupConstructions, 20000,
			'the previous implementation must reproduce two RegExp constructions per row');
		assert.equal(legacyConstructions, 100000,
			'the previous implementation must keep constructing two RegExp objects per row');
		assert.equal(cachedWarmupConstructions, 0,
			'warmup batches must reuse the module-initialized KV patterns');
		assert.equal(cachedConstructions, 0,
			'normalizePollBatch must not construct RegExp objects per message');

		/* Unknown direct keys stay uncached, so arbitrary callers cannot grow module state. */
		constructed = 0;
		assert.equal(h.log.kvHas('CUSTOM=', 'CUSTOM'), true);
		assert.equal(h.log.kvHas('CUSTOM=', 'CUSTOM'), true);
		assert.equal(constructed, 2,
			'non-spec direct keys must preserve behavior without entering the cache');

		testKvHasParity(core, h.log);

		const legacyMsPerBatch = legacyElapsedMs / iterations;
		const cachedMsPerBatch = cachedElapsedMs / iterations;
		console.log('fwlive kv RegExp cache: ' + initializationConstructions +
			' module-init constructions; legacy ' + (legacyConstructions / iterations) +
			' vs cached ' + cachedConstructions + ' hot-path constructions per batch; ' +
			legacyMsPerBatch.toFixed(2) + ' vs ' + cachedMsPerBatch.toFixed(2) +
			' ms/batch (informational only)');
	} finally {
		global.RegExp = previousRegExp;
	}
}

main();
