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
	paused: false,

	FILTER_CHIP_FIELDS: [
		{ key: 'q', label: 'search' },
		{ key: 'action', label: 'action' },
		{ key: 'interface', label: 'iface' },
		{ key: 'proto', label: 'proto' },
		{ key: 'src', label: 'src' },
		{ key: 'dst', label: 'dst' },
		{ key: 'sport', label: 'sport' },
		{ key: 'dport', label: 'dport' }
	],

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

	filteredRows() {
		const filters = this.readFilters();
		return this.entries
			.filter((row) => log.matchesFilter(row, filters))
			.slice(-this.visibleRows)
			.reverse();
	},

	updateStatus(rows) {
		const status = document.getElementById('fwlive-status');
		if (!status)
			return;

		const matchCount = rows ? rows.length : this.filteredRows().length;

		if (this.paused) {
			status.className = 'fwlive-status fwlive-status-paused';
			status.textContent = matchCount
				? _('Paused — %d events in buffer (%d match filters). Resume to refresh the table.').format(this.entries.length, matchCount)
				: _('Paused — %d events in buffer. Resume to refresh the table.').format(this.entries.length);
			return;
		}

		status.className = 'fwlive-status';
		status.textContent = matchCount
			? _('Showing %d of %d firewall events (newest first).').format(matchCount, this.entries.length)
			: '';
	},

	filterClick(field, value, ev) {
		if (ev && ev.preventDefault)
			ev.preventDefault();
		if (!value)
			return;

		const el = document.getElementById('fwlive-' + field);
		if (!el)
			return;

		el.value = value;
		this.onFilterInput();
	},

	filterLink(field, value, label) {
		if (!value)
			return log.formatCell(value);

		return E('a', {
			'href': '#',
			'class': 'fwlive-filter-link',
			'title': _('Filter by %s').format(field),
			'click': this.filterClick.bind(this, field, value)
		}, label || value);
	},

	ruleAdminPath(hint) {
		if (hint === 'fw4')
			return 'admin/network/firewall/rules';

		return 'admin/status/nftables';
	},

	luciUrl(path) {
		if (typeof L !== 'undefined' && L.url)
			return L.url(path);

		return '/cgi-bin/luci/' + path;
	},

	ruleAdminLink(hint, label) {
		if (!hint)
			return log.formatCell(hint);

		const path = this.ruleAdminPath(hint);
		const url = '%s#%s'.format(this.luciUrl(path), encodeURIComponent(hint));
		const text = label || hint;

		return E('a', {
			'href': '#',
			'class': 'fwlive-filter-link fwlive-rule-link',
			'title': _('Filter logs by rule (hint: %s). Ctrl+click to open firewall settings.').format(hint),
			'click': function(ev) {
				if (ev && (ev.ctrlKey || ev.metaKey)) {
					if (ev.preventDefault)
						ev.preventDefault();
					window.location = url;
					return;
				}

				this.filterClick('q', hint, ev);
			}.bind(this)
		}, text);
	},

	ifaceLink(value) {
		if (!value)
			return log.formatCell(value);

		return E('a', {
			'href': '#',
			'class': 'fwlive-filter-link fwlive-iface-badge',
			'title': _('Filter by interface'),
			'click': this.filterClick.bind(this, 'interface', value)
		}, value);
	},

	clearFilter(field, ev) {
		if (ev && ev.preventDefault)
			ev.preventDefault();

		const el = document.getElementById('fwlive-' + field);
		if (el)
			el.value = '';

		this.onFilterInput();
	},

	clearAllFilters(ev) {
		if (ev && ev.preventDefault)
			ev.preventDefault();

		for (let i = 0; i < this.FILTER_CHIP_FIELDS.length; i++) {
			const el = document.getElementById('fwlive-' + this.FILTER_CHIP_FIELDS[i].key);
			if (el)
				el.value = '';
		}

		this.onFilterInput();
	},

	renderFilterChips() {
		const bar = document.getElementById('fwlive-chips');
		if (!bar)
			return;

		const filters = this.readFilters();
		const chips = [];

		for (let i = 0; i < this.FILTER_CHIP_FIELDS.length; i++) {
			const spec = this.FILTER_CHIP_FIELDS[i];
			const val = filters[spec.key];
			if (!val)
				continue;

			chips.push(E('span', { 'class': 'fwlive-chip' }, [
				E('span', { 'class': 'fwlive-chip-label' }, '%s: %s'.format(spec.label, val)),
				E('a', {
					'href': '#',
					'class': 'fwlive-chip-remove',
					'title': _('Remove filter'),
					'click': this.clearFilter.bind(this, spec.key)
				}, '×')
			]));
		}

		bar.innerHTML = '';
		if (!chips.length) {
			bar.style.display = 'none';
			return;
		}

		bar.style.display = 'flex';
		for (let i = 0; i < chips.length; i++)
			bar.appendChild(chips[i]);

		bar.appendChild(E('a', {
			'href': '#',
			'class': 'fwlive-chip-clear',
			'click': this.clearAllFilters.bind(this)
		}, _('Clear all')));
	},

	togglePaused() {
		this.paused = !this.paused;
		const btn = document.getElementById('fwlive-pause');
		if (btn)
			btn.textContent = this.paused ? _('Resume') : _('Pause');

		if (this.paused)
			this.updateStatus();
		else
			this.renderRows();
	},

	renderRows() {
		const table = document.getElementById('fwlive-table');
		if (!table)
			return;

		const body = table.querySelector('tbody');
		const empty = document.getElementById('fwlive-empty');
		const scroll = document.getElementById('fwlive-scroll');
		this.updateHash(this.readFilters());

		const rows = this.filteredRows();

		const atTop = scroll ? scroll.scrollTop < 8 : true;
		const prevScroll = scroll ? scroll.scrollTop : 0;

		body.innerHTML = '';
		if (empty)
			empty.style.display = rows.length ? 'none' : 'block';
		this.updateStatus(rows);
		this.renderFilterChips();

		for (let i = 0; i < rows.length; i++) {
			const r = rows[i];
			const msgDisplay = log.formatMessageDisplay(r.message);
			const actionCell = r.action && r.action !== 'unknown'
				? this.filterLink('action', r.action, log.formatActionLabel(r.action))
				: log.formatActionLabel(r.action);
			const tr = E('tr', { 'class': i % 2 ? 'fwlive-row-alt' : '' }, [
				E('td', { 'class': 'fwlive-time' }, log.formatTimestampLocal(r.timestamp)),
				E('td', { 'class': log.actionRowClass(r.action) }, actionCell),
				E('td', { 'class': 'fwlive-rule' }, this.ruleAdminLink(r.rule_hint, r.rule_label)),
				E('td', { 'class': 'fwlive-iface' }, this.ifaceLink(r.interface_in)),
				E('td', { 'class': 'fwlive-iface' }, this.ifaceLink(r.interface_out)),
				E('td', { 'class': 'fwlive-dir' }, log.formatCell(r.direction)),
				E('td', { 'class': 'fwlive-proto' }, this.filterLink('proto', r.proto)),
				E('td', { 'class': 'fwlive-addr' }, this.filterLink('src', r.src)),
				E('td', { 'class': 'fwlive-port' }, this.filterLink('sport', r.sport)),
				E('td', { 'class': 'fwlive-addr' }, this.filterLink('dst', r.dst)),
				E('td', { 'class': 'fwlive-port' }, this.filterLink('dport', r.dport)),
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

	onFilterInput() {
		if (this.paused) {
			this.renderFilterChips();
			this.updateStatus();
		} else {
			this.renderRows();
		}
	},

	attachHandlers() {
		const ids = [ 'q', 'action', 'interface', 'proto', 'src', 'dst', 'sport', 'dport' ];
		for (let i = 0; i < ids.length; i++) {
			const el = document.getElementById('fwlive-' + ids[i]);
			if (!el)
				continue;
			el.addEventListener('input', this.onFilterInput.bind(this));
			if (el.tagName === 'SELECT')
				el.addEventListener('change', this.onFilterInput.bind(this));
		}

		const pauseBtn = document.getElementById('fwlive-pause');
		if (pauseBtn)
			pauseBtn.addEventListener('click', this.togglePaused.bind(this));
	},

	async pollData() {
		await this.fetchEntries();
		if (this.paused)
			this.updateStatus();
		else
			this.renderRows();
	},

	load() {
		poll.add(this.pollData.bind(this), 1);
		return this.fetchEntries();
	},

	render() {
		return E('div', { 'class': 'cbi-map' }, [
			E('style', {}, `
				.fwlive-toolbar {
					display: flex;
					align-items: center;
					gap: 12px;
					margin-bottom: 10px;
					flex-wrap: wrap;
				}
				.fwlive-grid { display: grid; grid-template-columns: repeat(4, minmax(140px, 1fr)); gap: 8px; margin-bottom: 12px; }
				.fwlive-status { margin: 0; color: #666; font-size: 0.92em; flex: 1; min-width: 200px; }
				.fwlive-status-paused { color: #a65e00; font-weight: 600; }
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
				.fwlive-rule, .fwlive-iface, .fwlive-proto, .fwlive-dir, .fwlive-flags { white-space: nowrap; }
				.fwlive-rule { font-size: 0.88em; }
				.fwlive-rule-link {
					color: #0066cc;
					text-decoration: none;
					font-weight: 500;
				}
				.fwlive-rule-link:hover { text-decoration: underline; }
				.fwlive-iface-badge {
					display: inline-block;
					padding: 1px 6px;
					background: #eee;
					border: 1px solid #ccc;
					border-radius: 3px;
					font-size: 0.85em;
					text-decoration: none;
				}
				.fwlive-iface-badge:hover { background: #e0e8f5; border-color: #99b3dd; }
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
				.fwlive-filter-link {
					color: inherit;
					text-decoration: underline;
					text-decoration-style: dotted;
					cursor: pointer;
				}
				.fwlive-filter-link:hover { color: #0066cc; }
				.fwlive-chips {
					display: none;
					flex-wrap: wrap;
					align-items: center;
					gap: 6px;
					margin: 0 0 10px;
				}
				.fwlive-chip {
					display: inline-flex;
					align-items: center;
					gap: 4px;
					padding: 2px 8px;
					background: #e8f0fe;
					border: 1px solid #c5d7f5;
					border-radius: 3px;
					font-size: 0.88em;
				}
				.fwlive-chip-remove {
					color: #555;
					text-decoration: none;
					font-weight: 700;
					line-height: 1;
				}
				.fwlive-chip-remove:hover { color: #b30000; }
				.fwlive-chip-clear {
					font-size: 0.88em;
					margin-left: 4px;
				}
			`),
			E('h2', {}, _('Firewall Live View')),
			E('p', {}, _('Live nftables/firewall4 events from logd (firewall-shaped lines only).')),
			E('div', { 'class': 'fwlive-toolbar' }, [
				E('button', {
					'id': 'fwlive-pause',
					'class': 'cbi-button cbi-button-action',
					'type': 'button'
				}, _('Pause')),
				E('span', { 'id': 'fwlive-status', 'class': 'fwlive-status' }, '')
			]),
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
			E('div', { 'id': 'fwlive-chips', 'class': 'fwlive-chips' }, []),
			E('p', {
				'id': 'fwlive-empty',
				'class': 'fwlive-empty',
				'style': 'display:none'
			}, _('No firewall log events yet. Add log to fw4/nft rules — see docs/fwlive-nft-logging.md on the build host.')),
			E('div', { 'id': 'fwlive-scroll', 'class': 'fwlive-scroll' }, [
				E('table', { 'id': 'fwlive-table', 'class': 'table cbi-section-table' }, [
					E('thead', {}, E('tr', {}, [
						E('th', {}, _('Time')),
						E('th', {}, _('Action')),
						E('th', {}, _('Rule')),
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
			E('p', { 'class': 'cbi-value-description' }, _('Tip: click table values to filter; Ctrl+click Rule to open firewall settings. URL hash preserves filter fields on reload.'))
		]);
	},

	addFooter() {
		this.applyHash();
		this.attachHandlers();
		this.renderRows();
	}
});
