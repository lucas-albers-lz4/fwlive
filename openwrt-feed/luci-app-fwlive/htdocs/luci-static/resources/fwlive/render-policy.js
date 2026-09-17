'use strict';
/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2025-2026 Lucas Albers <lucas.b.albers@gmail.com> */
'require baseclass';

/**
 * Pure render-policy decisions for the fwlive view.
 *
 * The caller supplies view state and receives the visible-row cap plus the
 * cost of the next render. This module does not mutate state, schedule work,
 * inspect the DOM, or know how rows are rendered.
 *
 * @param {object} opts
 * @param {number} opts.rowLimit - User-selected stored-row limit.
 * @param {boolean} opts.weakDevice - Whether the weak-device cap is active.
 * @param {number} opts.weakDeviceDisplayRowCap - Maximum visible rows when capped.
 * @param {number} opts.visibleRowCount - Number of candidate visible rows.
 * @param {*} opts.visibleHeadId - First candidate row identity.
 * @param {number} opts.lastRenderedRowCount - Count from the previous render.
 * @param {*} opts.lastRenderedHeadId - First row identity from the previous render.
 * @param {number} opts.lastBatchNewIdCount - Session-new IDs in the last batch.
 * @returns {{ visibleRowCap: number, renderCost: number }}
 */
function decide(opts) {
	opts = opts || {};

	const count = opts.visibleRowCount || 0;
	const headId = count ? opts.visibleHeadId : '';
	const lastRenderedRowCount = opts.lastRenderedRowCount || 0;
	const lastRenderedHeadId = opts.lastRenderedHeadId || '';
	let renderCost;

	if (!count && !lastRenderedRowCount) renderCost = 0;
	else if (count === lastRenderedRowCount && headId === lastRenderedHeadId) renderCost = 0;
	else if (count !== lastRenderedRowCount) renderCost = 1;
	else renderCost = Math.max(1, opts.lastBatchNewIdCount || 1);

	return {
		visibleRowCap: opts.weakDevice
			? Math.min(opts.rowLimit, opts.weakDeviceDisplayRowCap)
			: opts.rowLimit,
		renderCost: renderCost
	};
}

return baseclass.extend({
	decide: decide
});
