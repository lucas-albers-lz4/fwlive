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
	assert.match(status.textContent, /Connection lost/i,
		'error reply must show connection-lost banner');
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

async function testTimeoutRecoveryThrowKeepsPollSuccess() {
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return { log: [SAMPLE_ROW] };
			}
		}
	});
	const view = h.view;
	view.lastPollErrorCode = 'timeout_missing';
	view.loadRulesMap = async function() {
		throw new Error('recovery ui');
	};
	await view.runPollRequest(view.currentPollEpoch());
	assert.strictEqual(view.lastPollError, false, 'recovery throw must not mark the poll failed');
	assert.notStrictEqual(
		view.lastPollErrorCode,
		'timeout_missing',
		'successful poll must clear timeout_missing'
	);
	assert.ok(view.entries.length >= 1, 'successful poll must keep the row');
	console.log('fwlive-view poll-error: timeout recovery throw OK');
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

async function testMissingTimeoutHasAccuratePollError() {
	let timeoutMissing = false;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() {
				return timeoutMissing
					? { log: [], error: 'timeout_missing' }
					: { log: [SAMPLE_ROW] };
			},
			'fwlive.rules': async function() {
				return timeoutMissing
					? { backend: 'unknown', rules: {}, error: 'timeout_missing' }
					: { backend: 'nft', rules: {} };
			},
			'fwlive.logging_status': async function() {
				return { warnings: timeoutMissing ? ['timeout_missing'] : [] };
			}
		}
	});
	const view = h.view;
	const status = h.document.getElementById('fwlive-status');
	const backend = h.document.getElementById('fwlive-backend');
	assert.ok(status, 'fwlive-status must exist after render');
	assert.ok(backend, 'fwlive-backend must exist after render');

	await Promise.all([view.loadRulesMap(), view.loadLoggingStatus()]);
	assert.ok(/using fw4/i.test(String(backend.textContent)),
		'a healthy install must retain its backend label');

	/* A stale warning must not erase the known backend or coexist in place of
	 * a more useful rules/legacy-table explanation. */
	view.loggingStatus = { warnings: ['timeout_missing', 'legacy_iptables_detected'] };
	view.lastRulesError = 'no_backend';
	view.updateBackendUi();
	assert.ok(/using fw4/i.test(String(backend.textContent)),
		'a stale timeout warning must not blank a usable backend label');
	assert.ok(/Some rule names may be missing/i.test(String(backend.textContent)),
		'a stale timeout warning must not hide the rules-map diagnosis');
	assert.ok(/legacy iptables table/i.test(String(backend.textContent)),
		'a timeout warning must not hide a coexisting legacy-table warning');
	assert.ok(!/timeout/i.test(String(backend.textContent)),
		'a stale warning during a healthy poll must not appear in the backend label');

	/* The next poll itself identifies a provider removed while this page is
	 * open; it must not depend on logging_status being refreshed first. */
	await Promise.all([view.loadRulesMap(), view.loadLoggingStatus()]);
	timeoutMissing = true;
	await view.fetchEntries();
	view.updateStatus();
	assert.equal(String(status.textContent), 'Installation is incomplete. Reinstall luci-app-fwlive.',
		'a timeout_missing poll reply must show the concise repair message only');
	assert.ok(/using fw4/i.test(String(backend.textContent)),
		'a timeout_missing poll reply must preserve the known backend');
	assert.ok(!/timeout/i.test(String(backend.textContent)),
		'a timeout_missing diagnosis must stay out of the backend label');

	/* A successful poll after repair triggers fresh rules and warning reads;
	 * verify the banner clears and backend context remains in this session. */
	timeoutMissing = false;
	await view.fetchEntries();
	view.updateStatus();
	assert.ok(!/Connection lost|Installation is incomplete/i.test(String(status.textContent)),
		'a healthy poll after repair must clear the poll error banner');
	assert.ok(/using fw4/i.test(String(backend.textContent)),
		'a healthy poll after repair must restore the backend label');
	assert.ok(!/timeout|Some rule names may be missing/i.test(String(backend.textContent)),
		'a healthy poll after repair must clear stale rules diagnostics and keep provider details hidden');
	console.log('fwlive-view poll-error: missing timeout, stale warning, and recovery OK');
}

