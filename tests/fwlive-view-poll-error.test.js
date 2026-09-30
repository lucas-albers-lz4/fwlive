#!/usr/bin/env node
'use strict';

/**
 * View poll contract (#233 / #240 Tier 1.4): reply.error must reach lastPollError + status banner.
 */

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

const SAMPLE_ROW = {
	id: 1,
	time: 1704067200,
	msg: 'fw4: IN=wan OUT= SRC=192.0.2.1 DST=192.0.2.2 PROTO=TCP SPT=1234 DPT=443'
};

function fail(msg) {
	console.error(msg);
	process.exit(1);
}

async function testPollErrorField() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return { log: [], error: 'filter_failed' };
			}
		}
	});
	const view = h.view;

	await view.fetchEntries();
	assert.strictEqual(view.lastPollError, true, 'reply.error must set lastPollError');

	view.updateStatus();
	const status = h.document.getElementById('fwlive-status');
	assert.ok(status, 'fwlive-status must exist after render');
	assert.match(status.textContent, /could not read the firewall log/i,
		'a typed error reply must show the router-read message');
	assert.strictEqual(view.lastBatchNewIdCount, 0,
		'failed poll must reset lastBatchNewIdCount');
	console.log('fwlive-view poll-error: reply.error banner OK');
}

async function testPollErrorResetsBatchNewIdCount() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return { log: [], error: 'filter_failed' };
			}
		}
	});
	const view = h.view;
	view.lastBatchNewIdCount = 7;

	await view.fetchEntries();
	assert.strictEqual(view.lastPollError, true, 'reply.error must set lastPollError');
	assert.strictEqual(view.lastBatchNewIdCount, 0,
		'failPollReply must clear the previous batch new-id count');
	console.log('fwlive-view poll-error: lastBatchNewIdCount reset OK');
}

async function testPollHappyPath() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return { log: [SAMPLE_ROW] };
			}
		}
	});
	const view = h.view;

	await view.fetchEntries();
	assert.strictEqual(view.lastPollError, false, 'happy poll must clear lastPollError');
	assert.deepStrictEqual(view.entries.map((row) => row.id), ['log:' + SAMPLE_ROW.id],
		'happy poll must contain exactly the returned row');
	console.log('fwlive-view poll-error: happy path OK');
}

async function testPollBadShape() {
	for (const bad of [null, [], { log: null }]) {
		const h = loadFwliveView({
			rpcMocks: {
				'fwlive.poll': async function() { return bad; }
			}
		});
		await h.view.fetchEntries();
		assert.strictEqual(h.view.lastPollError, true,
			'bad poll shape must set lastPollError: ' + JSON.stringify(bad));
	}
	console.log('fwlive-view poll-error: bad shape OK');
}

async function testPollTransportThrow() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				throw new Error('network down');
			}
		}
	});
	await h.view.fetchEntries();
	assert.strictEqual(h.view.lastPollError, true, 'transport throw must set lastPollError');
	console.log('fwlive-view poll-error: transport throw OK');
}

async function testLoggingToggleInvalidatesOlderStatusRead() {
	let startedOldRead;
	let releaseOldRead;
	let statusCalls = 0;
	const oldReadStarted = new Promise((resolve) => { startedOldRead = resolve; });
	const oldReadGate = new Promise((resolve) => { releaseOldRead = resolve; });
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.logging_status': async function() {
				statusCalls++;
				if (statusCalls === 1) {
					startedOldRead();
					await oldReadGate;
					return { wan_log: false, warnings: [] };
				}
				return { wan_log: true, warnings: [] };
			}
		}
	});
	const view = h.view;
	view.loggingStatus = { wan_log: false, warnings: [] };

	/* Keep the poll epoch constant: this covers request ordering within one view epoch. */
	const oldRead = view.loadLoggingStatus(0);
	await oldReadStarted;
	await view.runLoggingToggle({
		wanLog: true,
		call: async function() { return { ok: true }; },
		initialUi: function() {},
		successNotice: function() { return ''; }
	});
	assert.equal(view.loggingStatus.wan_log, true,
		'the toggle refresh must commit its newer WAN logging state');

	releaseOldRead();
	await oldRead;
	assert.equal(view.loggingStatus.wan_log, true,
		'an older same-epoch recovery read must not overwrite a successful toggle');
	console.log('fwlive-view poll-error: logging toggle invalidates older status reads OK');
}

async function testLoggingWarningDoesNotOverridePollCause() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.logging_status': async function () {
				return { warnings: ['legacy_iptables_detected'] };
			}
		}
	});
	const view = h.view;
	view.lastPollError = true;
	view.lastPollErrorCode = 'filter_failed';
	await view.loadLoggingStatus();
	const status = h.document.getElementById('fwlive-status');
	assert.match(String(status.textContent), /could not read the firewall log/i,
		'logging warnings must not override the typed poll cause');
	assert.match(String(h.document.getElementById('fwlive-backend').textContent), /legacy iptables table/i);
	view.lastPollErrorCode = 'jsonfilter_missing';
	view.updateStatus();
	assert.equal(String(status.textContent), 'Installation is incomplete. Reinstall luci-app-fwlive.');
	await view.fetchEntries();
	view.updateStatus();
	assert.equal(view.lastPollError, false, 'a successful poll must clear the typed installation error');
	assert.doesNotMatch(String(status.textContent), /Installation is incomplete/i);
	console.log('fwlive-view poll-error: logging warnings and ordinary installation recovery OK');
}

