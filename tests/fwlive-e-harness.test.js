#!/usr/bin/env node
'use strict';

/**
 * LuCI-accurate E() harness (#149) + the discriminating renderer test.
 *
 * The module-loader stub `fakeE` returns { tag, attrs, children } object
 * literals and never renders, so DOM-injection regressions (a value reaching
 * an innerHTML sink instead of a text node) are structurally invisible to CI.
 *
 * This test renders through the real LuCI dom.append/dom.create semantics
 * (tests/lib/luci-e-harness.js) and discriminates:
 *   - array child     → document.createTextNode() → appendChild, NO innerHTML write
 *   - bare string     → node.innerHTML = value    (the HTML sink — writes are recorded)
 *
 * Red/green: every assertion here fails against a fakeE-like stub (object
 * literals have no innerHTML setter, no _innerHTMLWrites, no childNodes).
 */

const assert = require('node:assert/strict');
const {
	loadFwliveModule,
	fakeE,
	luciE
} = require('./lib/load-fwlive-module');

const { E, Element, TextNode, document } = luciE;

/* --- discrimination: array child renders a text node, no innerHTML write --- */
function testArrayChildCreatesTextNode() {
	const el = E('div', {}, ['alpha', 'beta']);
	assert.ok(Array.isArray(el._innerHTMLWrites), 'real harness must record innerHTML writes');
	assert.strictEqual(el._innerHTMLWrites.length, 0, 'array children must NOT touch innerHTML');
	assert.strictEqual(el.childNodes.length, 2);
	assert.strictEqual(el.childNodes[0].nodeType, 3, 'non-node array item must become a text node');
	assert.ok(el.childNodes[0] instanceof TextNode);
	assert.strictEqual(el.childNodes[0].textContent, 'alpha');
	assert.strictEqual(el.childNodes[1].textContent, 'beta');
}

/* --- discrimination: bare string child is the innerHTML sink --- */
function testBareStringChildWritesInnerHTML() {
	const el = E('div', {}, 'plain text');
	assert.strictEqual(el._innerHTMLWrites.length, 1, 'bare string child must write innerHTML');
	assert.strictEqual(el._innerHTML, 'plain text');
}

/* --- vulnerability shape: same value, array child is inert / bare string hits the sink --- */
function testHtmlShapedValueDiscrimination() {
	const value = '<b>x</b>';

	const sink = E('div', {}, value);
	assert.strictEqual(sink._innerHTMLWrites.length, 1, 'bare string <b>x</b> must reach the sink');
	assert.strictEqual(sink._innerHTML, value);

	const safe = E('div', {}, [value]);
	assert.strictEqual(safe._innerHTMLWrites.length, 0, 'array <b>x</b> must NOT reach the sink');
	assert.strictEqual(safe.childNodes.length, 1);
	assert.strictEqual(safe.childNodes[0].nodeType, 3, 'array <b>x</b> must become a text node');
	assert.strictEqual(safe.childNodes[0].textContent, value);
}

/* --- fidelity: attrs (string + event) and node children --- */
function testAttrsAndNodeChildren() {
	const clicked = [];
	const el = E('a', {
		'class': 'fwlive-filter-link',
		'href': '#',
		'click': function() { clicked.push(1); }
	}, [E('span', {}, 'label'), E('b', {}, 'x')]);
	assert.strictEqual(el.tagName, 'a');
	assert.strictEqual(el._attrs['class'], 'fwlive-filter-link');
	assert.strictEqual(el._attrs['href'], '#');
	assert.ok(Array.isArray(el._listeners.click) && el._listeners.click.length === 1);
	el._listeners.click[0]();
	assert.deepStrictEqual(clicked, [1]);
	assert.strictEqual(el._innerHTMLWrites.length, 0, 'node children must appendChild, not innerHTML');
	assert.strictEqual(el.childNodes.length, 2);
	assert.strictEqual(el.childNodes[0].tagName, 'span');
	assert.strictEqual(el.childNodes[1].tagName, 'b');
}

