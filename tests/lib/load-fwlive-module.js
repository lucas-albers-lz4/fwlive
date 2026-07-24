'use strict';

/**
 * Load a luci-app-fwlive resources/fwlive/*.js module under Node.
 * Strips LuCI 'require' lines and stubs baseclass.extend → descriptor object.
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..', '..');
const FWLIVE = path.join(
	ROOT,
	'openwrt-feed/luci-app-fwlive/htdocs/luci-static/resources/fwlive'
);

function fakeE(tag, attrs, children) {
	return { tag: tag, attrs: attrs || {}, children: children };
}

function fakeGettext(s) {
	const out = Object(String(s));
	out.format = function() {
		let i = 0;
		const args = arguments;
		return String(out).replace(/%s|%d/g, function() {
			return String(args[i++]);
		});
	};
	return out;
}

if (typeof String.prototype.format !== 'function') {
	String.prototype.format = function() {
		let i = 0;
		const args = arguments;
		return String(this).replace(/%s|%d/g, function() {
			return String(args[i++]);
		});
	};
}

function loadFwliveModule(name, deps) {
	deps = deps || {};
	const src = fs.readFileSync(path.join(FWLIVE, name + '.js'), 'utf8');
	const body = src
		.replace(/^'use strict';\s*/m, '')
		.replace(/^'require [^']+';[^\n]*\n/gm, '');
	const baseclass = { extend: function(desc) { return desc; } };
	const fn = new Function(
		'baseclass', 'log', 'links', 'E', '_', 'document', 'window',
		body
	);
	return fn(
		baseclass,
		deps.log || {},
		deps.links || {},
		deps.E || fakeE,
		deps._ || fakeGettext,
		deps.document || {
			createTextNode: function(t) { return { text: t }; },
			createElement: function(tag) { return fakeE(tag, {}, []); }
		},
		deps.window || {}
	);
}

module.exports = {
	FWLIVE: FWLIVE,
	fakeE: fakeE,
	fakeGettext: fakeGettext,
	loadFwliveModule: loadFwliveModule
};
