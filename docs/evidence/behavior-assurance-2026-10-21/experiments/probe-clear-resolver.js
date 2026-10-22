'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const repo = path.resolve(__dirname, '../../../..');
const { createFwliveView } = require(path.join(repo, 'tests/lib/load-fwlive-view'));
const { EMPTY_POLL_STALE_AFTER_MS } = createFwliveView().constants;

function line(id, ip) {
	return {
		id,
		time: 1704067200 + id,
		msg: `fw4: DROP IN=wan OUT= SRC=${ip} DST=192.0.2.2 PROTO=TCP DPT=22`
	};
}

function apply(view, raw) {
	view.applyPollReply({ rtt: 20, reply: { log: raw, adaptive: 1 } }, {
		resumeMerge: false,
		pausedAtStart: false,
		fetchLines: 200,
		beforeLength: view.entries.length
	});
}

function snapshot(view, document, rawCount) {
	view.updateStatus();
	return {
		rawCount,
		normalizedBufferCount: view.entries.length,
		lastBatchNewIdCount: view.lastBatchNewIdCount,
		lastSuccessfulBatchEmpty: view.lastSuccessfulBatchEmpty,
		lastNonEmptyBatchAt: view.lastNonEmptyBatchAt,
		status: String(document.getElementById('fwlive-status').textContent)
	};
}

function clearStalenessProbe() {
	function preparedView() {
		const h = createFwliveView();
		const v = h.view;
		let now = 100000;
		v.nowMs = () => now;
		const old = line(1, '203.0.113.1');
		const fresh = line(2, '198.51.100.2');
		apply(v, [old]);
		v.onClearEntriesClick();
		apply(v, [old, fresh]);
		assert.equal(v.entries.length, 1, 'the post-Clear event is admitted');
		assert.equal(v.lastNonEmptyBatchAt, now, 'admitted event refreshes receipt clock');
		return { h, v, old, fresh, getNow: () => now,
			advance: (ms) => { now += ms; } };
	}

	const threshold = EMPTY_POLL_STALE_AFTER_MS;
	const repeat = preparedView();
	repeat.advance(threshold + 1);
	/* A realistic repeat of the non-empty ring suffix still includes its newer event. */
	apply(repeat.v, [repeat.old, repeat.fresh]);
	const repeatedNonempty = snapshot(repeat.v, repeat.h.document, 2);
	assert.equal(repeatedNonempty.normalizedBufferCount, 1);
	assert.equal(repeatedNonempty.lastBatchNewIdCount, 0,
		'repeated event is not session-new even though the normalized batch is nonempty');
	assert.equal(repeatedNonempty.lastSuccessfulBatchEmpty, false);
	assert.equal(repeatedNonempty.lastNonEmptyBatchAt, repeat.getNow());
	assert.doesNotMatch(repeatedNonempty.status, /no current entries/,
		'a repeated non-empty window must reset age and avoid the stale hint');

	const empty = preparedView();
	empty.advance(threshold + 1);
	apply(empty.v, []);
	const genuinelyEmpty = snapshot(empty.v, empty.h.document, 0);
	assert.equal(genuinelyEmpty.normalizedBufferCount, 1,
		'genuinely empty polls retain the last buffered event');
	assert.equal(genuinelyEmpty.lastSuccessfulBatchEmpty, true);
	assert.match(genuinelyEmpty.status, /Firewall log has no current entries/);

	/* A fabricated non-empty raw window containing only the old cleared row can
	 * manufacture the same hint, but the host view harness cannot prove logread
	 * can return this window after the newer event. */
	const suppressedOnly = preparedView();
	suppressedOnly.advance(threshold + 1);
	apply(suppressedOnly.v, [suppressedOnly.old]);
	const clearedOnlyWindow = snapshot(suppressedOnly.v, suppressedOnly.h.document, 1);
	assert.equal(clearedOnlyWindow.normalizedBufferCount, 1);
	assert.equal(clearedOnlyWindow.lastBatchNewIdCount, 0);
	assert.equal(clearedOnlyWindow.lastSuccessfulBatchEmpty, true);
	assert.equal(clearedOnlyWindow.status, genuinelyEmpty.status);

	return { thresholdMs: threshold, repeatedNonempty, genuinelyEmpty,
		clearedOnlyWindow, interpretation: 'normal repeated ring suffix passes; synthetic old-only window reproduces but is not established as logread-reachable' };
}

function runResolverFenceFault() {
	const dir = fs.mkdtempSync(path.join(__dirname, '.frontend-resolve-fault-'));
	try {
		const sourcePath = path.join(repo,
			'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/view/status/fwlive.js');
		const original = fs.readFileSync(sourcePath, 'utf8');
		const guard = '\t\t\tif (gen !== this.resolveGeneration) return;';
		assert.equal(original.split(guard).length - 1, 1, 'fault target is unique');
		const faultPath = path.join(dir, 'fwlive-fault.js');
		fs.writeFileSync(faultPath, original.replace(guard, '\t\t\t/* fault: stale-result fence removed */'));

		let loader = fs.readFileSync(path.join(repo, 'tests/lib/load-fwlive-view.js'), 'utf8');
		loader = loader.replace("require('./load-fwlive-module')",
			`require(${JSON.stringify(path.join(repo, 'tests/lib/load-fwlive-module.js'))})`);
		loader = loader.replace("require('./rpc-expect')",
			`require(${JSON.stringify(path.join(repo, 'tests/lib/rpc-expect.js'))})`);
		loader = loader.replace("require('./luci-e-harness')",
			`require(${JSON.stringify(path.join(repo, 'tests/lib/luci-e-harness.js'))})`);
		const viewPathPattern = /const VIEW_PATH = path\.join\([\s\S]*?\n\);/;
		assert.match(loader, viewPathPattern, 'loader view path is locatable');
		loader = loader.replace(viewPathPattern, `const VIEW_PATH = ${JSON.stringify(faultPath)};`);
		const loaderPath = path.join(dir, 'load-fault-view.js');
		fs.writeFileSync(loaderPath, loader);

		let test = fs.readFileSync(path.join(repo, 'tests/fwlive-view-fetch-budget.test.js'), 'utf8');
		test = test.replace("require('./lib/load-fwlive-view')", `require(${JSON.stringify(loaderPath)})`);
		test = test.replace(/async function main\(\) \{[\s\S]*?\n\}\n\nmain\(\)\.catch\([\s\S]*?\n\}\);\s*$/, '');
		assert.doesNotMatch(test, /main\(\)\.catch/);
		test += `\n(async () => { await testPagehideDuringHostnameResolution(); })().catch(err => { console.error(err.stack || err); process.exit(1); });\n`;
		const testPath = path.join(dir, 'fetch-budget-fault-probe.js');
		fs.writeFileSync(testPath, test);
		const child = spawnSync(process.execPath, [testPath], { encoding: 'utf8', timeout: 10000 });
		return {
			fault: 'removed only post-await resolveGeneration equality guard in disposable source copy',
			target: 'existing testPagehideDuringHostnameResolution oracle from tests/fwlive-view-fetch-budget.test.js',
			exitCode: child.status,
			stdout: child.stdout.trim(),
			stderr: child.stderr.trim().replaceAll(dir, '<TEMP_PROBE_DIR>')
		};
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
}

const clear = clearStalenessProbe();
const fault = runResolverFenceFault();
assert.notEqual(fault.exitCode, 0, 'existing test must detect removed stale-result fence');
console.log(JSON.stringify({ clearStalenessProbe: clear, sourceCopyFault: fault }, null, 2));
