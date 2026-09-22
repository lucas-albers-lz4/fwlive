#!/usr/bin/env node
'use strict';

const assert = require('node:assert/strict');
const { loadFwliveView } = require('./lib/load-fwlive-view');

function addFooterForHarness(h) {
	const view = h.view;
	view.attachHandlers = function () {};
	view.applyRowTintMode = function () {};
	view.updateRowTintUi = function () {};
	view.updateMessageLayoutUi = function () {};
	view.updateStreamControlsUi = function () {};
	view.updateDetailToggleUi = function () {};
	view.renderThead = function () {};
	view.updateLoggingToolbarUi = function () {};
	view.updateEmptyStateUi = function () {};
	view.updateBackendUi = function () {};
	view.updateTintWarnUi = function () {};
	view.renderRows = function () {};
	view.addFooter();
}

const first = loadFwliveView();
addFooterForHarness(first);
first.view.rowTint = 'accessible';
first.view.rowTintPalette = 'accessible';
first.view.commitRowTintChange();
first.view.onRowTintEnabledChange({ target: { checked: false } });

const storage = {
	'fwlive-row-tint': first.localStorage.getItem('fwlive-row-tint'),
	'fwlive-row-tint-palette': first.localStorage.getItem('fwlive-row-tint-palette')
};
assert.equal(storage['fwlive-row-tint'], 'off');
assert.equal(storage['fwlive-row-tint-palette'], 'accessible');

const reloaded = loadFwliveView({ storage: storage });
addFooterForHarness(reloaded);
assert.equal(reloaded.view.rowTint, 'off', 'reload must keep tint disabled');
assert.equal(reloaded.view.rowTintPalette, 'accessible',
	'tint palette must survive reload while tint is disabled');

reloaded.view.onRowTintEnabledChange({ target: { checked: true } });
assert.equal(reloaded.view.rowTint, 'accessible',
	're-enabling tint must restore the persisted palette');
console.log('fwlive-view tint persistence tests passed');
