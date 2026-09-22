#!/usr/bin/env node
'use strict';

/**
 * #393: chip sink assertions and applyHash restore.
 *
 * Renderer tests are complementary evidence, not standalone XSS proof.
 * They discriminate array-child text nodes from innerHTML sinks under the
 * LuCI-accurate E() harness. A green run does not prove the installed LuCI
 * page is injection-safe.
 */

const assert = require('node:assert/strict');
const { loadFwliveModule, luciE } = require('./lib/load-fwlive-module');
const { loadFwliveView } = require('./lib/load-fwlive-view');
const { collectInnerHTMLWrites } = luciE;

const HOSTILE = '<img src=x onerror=alert(1)>';
const CHIP_FIELDS = [
	{ key: 'q', label: 'search' },
	{ key: 'action', label: 'action' },
	{ key: 'interface', label: 'iface' },
	{ key: 'proto', label: 'proto' },
	{ key: 'src', label: 'src' },
	{ key: 'dst', label: 'dst' },
	{ key: 'sport', label: 'sport' },
	{ key: 'dport', label: 'dport' }
];
const NOOP = {
	onInvert: function () {},
	onClear: function () {},
	onClearAll: function () {}
};

function collectText(node) {
	if (!node) return '';
	if (node.nodeType === 3) return String(node.textContent || '');
	const kids = node.childNodes || [];
	let out = '';
	for (let i = 0; i < kids.length; i++) out += collectText(kids[i]);
	return out;
}

function assertPayloadNeverInSink(host, payload) {
	const writes = collectInnerHTMLWrites(host);
	for (let i = 0; i < writes.length; i++) {
		assert.ok(
			writes[i] === '' || writes[i].indexOf(payload) < 0,
			'attacker bytes must not reach an HTML sink: ' + JSON.stringify(writes[i])
		);
	}
}

function renderChips(filters) {
	const log = loadFwliveModule('log');
	const chips = loadFwliveModule('chips', {
		log: log,
		E: luciE.E,
		document: luciE.document
	});
	const host = luciE.E('div', { 'class': 'fwlive-chips' }, []);
	host.style = { display: '' };
	chips.renderFilterChips(
		host,
		{ filters: filters, chipFields: CHIP_FIELDS },
		NOOP
	);
	return host;
}

function testRecursiveProtoSink() {
	const host = renderChips({ proto: HOSTILE });
	assert.ok(host._innerHTMLWrites.length >= 1, 'chip rebuild clears via innerHTML');
	assertPayloadNeverInSink(host, HOSTILE);
	assert.ok(collectText(host).indexOf(HOSTILE) >= 0, 'hostile proto stays visible as text');
}

function testNegatedTextChips() {
	const cases = [
		{ key: 'q', value: '!drop' },
		{ key: 'src', value: '!192.0.2.1' },
		{ key: 'dst', value: '!2001:db8::1' }
	];
	for (let i = 0; i < cases.length; i++) {
		const spec = cases[i];
		const filters = {};
		filters[spec.key] = spec.value;
		const host = renderChips(filters);
		const text = collectText(host);
		assert.ok(text.indexOf('not') >= 0, spec.key + ' must show not');
		assert.ok(text.indexOf('≠') >= 0, spec.key + ' must show ≠');
		assert.ok(
			text.indexOf('contains') >= 0,
			spec.key + ' must show contains, got: ' + text
		);
		assert.ok(
			text.indexOf(spec.value.slice(1)) >= 0,
			spec.key + ' value must remain visible'
		);
		assertPayloadNeverInSink(host, spec.value);
	}
}

function testHostileTextChipSink() {
	const host = renderChips({ q: '!' + HOSTILE, src: HOSTILE, dst: '!' + HOSTILE });
	assertPayloadNeverInSink(host, HOSTILE);
	const text = collectText(host);
	assert.ok(text.indexOf(HOSTILE) >= 0, 'hostile filter text must remain visible');
	assert.ok(text.indexOf('contains') >= 0, 'negated address/search chips use contains');
}

