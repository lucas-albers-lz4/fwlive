'use strict';
'require fwlive.log as log';

/**
 * Filter-chip DOM renderer for luci-app-fwlive.
 *
 * renderFilterChips(host, state, callbacks) → void
 *   host      - container element (cleared and rebuilt; element itself is kept)
 *   state     - shallow copy: { filters: {q, action, interface, proto, src, dst, sport, dport},
 *                               chipFields: [{key, label}, ...] }
 *   callbacks - { onInvert(field, ev), onClear(field, ev), onClearAll(ev) }
 *
 * Modules must not mutate state. host is cleared then rebuilt (idempotent replace).
 */

function chipLabelNodes(field, val) {
	const p = log.parseFilterValue(val);
	if (!p.value)
		return [ '' ];

	if (!p.negate)
		return [ log.formatFilterChipLabel(field, val) ];

	if (field === 'q' || field === 'src' || field === 'dst')
		return [
			field + ': ',
			E('strong', { 'class': 'fwlive-chip-not' }, 'not'),
			' contains ' + p.value
		];

	return [
		field + ': ',
		E('strong', { 'class': 'fwlive-chip-not' }, 'not'),
		' ' + p.value
	];
}

function renderFilterChips(host, state, callbacks) {
	const filters = state.filters || {};
	const chipFields = state.chipFields || [];
	const chips = [];

	for (let i = 0; i < chipFields.length; i++) {
		const spec = chipFields[i];
		const val = filters[spec.key];
		if (!val)
			continue;

		const parsed = log.parseFilterValue(val);
		const negated = parsed.negate;

		chips.push(E('span', {
			'class': 'fwlive-chip' + (negated ? ' fwlive-chip-negated' : '')
		}, [
			E('span', { 'class': 'fwlive-chip-label' }, chipLabelNodes(spec.label, val)),
			E('span', {
				'class': 'fwlive-chip-invert-wrap',
				'data-tip': negated ? _('Include instead') : _('Exclude instead')
			}, [
				E('button', {
					'type': 'button',
					'class': 'fwlive-chip-invert',
					'click': function(ev) { callbacks.onInvert(spec.key, ev); }
				}, '≠')
			]),
			E('a', {
				'href': '#',
				'class': 'fwlive-chip-remove',
				'title': _('Remove filter'),
				'click': function(ev) { callbacks.onClear(spec.key, ev); }
			}, '×')
		]));
	}

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

return {
	renderFilterChips: renderFilterChips
};
