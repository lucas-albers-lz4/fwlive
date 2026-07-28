'use strict';
'require baseclass'; /* LuCI require() needs Class.isSubclass — plain return {} fails */
'require fwlive.log as log';

/**
 * Filter-chip DOM renderer for luci-app-fwlive.
 *
 * renderFilterChips(host, state, callbacks) → void
 *   host      - container element (cleared and rebuilt; element itself is kept)
 *   state     - shallow copy: { filters, chipFields, chipStyle }
 *               chipStyle: 'labels' (default) | 'symbols' | 'tone'
 *   callbacks - { onInvert(field, ev), onClear(field, ev), onClearAll(ev) }
 *
 * Modules must not mutate state. host is cleared then rebuilt (idempotent replace).
 */

function normalizeChipStyle(style) {
	if (style === 'symbols' || style === 'tone')
		return style;
	return 'labels';
}

function chipValueNodes(field, val, style) {
	const p = log.parseFilterValue(val);
	if (!p.value)
		return [ '' ];

	const valueNode = (style === 'labels' && p.negate)
		? E('span', { 'class': 'fwlive-chip-strike' }, p.value)
		: p.value;

	if (!p.negate) {
		if (style === 'labels')
			return [
				E('span', { 'class': 'fwlive-chip-polarity' }, _('is')),
				' ',
				log.formatFilterChipLabel(field, val)
			];
		return [ log.formatFilterChipLabel(field, val) ];
	}

	if (field === 'q' || field === 'src' || field === 'dst')
		return [
			field + ': ',
			E('strong', { 'class': 'fwlive-chip-not' }, _('not')),
			' contains ',
			valueNode
		];

	return [
		field + ': ',
		E('strong', { 'class': 'fwlive-chip-not' }, _('not')),
		' ',
		valueNode
	];
}

function chipLeadingSym(style, negated) {
	/* symbols: always show = / ≠. labels: light touch of B — ≠ only on exclude. */
	if (style === 'symbols')
		return E('span', {
			'class': 'fwlive-chip-sym',
			'aria-hidden': 'true'
		}, negated ? '≠' : '=');

	if (style === 'labels' && negated)
		return E('span', {
			'class': 'fwlive-chip-sym fwlive-chip-sym-light',
			'aria-hidden': 'true'
		}, '≠');

	return null;
}

function renderFilterChips(host, state, callbacks) {
	const filters = state.filters || {};
	const chipFields = state.chipFields || [];
	const style = normalizeChipStyle(state.chipStyle);
	const chips = [];

	for (let i = 0; i < chipFields.length; i++) {
		const spec = chipFields[i];
		const val = filters[spec.key];
		if (!val)
			continue;

		const parsed = log.parseFilterValue(val);
		const negated = parsed.negate;
		const kids = [];
		const lead = chipLeadingSym(style, negated);
		if (lead)
			kids.push(lead);

		kids.push(E('span', { 'class': 'fwlive-chip-label' }, chipValueNodes(spec.label, val, style)));
		kids.push(E('span', {
			'class': 'fwlive-chip-invert-wrap',
			'data-tip': negated ? _('Include instead') : _('Exclude instead')
		}, [
			E('button', {
				'type': 'button',
				'class': 'fwlive-chip-invert',
				'click': function(ev) { callbacks.onInvert(spec.key, ev); }
			}, '≠')
		]));
		kids.push(E('a', {
			'href': '#',
			'class': 'fwlive-chip-remove',
			'title': _('Remove filter'),
			'click': function(ev) { callbacks.onClear(spec.key, ev); }
		}, '×'));

		chips.push(E('span', {
			'class': 'fwlive-chip'
				+ (negated ? ' fwlive-chip-negated' : ' fwlive-chip-include')
		}, kids));
	}

	host.className = 'fwlive-chips fwlive-chips-' + style;
	host.innerHTML = '';
	if (!chips.length) {
		host.style.display = 'none';
		return;
	}

	host.style.display = 'flex';
	for (let i = 0; i < chips.length; i++)
		host.appendChild(chips[i]);

	host.appendChild(E('a', {
		'href': '#',
		'class': 'fwlive-chip-clear',
		'click': function(ev) { callbacks.onClearAll(ev); }
	}, _('Clear all')));
}

return baseclass.extend({
	normalizeChipStyle: normalizeChipStyle,
	renderFilterChips: renderFilterChips
});
