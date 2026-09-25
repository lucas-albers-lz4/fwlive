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

/** #674: sparse catalog — identity fakeGettext cannot catch composition regressions. */
const TRANSLATED_CHIP_CATALOG = {
	'%s: %s': '[%s|%s]',
	'not': 'NICHT',
	'does not contain': 'ENTHAELT-NICHT',
	'Search': 'SUCHE',
	'Source': 'QUELLE',
	'is': 'IST',
	'Clear all': 'ALLES-LOESCHEN',
	'Include instead': 'STATTDESSEN-EIN',
	'Exclude instead': 'STATTDESSEN-AUS',
	'Remove filter': 'FILTER-ENTFERNEN'
};

function translatedGettext(msgid) {
	const mapped = Object.prototype.hasOwnProperty.call(TRANSLATED_CHIP_CATALOG, msgid)
		? TRANSLATED_CHIP_CATALOG[msgid]
		: String(msgid);
	const out = Object(String(mapped));
	out.format = function () {
		let i = 0;
		const args = arguments;
		return String(out).replace(/%s|%d/g, function () {
			return String(args[i++]);
		});
	};
	return out;
}

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

function renderChips(filters, chipFields, gettext) {
	const log = loadFwliveModule('log', gettext ? { _: gettext } : {});
	const chips = loadFwliveModule('chips', {
		log: log,
		E: luciE.E,
		document: luciE.document,
		_: gettext
	});
	const host = luciE.E('div', { 'class': 'fwlive-chips' }, []);
	host.style = { display: '' };
	chips.renderFilterChips(
		host,
		{ filters: filters, chipFields: chipFields || CHIP_FIELDS },
		NOOP
	);
	return host;
}

function testIdentityChipFieldLabels() {
	const includeHost = renderChips({ q: 'wan' });
	const includeText = collectText(includeHost);
	assert.ok(
		includeText.indexOf('Search: wan') >= 0,
		'include q chip must use Search via formatFilterChipLabel, got: ' + includeText
	);

	const qHost = renderChips({ q: '!drop' });
	const qText = collectText(qHost);
	assert.ok(qText.indexOf('Search') >= 0, 'negated q chip must show Search, got: ' + qText);
	assert.ok(
		qText.indexOf('does not contain') >= 0,
		'negated q chip must show the full phrase, got: ' + qText
	);

	const srcHost = renderChips({ src: '!192.0.2.1' });
	const srcText = collectText(srcHost);
	assert.ok(srcText.indexOf('Source') >= 0, 'negated src chip must show Source, got: ' + srcText);
	assert.ok(
		srcText.indexOf('does not contain') >= 0,
		'negated src chip must show the full phrase, got: ' + srcText
	);
}

function testTranslatedChipCatalog() {
	const includeHost = renderChips({ q: 'wan' }, CHIP_FIELDS, translatedGettext);
	const includeText = collectText(includeHost);
	assert.ok(
		includeText.indexOf('[SUCHE|wan]') >= 0,
		'include q chip must use translated connector and Search, got: ' + includeText
	);
	assert.ok(
		includeText.indexOf('IST') >= 0,
		'include q chip must use translated polarity is, got: ' + includeText
	);

	const qHost = renderChips({ q: '!drop' }, CHIP_FIELDS, translatedGettext);
	const qText = collectText(qHost);
	assert.ok(
		qText.indexOf('SUCHE') >= 0,
		'negated q chip must show translated Search, got: ' + qText
	);
	assert.ok(
		qText.indexOf('ENTHAELT-NICHT') >= 0,
		'negated q chip must show translated does not contain, got: ' + qText
	);

	const srcHost = renderChips({ src: '!192.0.2.1' }, CHIP_FIELDS, translatedGettext);
	const srcText = collectText(srcHost);
	assert.ok(
		srcText.indexOf('QUELLE') >= 0,
		'negated src chip must show translated Source, got: ' + srcText
	);
	assert.ok(
		srcText.indexOf('ENTHAELT-NICHT') >= 0,
		'negated src chip must show translated does not contain, got: ' + srcText
	);
}

function testUnknownChipFieldLabel() {
	const host = renderChips({ custom: 'x' }, [{ key: 'custom', label: 'widget' }]);
	const text = collectText(host);
	assert.ok(text.indexOf('widget') >= 0, 'unknown spec.key must honor spec.label, got: ' + text);
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
		assert.ok(text.indexOf('≠') >= 0, spec.key + ' must show ≠');
		assert.ok(
			text.indexOf('does not contain') >= 0,
			spec.key + ' must show the full negated phrase, got: ' + text
		);
		assert.ok(text.indexOf(spec.value.slice(1)) >= 0, spec.key + ' value must remain visible');
		assertPayloadNeverInSink(host, spec.value);
	}
}

function testHostileTextChipSink() {
	const host = renderChips({ q: '!' + HOSTILE, src: HOSTILE, dst: '!' + HOSTILE });
	assertPayloadNeverInSink(host, HOSTILE);
	const text = collectText(host);
	assert.ok(text.indexOf(HOSTILE) >= 0, 'hostile filter text must remain visible');
	assert.ok(
		text.indexOf('does not contain') >= 0,
		'negated address/search chips use the full phrase'
	);
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
	const q = h.view.hashEntries().filter(function (entry) {
		return entry.key === 'q';
	})[0];
	assert.deepStrictEqual(q, { key: 'q', val: 'a=b&c' });
}

function testUpdateHashUsesReplaceState() {
	let hashAssigns = 0;
	let hashValue = '';
	const location = {};
	Object.defineProperty(location, 'hash', {
		configurable: true,
		enumerable: true,
		get: function () {
			return hashValue;
		},
		set: function (v) {
			hashAssigns++;
			hashValue = String(v);
		}
	});
	const h = loadFwliveView({ location: location });
	hashAssigns = 0;
	h.history.calls.length = 0;
	h.view.updateHash({ q: 'wan' });
	assert.strictEqual(h.history.calls.length, 1, 'replaceState must write the fragment');
	assert.strictEqual(
		hashAssigns,
		h.history.calls.length,
		'location.hash must change only via replaceState'
	);
	assert.match(h.location.hash, /^#q=wan$/);
	assert.strictEqual(h.history.calls[0].url, '#q=wan');

	hashAssigns = 0;
	h.history.calls.length = 0;
	h.view.updateHash({ q: '' });
	assert.strictEqual(h.history.calls.length, 1, 'empty filters still replaceState');
	assert.strictEqual(hashAssigns, 1, 'empty filters must not assign location.hash directly');
	assert.ok(
		!h.location.hash || h.location.hash.length < 2,
		'empty filters keep empty-hash handling'
	);
	assert.deepStrictEqual(h.view.hashEntries(), []);
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
testIdentityChipFieldLabels();
testTranslatedChipCatalog();
testUnknownChipFieldLabel();
testApplyHashValidAndMalformed();
testApplyHashPreservesEqualsInValue();
testUpdateHashRoundTripsEqualsAndAmpersand();
testUpdateHashUsesReplaceState();
testApplyHashHostileAsText();
console.log('fwlive chips/hash sink tests passed');