async function testBufferedRuleLabelsRefreshAfterTimeoutRecovery() {
	const raw = {
		id: 77,
		time: 1780797240,
		msg: '[  239.247521] fwlive-pingIN=lo OUT= MAC=00:00:00:00:00:00:00:00:00:00:00:00:08:00 SRC=127.0.0.1 DST=127.0.0.1 LEN=84 TOS=0x00 PREC=0x00 TTL=64 ID=6376 DF PROTO=ICMP TYPE=8 CODE=0 ID=3139 SEQ=2'
	};
	const recoveredLabel = 'Recovered ping rule';

	for (const paused of [true, false]) {
		const h = loadFwliveView({
			rpcMocks: {
				'fwlive.poll': async function() { return { log: paused ? [] : [raw] }; },
				'fwlive.rules': async function() {
					return { backend: 'nft', rules: { 'fwlive-ping': recoveredLabel } };
				},
				'fwlive.logging_status': async function() { return { warnings: [] }; }
			}
		});
		const view = h.view;
		view.rulesMap = {};
		view.entries = view.normalizePollBatch([raw]).rows;
		view.tablePaused = paused;
		view.lastPollError = true;
		view.lastPollErrorCode = 'timeout_missing';
		const oldLabel = view.entries[0].rule_label;
		assert.notEqual(oldLabel, recoveredLabel, 'fixture must begin with a fallback rule label');
		const paints = [];
		let refreshCalls = 0;
		const refreshBufferedRuleLabels = view.refreshBufferedRuleLabels;
		view.refreshBufferedRuleLabels = function() {
			refreshCalls++;
			return refreshBufferedRuleLabels.apply(this, arguments);
		};
		view.renderRows = (force) => paints.push({ force, label: view.entries[0].rule_label });

		await view.fetchEntries();
		assert.equal(view.entries.length, 1,
			'provider recovery must keep the buffered row absent from the current poll when paused');
		assert.equal(view.entries[0].rule_label, recoveredLabel,
			'provider recovery must relabel retained rows from the refreshed map');
		assert.equal(refreshCalls, 1,
			'timeout recovery must refresh buffered labels only in loadRulesMap');
		if (paused) {
			assert.equal(paints.length, 0, 'recovery must not paint while the table is paused');
		} else {
			assert.ok(paints.some((paint) => paint.force && paint.label === recoveredLabel),
				'active recovery must repaint rows with the refreshed rule label');
		}
	}

	let releaseRecovery;
	let startedRules;
	let startedLoggingStatus;
	const rulesStarted = new Promise((resolve) => { startedRules = resolve; });
	const loggingStatusStarted = new Promise((resolve) => { startedLoggingStatus = resolve; });
	const recoveryGate = new Promise((resolve) => { releaseRecovery = resolve; });
	const stale = loadFwliveView({
		rpcMocks: {
			'fwlive.poll': async function() { return { log: [] }; },
			'fwlive.rules': async function() {
				startedRules();
				await recoveryGate;
				return { backend: 'nft', rules: { 'fwlive-ping': recoveredLabel } };
			},
			'fwlive.logging_status': async function() {
				startedLoggingStatus();
				await recoveryGate;
				return { warnings: [], weak_device: true };
			}
		}
	});
	const staleView = stale.view;
	staleView.rulesMap = { 'fwlive-ping': 'Previously known ping label' };
	staleView.firewallBackend = 'iptables';
	staleView.lastRulesError = 'previous_rules_error';
	staleView.loggingStatus = { warnings: ['legacy_iptables_detected'] };
	staleView.weakDevice = false;
	staleView.entries = staleView.normalizePollBatch([raw]).rows;
	staleView.tablePaused = true;
	staleView.lastPollError = true;
	staleView.lastPollErrorCode = 'timeout_missing';
	const staleLabel = staleView.entries[0].rule_label;
	const previousRulesMap = staleView.rulesMap;
	const previousLoggingStatus = staleView.loggingStatus;
	let epoch = 0;
	staleView.currentPollEpoch = () => epoch;
	const stalePaints = [];
	staleView.renderRows = (force) => stalePaints.push(force);
	const recovery = staleView.fetchEntries();
	await Promise.all([rulesStarted, loggingStatusStarted]);
	epoch++;
	releaseRecovery();
	await recovery;
	assert.equal(staleView.entries[0].rule_label, staleLabel,
		'a rules response from an old poll epoch must not relabel stale buffered rows');
	assert.strictEqual(staleView.rulesMap, previousRulesMap,
		'a rules response from an old epoch must not replace rulesMap');
	assert.equal(staleView.firewallBackend, 'iptables',
		'a rules response from an old epoch must not replace the backend');
	assert.equal(staleView.lastRulesError, 'previous_rules_error',
		'a rules response from an old epoch must not replace the rules error');
	assert.strictEqual(staleView.loggingStatus, previousLoggingStatus,
		'a status response from an old epoch must not replace loggingStatus');
	assert.equal(staleView.weakDevice, false,
		'a status response from an old epoch must not replace weakDevice');
	assert.equal(stalePaints.length, 0, 'a stale recovery epoch must not paint rows');
	console.log('fwlive-view poll-error: buffered rule labels refresh safely after provider recovery OK');
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
	let timeoutMissing = true;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.logging_status': async function () {
				return { warnings: timeoutMissing ? ['timeout_missing'] : [] };
			}
		}
	});
	const view = h.view;
	const status = h.document.getElementById('fwlive-status');
	view.updateLoggingToolbarUi = function () {};
	view.updateEmptyStateUi = function () {};
	view.lastPollError = true;
	view.lastPollErrorCode = 'filter_failed';

	await view.loadLoggingStatus();
	assert.match(String(status.textContent), /Connection lost/i,
		'a stale timeout_missing warning must not override another poll error');
	assert.ok(!/timeout/i.test(h.document.getElementById('fwlive-backend').textContent),
		'logging_status warnings must not add timeout details to the backend label');

	view.lastPollErrorCode = 'timeout_missing';
	view.updateStatus();
	assert.equal(String(status.textContent), 'Installation is incomplete. Reinstall luci-app-fwlive.',
		'a typed timeout_missing poll error must show the repair message');
	assert.ok(!/timeout/i.test(h.document.getElementById('fwlive-backend').textContent),
		'a typed timeout_missing poll error must not add a second diagnosis to the backend label');

	timeoutMissing = false;
	await view.loadLoggingStatus();
	assert.equal(String(status.textContent), 'Installation is incomplete. Reinstall luci-app-fwlive.',
		'only a later successful poll may clear the typed provider error');
	view.lastPollError = false;
	view.lastPollErrorCode = null;
	view.updateStatus();
	assert.ok(!/Installation is incomplete/i.test(String(status.textContent)),
		'a successful poll must clear the provider diagnosis');
	assert.ok(/using fw4/i.test(String(h.document.getElementById('fwlive-backend').textContent)),
		`the backend label must retain context: ${h.document.getElementById('fwlive-backend').textContent}`);
	assert.ok(!/timeout/i.test(String(h.document.getElementById('fwlive-backend').textContent)),
		'backend label must not expose provider details after recovery');
	console.log('fwlive-view poll-error: logging status warnings do not override typed poll errors OK');
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
	assert.match(status.textContent, /Connection lost/i,
		'summary-mode poll errors must refresh the status line');
	console.log('fwlive-view poll-error: summary error status OK');
}

(async function main() {
	try {
		await testPollErrorField();
		await testPollErrorResetsBatchNewIdCount();
		await testPollHappyPath();
		await testTimeoutRecoveryThrowKeepsPollSuccess();
		await testPollBadShape();
		await testPollTransportThrow();
		await testMissingTimeoutHasAccuratePollError();
		await testBufferedRuleLabelsRefreshAfterTimeoutRecovery();
		await testLoggingToggleInvalidatesOlderStatusRead();
		await testLoggingWarningDoesNotOverridePollCause();
		await testPollNonStringMsgSurvives();
		await testConstructorHintDoesNotPaintObjectSource();
		await testSummaryPollErrorRefreshesStatus();
		console.log('fwlive-view poll-error tests passed');
	} catch (e) {
		fail(e && e.stack ? e.stack : String(e));
	}
})();
