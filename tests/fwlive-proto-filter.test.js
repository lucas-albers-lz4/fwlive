#!/usr/bin/env node
'use strict';

/**
 * Protocol filter pair (D Always custom): typed value wins; menu hit clears custom.
 */

const assert = require('node:assert/strict');
const { loadFwliveModule, luciE } = require('./lib/load-fwlive-module');

const MENU = [ '', 'TCP', 'UDP', 'ICMP', 'ICMPV6', 'IGMP', 'GRE', 'ESP', 'AH', 'SCTP',
	'!TCP', '!UDP', '!ICMP', '!ICMPV6', '!IGMP', '!GRE', '!ESP', '!AH', '!SCTP' ];

function makeDoc() {
	const sel = {
		tagName: 'SELECT',
		value: '',
		options: MENU.map(function(v) { return { value: v }; })
	};
	const custom = { value: '' };
	const byId = {
		'fwlive-proto': sel,
		'fwlive-proto-custom': custom
	};
	return {
		document: {
			getElementById: function(id) { return byId[id] || null; }
		},
		sel: sel,
		custom: custom
	};
}

const harness = makeDoc();
const proto = loadFwliveModule('proto', { document: harness.document });
const log = loadFwliveModule('log');

assert.strictEqual(proto.readProtoFilter(), '');

proto.setProtoFilterValue('TCP');
assert.strictEqual(harness.sel.value, 'TCP');
assert.strictEqual(harness.custom.value, '');
assert.strictEqual(proto.readProtoFilter(), 'TCP');

harness.custom.value = '  esp  ';
assert.strictEqual(proto.readProtoFilter(), 'esp', 'trimmed custom wins over select');

proto.setProtoFilterValue('UDP');
assert.strictEqual(harness.sel.value, 'UDP');
assert.strictEqual(harness.custom.value, '', 'menu hit clears custom');
assert.strictEqual(proto.readProtoFilter(), 'UDP');

proto.setProtoFilterValue('ospf');
assert.strictEqual(harness.sel.value, '');
assert.strictEqual(harness.custom.value, 'ospf', 'unknown goes to custom');
assert.strictEqual(proto.readProtoFilter(), 'ospf');

proto.setProtoFilterValue('!TCP');
assert.strictEqual(harness.sel.value, '!TCP');
assert.strictEqual(harness.custom.value, '');
assert.strictEqual(proto.readProtoFilter(), '!TCP');

const cur = proto.readProtoFilter();
proto.setProtoFilterValue(log.toggleFilterNegation(cur));
assert.strictEqual(proto.readProtoFilter(), 'TCP', 'invert exclude menu value');

proto.setProtoFilterValue('weird');
proto.setProtoFilterValue(log.toggleFilterNegation(proto.readProtoFilter()));
assert.strictEqual(proto.readProtoFilter(), '!weird');
proto.setProtoFilterValue(log.toggleFilterNegation(proto.readProtoFilter()));
assert.strictEqual(proto.readProtoFilter(), 'weird');

proto.setProtoFilterValue('');
assert.strictEqual(harness.sel.value, '');
assert.strictEqual(harness.custom.value, '');
assert.strictEqual(proto.readProtoFilter(), '');

/* Malicious custom → chip must stay text-node (array child), not HTML sink. */
const chips = loadFwliveModule('chips', {
	log: log,
	E: luciE.E,
	document: luciE.document
});
const payload = '<img src=x onerror=alert(1)>';
const host = luciE.E('div', { 'class': 'fwlive-chips' }, []);
host.style = { display: '' };
chips.renderFilterChips(host, {
	filters: { proto: payload },
	chipFields: [ { key: 'proto', label: 'proto' } ],
	chipStyle: 'labels'
}, { onInvert: function() {}, onClear: function() {}, onClearAll: function() {} });
assert.ok(host._innerHTMLWrites.length >= 1, 'chip rebuild clears via innerHTML');
assert.ok(host._innerHTMLWrites.every(function(w) {
	return w === '' || w.indexOf(payload) < 0;
}), 'payload must not reach innerHTML sink');
assert.ok(host.childNodes.length >= 1);

console.log('fwlive proto filter tests passed');
