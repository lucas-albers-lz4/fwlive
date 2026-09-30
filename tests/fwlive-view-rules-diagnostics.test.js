#!/usr/bin/env node
'use strict';

// Host state/text contracts; native disclosure interaction is tested in Playwright.
const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

function ui(h) {
	return {
		label: h.document.getElementById('fwlive-backend'),
		details: h.document.getElementById('fwlive-rules-details'),
		body: h.document.getElementById('fwlive-rules-details-body')
	};
}

async function testOutcomesAndRecovery() {
	const h = loadFwliveView();
	const { label, details, body } = ui(h);
	const causes = {
		mktemp_failed: /temporary file/,
		tsv_failed: /process firewall rule names/,
		no_backend: /read the active firewall rules/
	};
	for (const truncated of [false, true]) {
		for (const error of [undefined, ...Object.keys(causes)]) {
			h.setRpcMock('fwlive.rules', async () => ({ backend: 'nft', rules: {}, truncated, error }));
			await h.view.loadRulesMap();
			assert.equal(h.view.rulesMapTruncated, truncated);
			assert.equal(h.view.lastRulesError, error || null);
			const degraded = truncated || !!error;
			assert.equal(details.style.display, degraded ? '' : 'none');
			const visibleWarning = truncated || error;
			assert.equal(/Some rule names may be missing/.test(label.textContent), !!visibleWarning);
			assert.equal(/truncated=true/.test(body.textContent), truncated);
			if (error && degraded) {
				assert.match(body.textContent, causes[error]);
				assert.ok(body.textContent.includes('(' + error + ')'));
			}

			if (degraded) {
				assert.match(body.textContent, /does not change your firewall rules/);
				assert.match(body.textContent, /Searching by a friendly rule name may miss/);
				assert.doesNotMatch(body.textContent, /capture is unaffected|names loaded/);
			}
		}
	}
	details.open = true;
	h.view.updateBackendUi();
	assert.equal(details.open, true, 'routine updates must preserve an opened disclosure');
	h.setRpcMock('fwlive.rules', async () => ({ backend: 'nft', rules: {}, truncated: false }));
	await h.view.loadRulesMap();
	assert.equal(details.style.display, 'none');
	assert.equal(details.open, false, 'recovery must close the hidden disclosure');
	assert.equal(body.textContent, '');
	assert.equal(String(label.textContent), 'using fw4');
}

async function testRefreshRetainsSnapshot() {
	for (const rules of [{ 'allow-ssh': 'Allow SSH' }, {}]) {
		const h = loadFwliveView({ rpcMocks: {
			'fwlive.rules': async () => ({ backend: 'unknown', rules, truncated: true, error: 'no_backend' })
		} });
		await h.view.loadRulesMap();
		const map = h.view.rulesMap;
		h.setRpcMock('fwlive.rules', async () => { throw new Error('transport failed'); });
		await h.view.loadRulesMap();
		assert.strictEqual(h.view.rulesMap, map, 'failed refresh must retain the map object');
		assert.equal(h.view.firewallBackend, 'unknown');
		assert.equal(h.view.rulesMapTruncated, true, 'even an empty map retains its limit state');
		assert.equal(h.view.lastRulesError, 'rules_unavailable');
		const body = ui(h).body;
		assert.match(body.textContent, /truncated=true/);
		assert.match(body.textContent, /Could not refresh rule names/);
		assert.equal(/previously loaded names are still shown/.test(body.textContent), !!Object.keys(rules).length);
		h.setRpcMock('fwlive.rules', async () => ({ backend: 'nft', rules: { fresh: 'Fresh' }, truncated: false }));
		await h.view.loadRulesMap();
		assert.equal(h.view.rulesMapTruncated, false);
		assert.equal(h.view.lastRulesError, null);
		assert.equal(ui(h).details.style.display, 'none');
	}
	const h = loadFwliveView({ rpcMocks: {
		'fwlive.rules': async () => { throw new Error('initial load failed'); }
	} });
	await h.view.loadRulesMap();
	assert.match(ui(h).body.textContent, /Could not load rule names/);
	assert.doesNotMatch(ui(h).body.textContent, /previously loaded/);
}

async function testStaleReplyAndUnknownCode() {
	let resolve;
	const h = loadFwliveView({ rpcMocks: {
		'fwlive.rules': () => new Promise(r => { resolve = r; })
	} });
	const epoch = h.view.currentPollEpoch();
	const loading = h.view.loadRulesMap(epoch);
	h.view.viewDisposed = true;
	resolve({ backend: 'unknown', rules: { stale: 'Stale' }, truncated: true, error: 'no_backend' });
	await loading;
	assert.equal(h.view.rulesMapTruncated, false, 'discarded response must not mutate map metadata');
	assert.equal(h.view.rulesMapLoaded, false);
	assert.equal(h.view.lastRulesError, null);

	const payload = '<svg/onload=PWNED>';
	const safe = loadFwliveView({ rpcMocks: {
		'fwlive.rules': async () => ({ backend: 'nft', rules: {}, truncated: false, error: payload })
	} });
	await safe.view.loadRulesMap();
	const { body } = ui(safe);
	assert.match(body.textContent, /Rule-name lookup failed/);
	assert.ok(body.textContent.includes(payload), 'unknown codes must remain selectable literal text');
	assert.deepEqual(body._innerHTMLWrites || [], [], 'diagnostics must never use an HTML sink');
}

(async () => {
	await testOutcomesAndRecovery();
	await testRefreshRetainsSnapshot();
	await testStaleReplyAndUnknownCode();
	console.log('fwlive-view rules diagnostics: independent outcomes, retained snapshots, recovery, stale replies and text nodes OK');
})().catch(error => {
	console.error(error);
	process.exitCode = 1;
});
