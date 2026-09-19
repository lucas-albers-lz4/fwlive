#!/usr/bin/env node
'use strict';

/**
 * View logging handlers: preserve their intentionally different UI and
 * side-effect sequencing before any shared-runner extraction.
 */

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

const STORAGE_KEY = 'fwlive-logging-consent-v1';

function makeHarness(method, reply, storage, options) {
	options = options || {};
	let calls = 0;
	const h = loadFwliveView({
		storage: storage,
		rawRpcKeys: options.rawReply ? { ['fwlive.' + method]: true } : undefined,
		rpcMocks: {
			['fwlive.' + method]: async function () {
				calls++;
				if (reply instanceof Error) throw reply;
				return reply;
			}
		}
	});

	let statusLoads = 0;
	let emptyUpdates = 0;
	let toolbarUpdates = 0;
	h.view.loadLoggingStatus = async function () {
		statusLoads++;
	};
	h.view.updateEmptyStateUi = function () {
		emptyUpdates++;
	};
	h.view.updateLoggingToolbarUi = function () {
		toolbarUpdates++;
	};

	return {
		h: h,
		view: h.view,
		calls: function () {
			return calls;
		},
		statusLoads: function () {
			return statusLoads;
		},
		emptyUpdates: function () {
			return emptyUpdates;
		},
		toolbarUpdates: function () {
			return toolbarUpdates;
		}
	};
}

function notice(view) {
	return String(view.loggingNotice);
}

async function testEnableReply(reply, expectedNotice, shouldPersist) {
	const storage = {};
	const x = makeHarness('enable_wan_logging', reply, storage);
	await x.view.handleEnableLogging();

	assert.equal(notice(x.view), expectedNotice);
	assert.equal(x.view.loggingBusy, false, 'enable finally must clear busy');
	assert.equal(x.statusLoads(), 1, 'enable must refresh status once');
	assert.equal(x.emptyUpdates(), 2, 'enable updates empty state in preamble and finally');
	assert.equal(x.toolbarUpdates(), 2, 'enable updates toolbar in preamble and finally');
	if (shouldPersist) assert.equal(x.h.localStorage.getItem(STORAGE_KEY), '1');
	else assert.equal(x.h.localStorage.getItem(STORAGE_KEY), null);
}

async function testEnableVariants() {
	await testEnableReply(null, 'Could not enable logging.', false);
	await testEnableReply(
		{ ok: false, error: 'nf_log_missing' },
		'Cannot enable logging until kernel log modules are installed.',
		false
	);
	await testEnableReply(
		{ ok: false, error: 'firewall_changes_pending' },
		'Another change is staged for the firewall; apply or revert it first.',
		false
	);
	await testEnableReply({ ok: false, error: 'other' }, 'Could not enable logging.', false);
	await testEnableReply(
		{ ok: true, changed: true },
		'WAN drop/reject logging is on. Blocked inbound traffic should appear here as it happens — not normal LAN browsing.',
		true
	);
	await testEnableReply({ ok: true, changed: false }, 'WAN logging is already enabled.', true);
	await testEnableReply(
		new Error('permission denied'),
		'Administrator access is required to enable logging.',
		false
	);
	console.log('fwlive-view logging: enable variants and persistence OK');
}

async function testRawFalsyReply() {
	const x = makeHarness('enable_wan_logging', null, {}, { rawReply: true });
	await x.view.handleEnableLogging();
	assert.equal(notice(x.view), 'Could not enable logging.');
	assert.equal(x.view.loggingBusy, false, 'raw falsy reply must clear busy');
	assert.equal(x.h.localStorage.getItem(STORAGE_KEY), null);
	console.log('fwlive-view logging: raw falsy reply defensive path OK');
}

async function testDisableReply(reply, expectedNotice) {
	const storage = {};
	const x = makeHarness('disable_wan_logging', reply, storage);
	x.view.loggingNotice = 'stale notice';
	await x.view.handleDisableLogging();

	assert.equal(notice(x.view), expectedNotice);
	assert.equal(x.view.loggingBusy, false, 'disable finally must clear busy');
	assert.equal(x.statusLoads(), 1, 'disable must refresh status once');
	assert.equal(x.emptyUpdates(), 1, 'disable only updates empty state in finally');
	assert.equal(x.toolbarUpdates(), 2, 'disable updates toolbar in preamble and finally');
	assert.equal(x.h.localStorage.getItem(STORAGE_KEY), null, 'disable never persists consent');
}

async function testDisableVariants() {
	await testDisableReply(null, 'Could not disable logging.');
	await testDisableReply(
		{ ok: false, error: 'firewall_changes_pending' },
		'Another change is staged for the firewall; apply or revert it first.'
	);
	await testDisableReply({ ok: false, error: 'other' }, 'Could not disable logging.');
	await testDisableReply({ ok: true, changed: true }, 'WAN drop/reject logging is off.');
	await testDisableReply({ ok: true, changed: false }, '');
	await testDisableReply(
		new Error('permission denied'),
		'Administrator access is required to disable logging.'
	);
	console.log('fwlive-view logging: disable variants and no-change behavior OK');
}

async function testBusyReentry() {
	let rpcCalled = false;
	const h = loadFwliveView({
		rpcMocks: {
			'fwlive.enable_wan_logging': async function () {
				rpcCalled = true;
				return { ok: true, changed: true };
			}
		}
	});
	let emptyUpdates = 0;
	let toolbarUpdates = 0;
	h.view.updateEmptyStateUi = function () {
		emptyUpdates++;
	};
	h.view.updateLoggingToolbarUi = function () {
		toolbarUpdates++;
	};
	h.view.loggingBusy = true;
	await h.view.handleEnableLogging();
	assert.equal(rpcCalled, false, 'busy re-entry must not call RPC');
	assert.equal(emptyUpdates, 0);
	assert.equal(toolbarUpdates, 0);
	assert.equal(h.view.loggingBusy, true, 'busy re-entry must leave owner busy state alone');
	console.log('fwlive-view logging: busy re-entry OK');
}

(async function main() {
	try {
		await testEnableVariants();
		await testRawFalsyReply();
		await testDisableVariants();
		await testBusyReentry();
		console.log('fwlive-view logging-toggle tests passed');
	} catch (e) {
		console.error(e && e.stack ? e.stack : String(e));
		process.exit(1);
	}
})();
