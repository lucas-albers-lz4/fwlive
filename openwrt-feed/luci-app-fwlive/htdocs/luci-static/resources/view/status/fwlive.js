'use strict';
/*
 * LuCI Firewall Live View — client-side view (view.extend + ubus log.read).
 * UI interaction patterns inspired by OPNsense Live View; original implementation
 * for OpenWrt (Apache-2.0). See docs/fwlive-ui-design-target.md in the fwview repo.
 */
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
		const status = document.getElementById('fwlive-status');
		const scroll = document.getElementById('fwlive-scroll');
		const filters = this.readFilters();
		this.updateHash(filters);

		const rows = this.entries
			.filter((row) => log.matchesFilter(row, filters))
			.slice(-this.visibleRows)
			.reverse();

		const atTop = scroll ? scroll.scrollTop < 8 : true;
		const prevScroll = scroll ? scroll.scrollTop : 0;

		body.innerHTML = '';
		if (empty)
			empty.style.display = rows.length ? 'none' : 'block';
		if (status) {
			status.textContent = rows.length
				? _('Showing %d of %d firewall events (newest first).').format(rows.length, this.entries.length)
				: '';
		}

		for (let i = 0; i < rows.length; i++) {
			const r = rows[i];
			const msgDisplay = log.formatMessageDisplay(r.message);
			const tr = E('tr', { 'class': i % 2 ? 'fwlive-row-alt' : '' }, [
				E('td', { 'class': 'fwlive-time' }, log.formatTimestampLocal(r.timestamp)),
				E('td', { 'class': log.actionRowClass(r.action) }, log.formatActionLabel(r.action)),
				E('td', { 'class': 'fwlive-iface' }, log.formatCell(r.interface_in)),
				E('td', { 'class': 'fwlive-iface' }, log.formatCell(r.interface_out)),
				E('td', { 'class': 'fwlive-dir' }, log.formatCell(r.direction)),
				E('td', { 'class': 'fwlive-proto' }, log.formatCell(r.proto)),
				E('td', { 'class': 'fwlive-addr' }, log.formatCell(r.src)),
				E('td', { 'class': 'fwlive-port' }, log.formatCell(r.sport)),
				E('td', { 'class': 'fwlive-addr' }, log.formatCell(r.dst)),
				E('td', { 'class': 'fwlive-port' }, log.formatCell(r.dport)),
				E('td', { 'class': 'fwlive-flags' }, log.formatCell(r.flags)),
				E('td', { 'class': 'fwlive-len' }, r.length != null ? String(r.length) : ''),
				E('td', {
					'class': 'fwlive-message',
					'title': r.message || ''
				}, msgDisplay || '—')
			]);
			body.appendChild(tr);
		}

		if (scroll) {
			if (atTop)
				scroll.scrollTop = 0;
			else
				scroll.scrollTop = prevScroll;
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
				.fwlive-status { margin: 0 0 8px; color: #666; font-size: 0.92em; }
				.fwlive-scroll {
					max-height: min(70vh, 640px);
					overflow: auto;
					border: 1px solid #ddd;
					border-radius: 3px;
					background: #fff;
				}
				#fwlive-table { margin: 0; width: 100%; table-layout: auto; border-collapse: collapse; }
				#fwlive-table thead th {
					position: sticky;
					top: 0;
					z-index: 2;
					background: #f0f0f0;
					border-bottom: 2px solid #ccc;
					white-space: nowrap;
					padding: 6px 8px;
					font-size: 0.9em;
				}
				#fwlive-table tbody td {
					padding: 4px 8px;
					border-bottom: 1px solid #eee;
					vertical-align: top;
					font-size: 0.92em;
				}
				.fwlive-row-alt td { background: #fafafa; }
				.fwlive-time, .fwlive-addr, .fwlive-port, .fwlive-len {
					font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
					white-space: nowrap;
				}
				.fwlive-port, .fwlive-len { text-align: right; }
				.fwlive-iface, .fwlive-proto, .fwlive-dir, .fwlive-flags { white-space: nowrap; }
				.fwlive-action {
					font-weight: 700;
					text-transform: lowercase;
					white-space: nowrap;
				}
				.fwlive-deny { color: #b30000; }
				.fwlive-pass { color: #1f7a1f; }
				.fwlive-unknown { color: #666; font-weight: 500; }
				.fwlive-message {
					max-width: 28em;
					min-width: 12em;
					word-break: break-word;
					font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
					font-size: 0.85em;
					color: #444;
				}
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
			E('p', { 'id': 'fwlive-status', 'class': 'fwlive-status' }, ''),
			E('div', { 'id': 'fwlive-scroll', 'class': 'fwlive-scroll' }, [
				E('table', { 'id': 'fwlive-table', 'class': 'table cbi-section-table' }, [
					E('thead', {}, E('tr', {}, [
						E('th', {}, _('Time')),
						E('th', {}, _('Action')),
						E('th', {}, _('IN')),
						E('th', {}, _('OUT')),
						E('th', {}, _('Dir')),
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
				])
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