async function testPollNonStringMsgSurvives() {
	const validMsg =
		'fw4: IN=wan OUT= SRC=192.0.2.1 DST=192.0.2.2 PROTO=TCP SPT=1234 DPT=443';
	const shapes = [42, { nested: true }, ['arr'], true];
	const log = [];
	const expectedIds = [];
	for (let i = 0; i < shapes.length; i++) {
		log.push({ id: 100 + i, msg: shapes[i] });
		log.push({ id: 200 + i, time: 1704067200, msg: validMsg });
		expectedIds.push('log:' + (200 + i));
	}

	const h = loadFwliveView();
	assert.doesNotThrow(() => h.view.normalizePollBatch(log));
	const batch = h.view.normalizePollBatch(log);
	assert.equal(batch.rows.length, shapes.length,
		'normalizePollBatch must keep one valid row after each non-string msg');
	assert.deepEqual(batch.rows.map((row) => row.id), expectedIds);

	const poll = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return { log: log };
			}
		}
	});
	await poll.view.fetchEntries();
	assert.strictEqual(poll.view.lastPollError, false,
		'mixed non-string msg batch must not fail the poll');
	assert.deepEqual(
		poll.view.entries.map((row) => row.id),
		expectedIds,
		'fetchEntries must keep the valid firewall rows after each non-string msg'
	);
	console.log('fwlive-view poll-error: non-string msg batch OK');
}

async function testConstructorHintDoesNotPaintObjectSource() {
	const msg =
		'constructor: IN=wan OUT= SRC=192.0.2.1 DST=192.0.2.2 PROTO=TCP SPT=1234 DPT=443';
	const h = loadFwliveView();
	h.view.rulesMap = {};
	const batch = h.view.normalizePollBatch([{ id: 1, time: 1704067200, msg: msg }]);
	assert.equal(batch.rows.length, 1, 'constructor-prefixed firewall line must stay a row');
	assert.equal(batch.rows[0].rule_hint, 'constructor');
	assert.equal(batch.rows[0].rule_label, 'constructor',
		'Rule label must not be the Object constructor source');
	assert.equal(h.view.resolveRuleLabel('__proto__'), '__proto__');
	assert.equal(h.view.resolveRuleLabel('toString'), 'toString');
	h.view.rulesMap = { constructor: 'Allow-ctor' };
	assert.equal(h.view.resolveRuleLabel('constructor'), 'Allow-ctor');
	console.log('fwlive-view poll-error: constructor rule hint OK');
}

async function testPollErrorClasses() {
	const h = loadFwliveView({});
	const view = h.view;
	const status = h.document.getElementById('fwlive-status');
	const cases = [
		[null, 'Connection lost — retrying…'],
		['log_read_failed', 'The router could not read the firewall log — retrying…'],
		['filter_failed', 'The router could not read the firewall log — retrying…'],
		['filter_tempfile_failed', 'The router could not read the firewall log — retrying…'],
		['jsonfilter_missing', 'Installation is incomplete. Reinstall luci-app-fwlive.'],
		['classifier_missing', 'Installation is incomplete. Reinstall luci-app-fwlive.']
	];
	view.lastPollError = true;
	for (const [code, expected] of cases) {
		view.lastPollErrorCode = code;
		view.updateStatus();
		assert.ok(String(status.textContent).startsWith(expected),
			`${code} must map to "${expected}", got "${status.textContent}"`);
	}
	console.log('fwlive-view poll-error: error classes OK');
}

async function testSummaryPollErrorRefreshesStatus() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return { log: [], error: 'filter_failed' };
			}
		}
	});
	const view = h.view;
	view.summaryMode = true;
	view.summaryRowsShown = false;

	await view.runPollRequest(view.currentPollEpoch());
	const status = h.document.getElementById('fwlive-status');
	assert.match(status.textContent, /could not read the firewall log/i,
		'summary-mode poll errors must refresh the status line');
	console.log('fwlive-view poll-error: summary error status OK');
}

(async function main() {
	try {
		await testPollErrorField();
		await testPollErrorResetsBatchNewIdCount();
		await testPollHappyPath();
		await testPollBadShape();
		await testPollTransportThrow();
		await testLoggingToggleInvalidatesOlderStatusRead();
		await testLoggingWarningDoesNotOverridePollCause();
		await testPollNonStringMsgSurvives();
		await testConstructorHintDoesNotPaintObjectSource();
		await testPollErrorClasses();
		await testSummaryPollErrorRefreshesStatus();
		console.log('fwlive-view poll-error tests passed');
	} catch (e) {
		fail(e && e.stack ? e.stack : String(e));
	}
})();
