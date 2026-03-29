'use strict';
'require view';
'require poll';
'require rpc';
'require fwlive.parser as parser';

const callLogRead = rpc.declare({
	object: 'log',
	method: 'read',
	params: [ 'lines', 'stream', 'oneshot' ],
	expect: { log: [] }
});

function matchesFilter(row, filters) {
	if (filters.q && !Object.values(row).join(' ').toLowerCase().includes(filters.q.toLowerCase()))
		return false;
	if (filters.action && row.action !== filters.action)
		return false;
	if (filters.interface && row.interface !== filters.interface)
		return false;
	if (filters.proto && row.proto !== filters.proto)
		return false;
	if (filters.src && !row.src.includes(filters.src))
		return false;
	if (filters.dst && !row.dst.includes(filters.dst))
		return false;
	if (filters.sport && row.sport !== filters.sport)
		return false;
	if (filters.dport && row.dport !== filters.dport)
		return false;
	return true;
}

function actionRowClass(action) {
	const a = (action || '').toUpperCase();
	if (a.match(/DROP|REJECT|DENY|BLOCK/))
		return 'fwlive-deny';
	if (a.match(/ACCEPT|ALLOW|PASS/))
		return 'fwlive-pass';
	return '';
}

return view.extend({
	maxHistory: 2000,
	visibleRows: 200,
	entries: [],

	readFilters() {
		return {
			q: (document.getElementById('fwlive-q')?.value || '').trim(),
			action: document.getElementById('fwlive-action')?.value || '',
			interface: document.getElementById('fwlive-interface')?.value || '',
			proto: document.getElementById('fwlive-proto')?.value || '',
			src: (document.getElementById('fwlive-src')?.value || '').trim(),
			dst: (document.getElementById('fwlive-dst')?.value || '').trim(),
			sport: (document.getElementById('fwlive-sport')?.value || '').trim(),
			dport: (document.getElementById('fwlive-dport')?.value || '').trim()
		};
	},

	updateHash(filters) {
		const parts = Object.keys(filters)
			.filter((k) => filters[k])
			.map((k) => '%s=%s'.format(encodeURIComponent(k), encodeURIComponent(filters[k])));
		location.hash = parts.join('&');
	},

	applyHash() {
		if (!location.hash || location.hash.length < 2)
			return;

		const entries = location.hash.substring(1).split('&');
		for (let i = 0; i < entries.length; i++) {
			const kv = entries[i].split('=');
			if (kv.length !== 2)
				continue;
			const id = 'fwlive-' + decodeURIComponent(kv[0]);
			const el = document.getElementById(id);
			if (el)
				el.value = decodeURIComponent(kv[1]);
		}
	},

	async fetchEntries() {
		const raw = await callLogRead(this.maxHistory, false, true);
		const normalized = [];
		const seen = {};

		for (let i = 0; i < raw.length; i++) {
			const row = parser.normalizeEntry(raw[i]);
			if (seen[row.id])
				continue;
			seen[row.id] = true;
			normalized.push(row);
		}

		this.entries = normalized.reverse().slice(-this.maxHistory);
	},

	renderRows() {
		const table = document.getElementById('fwlive-table');
		if (!table)
			return;

		const body = table.querySelector('tbody');
		const filters = this.readFilters();
		this.updateHash(filters);

		const rows = this.entries
			.filter((row) => matchesFilter(row, filters))
			.slice(-this.visibleRows)
			.reverse();

		body.innerHTML = '';
		for (let i = 0; i < rows.length; i++) {
			const r = rows[i];
			const tr = E('tr', {}, [
				E('td', {}, r.timestamp || '-'),
				E('td', { 'class': actionRowClass(r.action) }, r.action),
				E('td', {}, r.interface || '-'),
				E('td', {}, r.direction || '-'),
				E('td', {}, r.proto || '-'),
				E('td', {}, r.src || '-'),
				E('td', {}, r.sport || '-'),
				E('td', {}, r.dst || '-'),
				E('td', {}, r.dport || '-'),
				E('td', { 'class': 'fwlive-message' }, r.message || '-')
			]);
			body.appendChild(tr);
		}
	},

	attachHandlers() {
		const ids = [ 'q', 'action', 'interface', 'proto', 'src', 'dst', 'sport', 'dport' ];
		for (let i = 0; i < ids.length; i++) {
			const el = document.getElementById('fwlive-' + ids[i]);
			if (el)
				el.addEventListener('input', this.renderRows.bind(this));
		}
	},

	async pollData() {
		await this.fetchEntries();
		this.renderRows();
	},

	load() {
		poll.add(this.pollData.bind(this), 1);
		return this.fetchEntries();
	},

	render() {
		return E('div', { 'class': 'cbi-map' }, [
			E('style', {}, `
				.fwlive-grid { display: grid; grid-template-columns: repeat(4, minmax(140px, 1fr)); gap: 8px; margin-bottom: 12px; }
				.fwlive-deny { color: #b30000; font-weight: 700; }
				.fwlive-pass { color: #1f7a1f; font-weight: 700; }
				.fwlive-message { max-width: 420px; word-break: break-word; }
			`),
			E('h2', {}, _('Firewall Live View')),
			E('p', {}, _('Live nftables/firewall4 event view for troubleshooting rule behavior.')),
			E('div', { 'class': 'fwlive-grid' }, [
				E('input', { 'id': 'fwlive-q', 'class': 'cbi-input-text', 'placeholder': _('Quick search') }),
				E('select', { 'id': 'fwlive-action', 'class': 'cbi-input-select' }, [
					E('option', { 'value': '' }, _('Any action')),
					E('option', { 'value': 'ACCEPT' }, 'ACCEPT'),
					E('option', { 'value': 'ALLOW' }, 'ALLOW'),
					E('option', { 'value': 'PASS' }, 'PASS'),
					E('option', { 'value': 'DROP' }, 'DROP'),
					E('option', { 'value': 'REJECT' }, 'REJECT'),
					E('option', { 'value': 'DENY' }, 'DENY'),
					E('option', { 'value': 'BLOCK' }, 'BLOCK'),
					E('option', { 'value': 'UNKNOWN' }, 'UNKNOWN')
				]),
				E('input', { 'id': 'fwlive-interface', 'class': 'cbi-input-text', 'placeholder': _('Interface (IN/OUT)') }),
				E('input', { 'id': 'fwlive-proto', 'class': 'cbi-input-text', 'placeholder': _('Protocol (TCP/UDP/ICMP)') }),
				E('input', { 'id': 'fwlive-src', 'class': 'cbi-input-text', 'placeholder': _('Source IP contains') }),
				E('input', { 'id': 'fwlive-sport', 'class': 'cbi-input-text', 'placeholder': _('Source port') }),
				E('input', { 'id': 'fwlive-dst', 'class': 'cbi-input-text', 'placeholder': _('Destination IP contains') }),
				E('input', { 'id': 'fwlive-dport', 'class': 'cbi-input-text', 'placeholder': _('Destination port') })
			]),
			E('table', { 'id': 'fwlive-table', 'class': 'table cbi-section-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Time')),
					E('th', {}, _('Action')),
					E('th', {}, _('Interface')),
					E('th', {}, _('Direction')),
					E('th', {}, _('Proto')),
					E('th', {}, _('Source')),
					E('th', {}, _('SPort')),
					E('th', {}, _('Destination')),
					E('th', {}, _('DPort')),
					E('th', {}, _('Message'))
				])),
				E('tbody', {}, [])
			]),
			E('p', { 'class': 'cbi-value-description' }, _('Tip: filter state is encoded into URL hash for sharing and quick reload.'))
		]);
	},

	addFooter() {
		this.applyHash();
		this.attachHandlers();
		this.renderRows();
	}
});
