'use strict';
'require view';
'require poll';
'require rpc';
'require fwlive.log as log';

const callLogRead = rpc.declare({
	object: 'log',
	method: 'read',
	params: [ 'lines', 'stream', 'oneshot' ],
	expect: { log: [] }
});

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
			if (!log.isFirewallEvent(raw[i]))
				continue;

			const row = log.normalizeEntry(raw[i]);
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
		const empty = document.getElementById('fwlive-empty');
		const filters = this.readFilters();
		this.updateHash(filters);

		const rows = this.entries
			.filter((row) => log.matchesFilter(row, filters))
			.slice(-this.visibleRows)
			.reverse();

		body.innerHTML = '';
		if (empty)
			empty.style.display = rows.length ? 'none' : 'block';

		for (let i = 0; i < rows.length; i++) {
			const r = rows[i];
			const tr = E('tr', {}, [
				E('td', {}, r.timestamp_display || '-'),
				E('td', { 'class': log.actionRowClass(r.action) }, r.action || '-'),
				E('td', {}, r.interface_in || '-'),
				E('td', {}, r.interface_out || '-'),
				E('td', {}, r.direction || '-'),
				E('td', {}, r.proto || '-'),
				E('td', {}, r.src || '-'),
				E('td', {}, r.sport || '-'),
				E('td', {}, r.dst || '-'),
				E('td', {}, r.dport || '-'),
				E('td', {}, r.flags || '-'),
				E('td', {}, r.length != null ? String(r.length) : '-'),
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
				.fwlive-message { max-width: 360px; word-break: break-word; }
				.fwlive-empty { margin: 12px 0; padding: 10px; background: #f8f8f8; border: 1px dashed #ccc; }
			`),
			E('h2', {}, _('Firewall Live View')),
			E('p', {}, _('Live nftables/firewall4 events from logd (firewall-shaped lines only).')),
			E('div', { 'class': 'fwlive-grid' }, [
				E('input', { 'id': 'fwlive-q', 'class': 'cbi-input-text', 'placeholder': _('Quick search') }),
				E('select', { 'id': 'fwlive-action', 'class': 'cbi-input-select' }, [
					E('option', { 'value': '' }, _('Any action')),
					E('option', { 'value': 'pass' }, 'pass'),
					E('option', { 'value': 'block' }, 'block'),
					E('option', { 'value': 'drop' }, 'drop'),
					E('option', { 'value': 'reject' }, 'reject'),
					E('option', { 'value': 'unknown' }, 'unknown')
				]),
				E('input', { 'id': 'fwlive-interface', 'class': 'cbi-input-text', 'placeholder': _('Interface IN or OUT') }),
				E('input', { 'id': 'fwlive-proto', 'class': 'cbi-input-text', 'placeholder': _('Protocol (TCP/UDP/ICMP)') }),
				E('input', { 'id': 'fwlive-src', 'class': 'cbi-input-text', 'placeholder': _('Source IP contains') }),
				E('input', { 'id': 'fwlive-sport', 'class': 'cbi-input-text', 'placeholder': _('Source port') }),
				E('input', { 'id': 'fwlive-dst', 'class': 'cbi-input-text', 'placeholder': _('Destination IP contains') }),
				E('input', { 'id': 'fwlive-dport', 'class': 'cbi-input-text', 'placeholder': _('Destination port') })
			]),
			E('p', {
				'id': 'fwlive-empty',
				'class': 'fwlive-empty',
				'style': 'display:none'
			}, _('No firewall log events yet. Add log to fw4/nft rules — see docs/fwlive-nft-logging.md on the build host.')),
			E('table', { 'id': 'fwlive-table', 'class': 'table cbi-section-table' }, [
				E('thead', {}, E('tr', {}, [
					E('th', {}, _('Time')),
					E('th', {}, _('Action')),
					E('th', {}, _('IN')),
					E('th', {}, _('OUT')),
					E('th', {}, _('Direction')),
					E('th', {}, _('Proto')),
					E('th', {}, _('Source')),
					E('th', {}, _('SPort')),
					E('th', {}, _('Destination')),
					E('th', {}, _('DPort')),
					E('th', {}, _('Flags')),
					E('th', {}, _('Len')),
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
