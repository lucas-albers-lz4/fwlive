#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

const h = loadFwliveView();
let ran = 0;
const id = h.window.requestAnimationFrame(function () {
	ran++;
	h.window.requestAnimationFrame(function () {
		ran++;
	});
});
assert.equal(typeof id, 'number');
assert.equal(ran, 0, 'queued rAF must not run until flushFrames');
h.flushFrames();
assert.equal(ran, 2, 'flushFrames must run a nested frame cycle');
assert.equal(typeof h.window.cancelAnimationFrame, 'function');
h.window.cancelAnimationFrame(h.window.requestAnimationFrame(function () {
	ran++;
}));
h.flushFrames();
assert.equal(ran, 2, 'cancelAnimationFrame must drop a queued callback');
console.log('fwlive-view raf harness: flushFrames OK');