/* --- nested array children render real elements --- */
function testNestedArrayChildren() {
	const ul = E('ul', {}, [E('li', {}, 'one'), E('li', {}, ['two', ' ', E('em', {}, 'em')])]);
	assert.strictEqual(ul._innerHTMLWrites.length, 0);
	assert.strictEqual(ul.childNodes.length, 2);
	assert.strictEqual(ul.childNodes[0].tagName, 'li');
	const li2 = ul.childNodes[1];
	assert.strictEqual(li2.childNodes.length, 3);
	assert.strictEqual(li2.childNodes[2].tagName, 'em');
}

/* --- red/green: harness must NOT degenerate to fakeE-like object returns --- */
function testHarnessIsNotFakeE() {
	const el = E('div', {}, ['x']);
	assert.ok(el instanceof Element, 'E() must return a rendered Node');
	assert.strictEqual(typeof el.innerHTML, 'string');
	assert.ok(Array.isArray(el._innerHTMLWrites));
	assert.ok(Array.isArray(el.childNodes));

	const fake = fakeE('div', {}, ['x']);
	assert.strictEqual(typeof fake.innerHTML, 'undefined', 'fakeE marker: no innerHTML getter');
	assert.strictEqual(fake._innerHTMLWrites, undefined, 'fakeE marker: no write log');
	assert.strictEqual(fake.childNodes, undefined, 'fakeE marker: no childNodes');

	assert.throws(function() {
		assert.strictEqual(fake._innerHTMLWrites.length, 0);
	}, /undefined/, 'fakeE-like stub must fail the discriminating assertion');
}

/* --- integration: a real fwlive renderer under the real E() --- */
function testRealRendererIntegration() {
	const log = loadFwliveModule('log');
	const links = loadFwliveModule('links', { log: log });
	const logging = loadFwliveModule('logging', {
		links: links,
		E: luciE.E,
		document: luciE.document
	});

	const nodes = logging.buildEmptyStateNodes(
		{ loggingStatus: { wan_log: false, blockers: [] }, loggingBusy: false, showConsent: true },
		{ onEnable: function() {}, onDismissConsent: function() {} }
	);
	assert.ok(Array.isArray(nodes));
	const panel = nodes.filter(function(n) { return n instanceof Element; })
		.find(function(n) { return n.tagName === 'div' && n._attrs['class'] === 'fwlive-consent'; });
	assert.ok(panel, 'consent panel must render under the real E()');
	assert.strictEqual(panel.tagName, 'div');
	assert.strictEqual(panel._innerHTMLWrites.length, 0, 'array-rooted panel must not write innerHTML');
	assert.ok(panel.childNodes.length >= 4, 'panel children must be appended, not stringified');

	const host = new Element('div');
	logging.renderEmptyState(host, {
		loggingStatus: { wan_log: false, blockers: [] },
		loggingBusy: false,
		entriesLength: 0,
		loggingNotice: '',
		showConsent: false
	}, { onEnable: function() {} });
	assert.strictEqual(host._innerHTMLWrites[0], '', 'renderer clears the host');
	assert.strictEqual(host._innerHTMLWrites.length, 1, 'only the clear; children appended as nodes');
	assert.ok(host.childNodes.length >= 1);
	for (let i = 0; i < host.childNodes.length; i++)
		assert.strictEqual(host.childNodes[i].nodeType, 1, 'host children must be element nodes');
}

/* --- document shim fidelity for E('a', ..., [...]) --- */
function testDocumentShim() {
	assert.ok(document.createElement('div') instanceof Element);
	const t = document.createTextNode('<b>x</b>');
	assert.ok(t instanceof TextNode);
	assert.strictEqual(t.textContent, '<b>x</b>');
	assert.ok(document.createDocumentFragment().nodeType === 11);
}

testArrayChildCreatesTextNode();
testBareStringChildWritesInnerHTML();
testHtmlShapedValueDiscrimination();
testAttrsAndNodeChildren();
testNestedArrayChildren();
testHarnessIsNotFakeE();
testRealRendererIntegration();
testDocumentShim();

console.log('fwlive E() harness tests passed');
