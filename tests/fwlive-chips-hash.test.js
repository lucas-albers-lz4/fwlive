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
	'contains': 'ENTHAELT',
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

function findElementByClass(root, className) {
	if (!root) return null;
	if (root.nodeType === 1) {
		const classes = String((root._attrs && root._attrs['class']) || '').split(/\s+/);
		if (classes.indexOf(className) !== -1) return root;
	}
	const kids = root.childNodes || [];
	for (let i = 0; i < kids.length; i++) {
		const found = findElementByClass(kids[i], className);
		if (found) return found;
	}
	return null;
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
	assert.ok(
		includeText.indexOf('contains') >= 0,
		'include q chip must say contains, got: ' + includeText
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
		includeText.indexOf('ENTHAELT') >= 0,
		'include q chip must use translated polarity contains, got: ' + includeText
	);
	assert.ok(
		includeText.indexOf('IST') < 0,
		'include q chip must not use translated polarity is, got: ' + includeText
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

function testInvertButtonAccessibleNameTracksFilterMode() {
	const log = loadFwliveModule('log', { _: translatedGettext });
	const chips = loadFwliveModule('chips', {
		log: log,
		E: luciE.E,
		document: luciE.document,
		_: translatedGettext
	});
	const host = luciE.E('div', {}, []);
	host.style = { display: '' };
	const state = {
		filters: { action: 'drop' },
		chipFields: [{ key: 'action', label: 'action' }]
	};
	let invertCalls = 0;
	let clearCalls = 0;
	let clearEvent = null;
	function render() {
		chips.renderFilterChips(host, state, {
			onInvert: function (field) {
				invertCalls++;
				state.filters[field] = state.filters[field].charAt(0) === '!'
					? state.filters[field].substring(1)
					: '!' + state.filters[field];
				render();
			},
			onClear: function (field, ev) {
				clearCalls++;
				clearEvent = { field: field, event: ev };
			},
			onClearAll: function () {}
		});
	}
	function assertInvertName(expected) {
		const button = findElementByClass(host, 'fwlive-chip-invert');
		const wrapper = findElementByClass(host, 'fwlive-chip-invert-wrap');
		const remove = findElementByClass(host, 'fwlive-chip-remove');
		assert.ok(button, 'chip invert button remains present');
		assert.ok(wrapper, 'chip tooltip wrapper remains present');
		assert.ok(remove, 'remove-filter control remains present');
		assert.strictEqual(button.getAttribute('aria-label'), expected);
		assert.strictEqual(wrapper.getAttribute('data-tip'), expected);
		assert.strictEqual(collectText(button), '≠', 'the existing icon stays in the button');
		assert.strictEqual(remove.getAttribute('aria-label'), 'FILTER-ENTFERNEN');
		assert.ok(
			remove.getAttribute('title').indexOf('FILTER-ENTFERNEN') >= 0,
			'the existing remove-filter tooltip remains present'
		);
		assert.strictEqual(collectText(remove), '×', 'the existing remove glyph stays visible');
		return button;
	}

	render();
	let button = assertInvertName('STATTDESSEN-AUS');
	button._listeners.click[0]({ type: 'click' });
	assert.strictEqual(state.filters.action, '!drop');
	assert.strictEqual(invertCalls, 1, 'one activation inverts exactly once');
	button = assertInvertName('STATTDESSEN-EIN');
	button._listeners.click[0]({ type: 'click' });
	assert.strictEqual(state.filters.action, 'drop');
	assert.strictEqual(invertCalls, 2, 'the inverse action also toggles exactly once');
	assert.strictEqual(clearCalls, 0, 'inversion does not invoke filter removal');
	const remove = findElementByClass(host, 'fwlive-chip-remove');
	const event = { type: 'click', preventDefault: function () {} };
	remove._listeners.click[0](event);
	assert.strictEqual(clearCalls, 1, 'one remove activation invokes the existing callback once');
	assert.strictEqual(clearEvent.field, 'action', 'remove keeps its field argument');
	assert.strictEqual(clearEvent.event, event, 'remove keeps passing the activation event');
}

function testActionPickerAccessibleNameAndHash() {
	const h = loadFwliveView({ location: { hash: '' } });
	const action = h.document.getElementById('fwlive-action');
	assert.ok(action, 'Action filter select must render');
	assert.strictEqual(
		action.getAttribute('aria-label'),
		'Filter by Action',
		'Action picker must have a persistent translated filter-purpose name'
	);

	action.value = 'block';
	h.view.onFilterInput();
	assert.strictEqual(h.view.readFilters().action, 'block', 'Action selection still filters');
	assert.deepStrictEqual(
		h.view.hashEntries().filter(function (entry) { return entry.key === 'action'; }),
		[{ key: 'action', val: 'block' }],
		'Action selection continues to update the shareable hash'
	);
	assert.strictEqual(
		action.getAttribute('aria-label'),
		'Filter by Action',
		'Action picker name persists after the value changes'
	);
}

function testChipStripSignatureAndCallbackRefresh() {
	const log = loadFwliveModule('log');
	const chips = loadFwliveModule('chips', { log: log, E: luciE.E, document: luciE.document });
	const host = luciE.E('div', {}, []);
	host.style = { display: '' };
	const state = {
		filters: { src: '192.0.2.1', dst: '192.0.2.2' },
		chipFields: [
			{ key: 'src', label: 'src' },
			{ key: 'dst', label: 'dst' }
		]
	};
	let clearCalls = 0;
	const callbacks = {
		onInvert: function () {},
		onClear: function () { clearCalls++; },
		onClearAll: function () {}
	};
	chips.renderFilterChips(host, state, callbacks);
	const initialNodes = host.childNodes.slice();
	const initialWrites = host._innerHTMLWrites.length;
	chips.renderFilterChips(host, state, callbacks);
	assert.deepStrictEqual(host.childNodes, initialNodes, 'unchanged strip must keep the same nodes');
	assert.strictEqual(host._innerHTMLWrites.length, initialWrites, 'unchanged strip must skip clearing');

	state.filters.src = '198.51.100.1';
	chips.renderFilterChips(host, state, callbacks);
	assert.notStrictEqual(host.childNodes[0], initialNodes[0], 'changed value must refresh its chip');
	assert.ok(collectText(host).indexOf('198.51.100.1') >= 0, 'changed value must be rendered');
	assert.ok(collectText(host).indexOf('192.0.2.1') < 0, 'old value must be removed');

	state.filters.src = '!198.51.100.1';
	chips.renderFilterChips(host, state, callbacks);
	assert.ok(
		String(host.childNodes[0].getAttribute('class')).indexOf('fwlive-chip-negated') >= 0,
		'polarity changes must refresh chip classes and content'
	);

	state.chipFields.reverse();
	chips.renderFilterChips(host, state, callbacks);
	const reorderedText = collectText(host);
	assert.ok(
		reorderedText.indexOf('192.0.2.2') < reorderedText.indexOf('198.51.100.1'),
		'chip-field order changes must refresh the rendered order'
	);

	const previousRemove = findElementByClass(host, 'fwlive-chip-remove');
	const replacementCallbacks = {
		onInvert: function () {},
		onClear: function () { clearCalls += 10; },
		onClearAll: function () {}
	};
	chips.renderFilterChips(host, state, replacementCallbacks);
	const replacementRemove = findElementByClass(host, 'fwlive-chip-remove');
	assert.notStrictEqual(replacementRemove, previousRemove, 'new callbacks must refresh click closures');
	replacementRemove._listeners.click[0]({ type: 'click' });
	assert.strictEqual(clearCalls, 10, 'replacement node must call only the current callback');

	state.filters.src = '';
	state.filters.dst = '!';
	chips.renderFilterChips(host, state, replacementCallbacks);
	assert.strictEqual(host.style.display, 'none', 'empty/bare-negation state hides the strip');
	assert.strictEqual(collectText(host), '', 'empty/bare-negation state removes all chip nodes');
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

function testBareBangRendersNoChip() {
	const host = renderChips({ src: '!', dst: '!', q: '!' });
	assert.strictEqual(host.style.display, 'none', 'bare ! must not render chips');
	assert.strictEqual(collectText(host), '', 'bare ! must not leave chip text');
	const h = loadFwliveView({ location: { hash: '' } });
	withSelectOptions(h);
	h.view.updateHash({ q: '!', src: '!' });
	assert.deepStrictEqual(h.view.hashEntries(), [], 'bare ! filters must not persist in the hash');
	h.view.applyHash();
	assert.strictEqual(valueOf(h, 'fwlive-q'), '', 'bare ! must not restore into the search field');
	h.view.updateHash({ q: '!wan' });
	assert.deepStrictEqual(
		h.view.hashEntries().filter(function (entry) { return entry.key === 'q'; })[0],
		{ key: 'q', val: '!wan' },
		'valid negated filters must survive the hash round-trip'
	);
	h.view.applyHash();
	assert.strictEqual(valueOf(h, 'fwlive-q'), '!wan', 'valid negated filter must restore from the hash');
	const real = renderChips({ src: '!10.0.0.1', action: '!' });
	const text = collectText(real);
	assert.ok(text.indexOf('10.0.0.1') >= 0, 'negated value must still render');
	assert.ok(text.indexOf('does not contain') >= 0, 'negated src must say does not contain');
	assert.ok(text.indexOf('action') < 0, 'bare ! action must not render a chip, got: ' + text);
}

function testIncludeTextChipsUseContains() {
	const cases = [
		{ key: 'q', value: 'wan' },
		{ key: 'src', value: '10.0.0.1' },
		{ key: 'dst', value: '10.0.0.1' }
	];
	for (let i = 0; i < cases.length; i++) {
		const spec = cases[i];
		const filters = {};
		filters[spec.key] = spec.value;
		const host = renderChips(filters);
		const text = collectText(host);
		assert.ok(
			text.indexOf('contains') >= 0,
			spec.key + ' include chip must say contains, got: ' + text
		);
		assert.ok(text.indexOf(spec.value) >= 0, spec.key + ' value must remain visible');
		assertPayloadNeverInSink(host, spec.value);
	}

	const actionHost = renderChips({ action: 'drop' });
	const actionText = collectText(actionHost);
	assert.ok(
		actionText.indexOf('is') >= 0,
		'exact-match include chips keep is, got: ' + actionText
	);
	assert.ok(
		actionText.indexOf('contains') < 0,
		'exact-match include chips must not say contains, got: ' + actionText
	);
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
	['fwlive-proto', 'fwlive-action'].forEach(function (id) {
		const sel = h.document.getElementById(id);
		if (!sel) return;
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
	});
	assert.ok(h.document.getElementById('fwlive-proto'), 'missing fwlive-proto');
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

function testPollPaintLeavesHashAlone() {
	const h = loadFwliveView({ location: { hash: '#q=wan' } });
	const tableEl = h.document.createElement('table');
	tableEl.setAttribute('id', 'fwlive-table');
	const body = h.document.createElement('tbody');
	tableEl.appendChild(body);
	h.view.entries = [{ id: '1', src: '192.0.2.1', message: 'wan drop' }];
	h.history.calls.length = 0;

	h.view.renderRows(true);
	h.view.renderRows(false);
	assert.ok(body.childNodes.length > 0, 'fixture must reach the table paint');
	assert.strictEqual(h.history.calls.length, 0, 'paints must not rewrite the URL hash');

	h.view.onFilterInput();
	assert.strictEqual(h.history.calls.length, 1, 'filter input must write the URL hash');
}

function testApplyHashIgnoresUnlistedAndPersistedKeys() {
	const h = loadFwliveView({
		location: {
			hash: '#fetch-mode=manual&row-tint=accessible&proto-custom=OSPF&backend=x&src=192.0.2.1'
		}
	});
	withSelectOptions(h);
	h.view.fetchMode = 'auto';
	h.view.applyHash();
	assert.strictEqual(h.view.fetchMode, 'auto', '#fetch-mode must stay persisted');
	assert.strictEqual(valueOf(h, 'fwlive-src'), '192.0.2.1');
	const custom = h.document.getElementById('fwlive-proto-custom');
	if (custom) {
		assert.notStrictEqual(custom.value, 'OSPF', '#proto-custom is not a hash filter key');
	}
	const backend = h.document.getElementById('fwlive-backend');
	if (backend) {
		assert.notStrictEqual(
			backend.value,
			'x',
			'unknown hash keys must not write fwlive-* nodes'
		);
		assert.notStrictEqual(backend.textContent, 'x');
	}
}

function testApplyHashUnlistedActionStaysSelected() {
	const h = loadFwliveView({ location: { hash: '#action=uncommon' } });
	withSelectOptions(h);
	assert.doesNotThrow(function () {
		h.view.applyHash();
	}, 'unlisted action hash must not throw');
	assert.strictEqual(valueOf(h, 'fwlive-action'), 'uncommon');
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
testBareBangRendersNoChip();
testIncludeTextChipsUseContains();
testNegatedTextChips();
testHostileTextChipSink();
testIdentityChipFieldLabels();
testTranslatedChipCatalog();
testInvertButtonAccessibleNameTracksFilterMode();
testActionPickerAccessibleNameAndHash();
testChipStripSignatureAndCallbackRefresh();
testUnknownChipFieldLabel();
testApplyHashValidAndMalformed();
testApplyHashIgnoresUnlistedAndPersistedKeys();
testApplyHashUnlistedActionStaysSelected();
testApplyHashPreservesEqualsInValue();
testUpdateHashRoundTripsEqualsAndAmpersand();
testUpdateHashUsesReplaceState();
testPollPaintLeavesHashAlone();
testApplyHashHostileAsText();
console.log('fwlive chips/hash sink tests passed');
