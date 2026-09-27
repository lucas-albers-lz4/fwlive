#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

const h = loadFwliveView();
const v = h.view;
const map = h.document.querySelector('.fwlive-map');
assert.ok(map, 'render must register .fwlive-map for querySelector');
assert.ok(h.document.querySelector('#fwlive-table tbody'),
	'render must register #fwlive-table tbody');
assert.ok(h.document.querySelector('#fwlive-table thead tr'),
	'descendant querySelector must find thead tr');

v.rowTint = 'classic';
v.applyRowTintMode();
assert.equal(map.getAttribute('data-row-tint'), 'classic');

v.applyTintFallback(map);
assert.equal(map.getAttribute('data-tint-fallback'), '1');
assert.equal(map.style['--fwlive-pass-color'], '#46a546');
assert.equal(map.style['--fwlive-deny-color'], '#ca3c3c');
assert.equal(v.tintFallbackActive, true);

const wrap = h.document.getElementById('fwlive-row-tint-palette-wrap');
assert.ok(wrap, 'palette wrap must render');
v.rowTint = 'off';
v.updateRowTintUi();
assert.equal(wrap.classList.contains('fwlive-hidden'), true,
	'disabled tint must hide the palette via classList');

v.clearTintFallback(map);
assert.equal(map.getAttribute('data-tint-fallback'), null);
assert.equal(map.style['--fwlive-pass-color'], undefined);
assert.equal(v.tintFallbackActive, false);

console.log('fwlive-view tint fallback harness OK');