function valueOf(h, id) {
	const el = h.document.getElementById(id);
	assert.ok(el, 'missing ' + id);
	return el.value || '';
}

function withSelectOptions(h) {
	const sel = h.document.getElementById('fwlive-proto');
	assert.ok(sel, 'missing fwlive-proto');
	const opts = [];
	function walk(node) {
		const kids = node.childNodes || [];
		for (let i = 0; i < kids.length; i++) {
			const c = kids[i];
			if (c && c.tagName === 'option')
				opts.push({ value: (c._attrs && c._attrs.value) || '' });
			else if (c && c.childNodes) walk(c);
		}
	}
	walk(sel);
	sel.options = opts;
}

function testApplyHashValidAndMalformed() {
	const h = loadFwliveView({
		location: {
			hash: '#view=detailed&proto=!TCP&q=!wan&src=!192.0.2.1&dst=!2001:db8::1'
		}
	});
	withSelectOptions(h);
	assert.doesNotThrow(function () {
		h.view.applyHash();
	}, 'valid filter hash must not throw');
	assert.strictEqual(h.view.viewMode, 'detailed');
	assert.strictEqual(h.view.readFilters().proto, '!TCP');
	assert.strictEqual(valueOf(h, 'fwlive-q'), '!wan');
	assert.strictEqual(valueOf(h, 'fwlive-src'), '!192.0.2.1');
	assert.strictEqual(valueOf(h, 'fwlive-dst'), '!2001:db8::1');

	const malformed = loadFwliveView({
		location: { hash: '#q=keepme&broken=%&proto=!TCP' }
	});
	withSelectOptions(malformed);
	assert.doesNotThrow(function () {
		malformed.view.applyHash();
	}, 'malformed % hash entry must drop silently');
	assert.strictEqual(valueOf(malformed, 'fwlive-q'), 'keepme');
	assert.strictEqual(malformed.view.readFilters().proto, '!TCP');
}

function testApplyHashPreservesEqualsInValue() {
	const h = loadFwliveView({ location: { hash: '#q=a=b%26c' } });
	withSelectOptions(h);
	h.view.applyHash();
	assert.strictEqual(valueOf(h, 'fwlive-q'), 'a=b&c');
}

function testUpdateHashRoundTripsEqualsAndAmpersand() {
	const h = loadFwliveView({ location: { hash: '' } });
	h.view.updateHash({ q: 'a=b&c' });
	// A browser prefixes the assigned hash with '#'; the harness is a plain object.
	h.location.hash = '#' + h.location.hash;
	const q = h.view.hashEntries().filter(function (entry) {
		return entry.key === 'q';
	})[0];
	assert.deepStrictEqual(q, { key: 'q', val: 'a=b&c' });
}

function testApplyHashHostileAsText() {
	const encoded = encodeURIComponent(HOSTILE);
	const h = loadFwliveView({
		location: { hash: '#q=' + encoded + '&src=' + encoded }
	});
	withSelectOptions(h);
	assert.doesNotThrow(function () {
		h.view.applyHash();
	});
	const filters = h.view.readFilters();
	assert.strictEqual(filters.q, HOSTILE);
	assert.strictEqual(filters.src, HOSTILE);
	const host = renderChips(filters);
	assertPayloadNeverInSink(host, HOSTILE);
	assert.ok(collectText(host).indexOf(HOSTILE) >= 0, 'hostile hash value stays text');
}

testRecursiveProtoSink();
testNegatedTextChips();
testHostileTextChipSink();
testApplyHashValidAndMalformed();
testApplyHashPreservesEqualsInValue();
testUpdateHashRoundTripsEqualsAndAmpersand();
testApplyHashHostileAsText();
console.log('fwlive chips/hash sink tests passed');
