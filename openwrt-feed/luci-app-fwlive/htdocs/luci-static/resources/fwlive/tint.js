'use strict';

/**
 * Row-tint paint helpers for luci-app-fwlive (plain LuCI module).
 */
var PAINT_DELTA_MIN = 8;
var PASS_HEX = '#46a546';
var DENY_HEX = '#ca3c3c';

function parseCssRgbChannels(value) {
	if (!value)
		return null;

	const s = String(value).trim().toLowerCase();
	if (s === 'transparent' || s === 'rgba(0, 0, 0, 0)' || s === 'rgba(0,0,0,0)')
		return null;

	const rgb = s.match(/rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)/i);
	if (rgb)
		return [ parseFloat(rgb[1]), parseFloat(rgb[2]), parseFloat(rgb[3]) ];

	/* color-mix() often serializes as color(srgb r g b[/a]) with 0..1 channels. */
	const modern = s.match(/color\(\s*srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)/i);
	if (modern)
		return [
			parseFloat(modern[1]) * 255,
			parseFloat(modern[2]) * 255,
			parseFloat(modern[3]) * 255
		];

	return null;
}

function cssColorPaintDelta(a, b) {
	const ca = parseCssRgbChannels(a);
	const cb = parseCssRgbChannels(b);
	/* Transparent vs opaque color is a real paint change (common off-state). */
	if (!ca && !cb)
		return 0;
	if (!ca && cb)
		return Math.abs(cb[0]) + Math.abs(cb[1]) + Math.abs(cb[2]);
	if (ca && !cb)
		return Math.abs(ca[0]) + Math.abs(ca[1]) + Math.abs(ca[2]);

	return Math.abs(ca[0] - cb[0]) + Math.abs(ca[1] - cb[1]) + Math.abs(ca[2] - cb[2]);
}

function tintShouldEngageFallback(opts) {
	const o = opts || {};
	const minDelta = (typeof o.minDelta === 'number') ? o.minDelta : PAINT_DELTA_MIN;

	/* Visible paint is the success criterion; token/CSS.supports are only used when
	   paint cannot be measured (no delta sample yet). */
	if (typeof o.paintDelta === 'number')
		return o.paintDelta < minDelta;

	if (o.tokenResolved === false)
		return true;

	return false;
}

return {
	PAINT_DELTA_MIN: PAINT_DELTA_MIN,
	PASS_HEX: PASS_HEX,
	DENY_HEX: DENY_HEX,
	parseCssRgbChannels: parseCssRgbChannels,
	cssColorPaintDelta: cssColorPaintDelta,
	tintShouldEngageFallback: tintShouldEngageFallback
};
