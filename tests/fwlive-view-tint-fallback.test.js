#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { createFwliveView: loadFwliveView } = require('./lib/load-fwlive-view');

const h = loadFwliveView();
const v = h.view;
const map = h.document.querySelector('.fwlive-map');
assert.ok(map, 'render must register .fwlive-map for querySelector');
assert.ok(h.document.querySelector('#fwlive-table tbody'),
	'render must register #fwlive-table tbody');
assert.ok(h.document.querySelector('#fwlive-table thead tr'),
	'descendant querySelector must find thead tr');

const miss = h.document.createElement('div');
miss.setAttribute('class', 'group');
const hit = h.document.createElement('div');
hit.setAttribute('class', 'group');
const target = h.document.createElement('span');
target.setAttribute('class', 'target');
hit.appendChild(target);
const root = h.document.createElement('div');
root.appendChild(miss);
root.appendChild(hit);
assert.equal(root.querySelector('.group .target'), target,
	'descendant querySelector must skip a first ancestor that has no match');

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

function paintDependsOnFallback(mapEl) {
	return function (el) {
		if (el === mapEl) {
			return {
				getPropertyValue: function () {
					return mapEl.getAttribute('data-tint-fallback') === '1' ? '#46a546' : '';
				}
			};
		}
		const tr = el && el.parentNode;
		const tinted =
			tr &&
			tr.classList &&
			(tr.classList.contains('fwlive-row-pass') || tr.classList.contains('fwlive-row-deny'));
		const fallbackOn = mapEl.getAttribute('data-tint-fallback') === '1';
		return {
			backgroundColor:
				tinted && fallbackOn ? 'rgb(70, 165, 70)' : 'rgba(0, 0, 0, 0)'
		};
	};
}

const previousComputed = global.getComputedStyle;
try {
	v.entries = [
		{
			id: '1',
			action: 'drop',
			src: '192.0.2.1',
			dst: '198.51.100.1',
			proto: 'TCP'
		}
	];
	v.rowTint = 'classic';
	v.rowTintPalette = 'classic';
	v.applyRowTintMode();
	v.applyTintFallback(map);
	assert.equal(map.getAttribute('data-tint-fallback'), '1');
	global.getComputedStyle = paintDependsOnFallback(map);
	v.onRowTintPaletteChange({ target: { value: 'accessible' } });
	h.flushFrames();
	assert.equal(map.getAttribute('data-row-tint'), 'accessible');
	assert.equal(
		map.getAttribute('data-tint-fallback'),
		'1',
		'palette change must re-probe without fallback paint and re-apply it'
	);
	assert.equal(v.tintFallbackActive, true);
	assert.equal(map.style['--fwlive-pass-color'], '#0d9488');
	assert.equal(map.style['--fwlive-deny-color'], '#c2410c');
} finally {
	if (previousComputed) global.getComputedStyle = previousComputed;
	else delete global.getComputedStyle;
}

console.log('fwlive-view tint fallback harness OK');
