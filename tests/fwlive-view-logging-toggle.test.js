#!/usr/bin/env node
'use strict';

/**
 * View logging handlers: preserve their intentionally different UI and
 * side-effect sequencing before any shared-runner extraction.
 */

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

const STORAGE_KEY = 'fwlive-logging-consent-v1';
const WRONG_TYPE_REPLIES = [null, [], 'bad', 7];

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
	for (const reply of WRONG_TYPE_REPLIES)
		await testEnableReply(reply, 'Could not enable logging.', false);
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
	for (const reply of WRONG_TYPE_REPLIES)
		await testDisableReply(reply, 'Could not disable logging.');
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

const LOGGING_STATUS_DEFAULT = {
	wan_zone: null,
	wan_zone_candidates: [],
	wan_log: false,
	wan_log_limit: null,
	nf_log_ipv4: false,
	nf_log_ipv6: false,
	ready: false,
	weak_device: false,
	blockers: [],
	warnings: []
};

async function testLoggingStatusDefaultReply() {
	for (const reply of WRONG_TYPE_REPLIES) {
		const h = loadFwliveView({
			defaultRpc: async function (key) {
				if (key === 'fwlive.logging_status') return reply;
				return {};
			}
		});
		h.view.updateBackendUi = function () {};
		h.view.updateLoggingToolbarUi = function () {};
		h.view.updateEmptyStateUi = function () {};

		await h.view.loadLoggingStatus();
		assert.deepEqual(
			h.view.loggingStatus,
			LOGGING_STATUS_DEFAULT,
			'logging_status wrong-type reply must use the declared full default: ' + JSON.stringify(reply)
		);
		assert.equal(h.view.weakDevice, false);
	}
	console.log('fwlive-view logging: logging_status default shape OK');
}

function testMktempFailedBackendLabel() {
	const h = loadFwliveView();
	h.document.querySelector = function () {
		return null;
	};
	h.view.updateEmptyStateUi = function () {};
	const label = h.document.getElementById('fwlive-backend');
	assert.ok(label, 'backend label must render');
	label.classList = {
		toggle: function () {}
	};
	h.view.firewallBackend = 'nft';
	h.view.lastRulesError = 'mktemp_failed';
	h.view.updateBackendUi();
	assert.equal(
		String(label.textContent),
		'using fw4 \u00b7 Rule labels unavailable — temp file failed',
		'mktemp_failed must use the specialized temp-file notice'
	);
	h.view.lastRulesError = 'nft_failed';
	h.view.updateBackendUi();
	assert.equal(
		String(label.textContent),
		'using fw4 \u00b7 Rule labels unavailable',
		'other rules errors must keep the generic unavailable notice'
	);
	console.log('fwlive-view logging: mktemp_failed backend label OK');
}

function testBackendDisplayLabels() {
	const h = loadFwliveView();
	h.document.querySelector = function () {
		return null;
	};
	h.view.updateEmptyStateUi = function () {};
	const label = h.document.getElementById('fwlive-backend');
	assert.ok(label, 'backend label must render');
	label.classList = {
		toggle: function () {}
	};
	h.view.lastRulesError = null;

	h.view.firewallBackend = 'nft';
	h.view.updateBackendUi();
	assert.equal(String(label.textContent), 'using fw4', 'nft backend label');

	h.view.firewallBackend = 'iptables';
	h.view.updateBackendUi();
	assert.equal(String(label.textContent), '', 'removed iptables backend has no using-* label');

	h.view.firewallBackend = 'unknown';
	h.view.updateBackendUi();
	assert.equal(String(label.textContent), '', 'unknown backend has no using-* label');

	h.view.lastRulesError = 'no_backend';
	h.view.updateBackendUi();
	assert.equal(
		String(label.textContent),
		'Rule labels unavailable',
		'unknown + no_backend must still render the error as text'
	);
	console.log('fwlive-view logging: nft/unknown backend labels OK');
}

function testLegacyIptablesWarning() {
	const h = loadFwliveView();
	h.document.querySelector = function () {
		return null;
	};
	h.view.updateEmptyStateUi = function () {};
	const label = h.document.getElementById('fwlive-backend');
	assert.ok(label, 'backend label must render');
	label.classList = {
		toggle: function (name, on) {
			this[name] = !!on;
		}
	};
	h.view.firewallBackend = 'nft';
	h.view.lastRulesError = null;
	h.view.loggingStatus = { warnings: [] };
	h.view.updateBackendUi();
	assert.equal(String(label.textContent), 'using fw4', 'absent warning leaves nft label');
	assert.equal(label.classList['fwlive-backend-warn'], false, 'absent warning is not warn-tint');

	h.view.loggingStatus = { warnings: ['legacy_iptables_detected'] };
	h.view.updateBackendUi();
	assert.equal(
		String(label.textContent),
		'using fw4 \u00b7 Live view may be incomplete — a legacy iptables table is registered',
		'legacy_iptables_detected must render as text beside the nft label'
	);
	assert.equal(label.classList['fwlive-backend-warn'], true, 'legacy warning uses warn-tint');
	assert.deepEqual(
		label._innerHTMLWrites || [],
		[],
		'backend span must not write innerHTML'
	);
	console.log('fwlive-view logging: legacy_iptables_detected warning OK');
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
		await testLoggingStatusDefaultReply();
		testMktempFailedBackendLabel();
		testBackendDisplayLabels();
		testLegacyIptablesWarning();
		await testBusyReentry();
		console.log('fwlive-view logging-toggle tests passed');
	} catch (e) {
		console.error(e && e.stack ? e.stack : String(e));
		process.exit(1);
	}
})();
