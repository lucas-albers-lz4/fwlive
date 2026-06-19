'use strict';
/*
 * LuCI Firewall Live View — client-side view (view.extend + ubus fwlive.poll).
 * UI interaction patterns inspired by OPNsense Live View; original implementation
 * for OpenWrt (Apache-2.0). See docs/fwlive-ui-design-target.md in the fwlive repo.
 */
'require view';
'require poll';
'require rpc';
'require fwlive.log as log';

const callFwlivePoll = rpc.declare({
	object: 'fwlive',
	method: 'poll',
	params: [ 'addresses' ],
	expect: { log: [] }
});

const callFwliveRules = rpc.declare({
	object: 'fwlive',
	method: 'rules',
	expect: { rules: {} }
});

const callFwliveResolve = rpc.declare({
	object: 'fwlive',
	method: 'resolve',
	params: [ 'addresses' ],
	expect: { names: {} }
});

const ROW_LIMIT_OPTIONS = [ 25, 50, 100, 250, 500, 1000, 2000 ];
const DEFAULT_ROW_LIMIT = 100;
const FETCH_LINES_MAX = 2000;
const RENDER_CAP_PER_SEC = 250;
const VIEW_MODES = [ 'simple', 'detailed' ];
const COLUMN_SETS = {
	simple: [ 'action', 'time', 'iface', 'flow', 'proto', 'rule' ],
	detailed: [ 'time', 'action', 'rule', 'iface_in', 'iface_out', 'dir', 'proto', 'src', 'sport', 'dst', 'dport', 'flags', 'len', 'message' ]
};

return view.extend({
	rowLimit: DEFAULT_ROW_LIMIT,
	maxHistory: DEFAULT_ROW_LIMIT,
	fetchLines: FETCH_LINES_MAX,
	visibleRows: DEFAULT_ROW_LIMIT,
	entries: [],
	sessionSeen: null,
	sessionNewTotal: 0,
	sessionAtPause: 0,
	pauseBufferLoading: false,
	paused: false,
	messageLayout: 'wrap',
	renderBucket: RENDER_CAP_PER_SEC,
	renderBucketMs: 0,
	floodSuppressed: false,
	lastPollNewEvents: 0,
	showHostnames: false,
	hostnameCache: null,
	hostnameFailed: null,
	resolveInFlight: false,
	lastRenderedRowCount: 0,
	lastRenderedHeadId: '',
	followLive: true,
	rulesMap: {},
	viewMode: 'simple',
	expandedRowId: null,

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
		if (this.rowLimit !== DEFAULT_ROW_LIMIT)
			parts.push('limit=%s'.format(encodeURIComponent(this.rowLimit)));
		if (this.viewMode === 'detailed')
			parts.push('view=detailed');
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
			const key = decodeURIComponent(kv[0]);
			const val = decodeURIComponent(kv[1]);
			if (key === 'limit') {
				const n = parseInt(val, 10);
				if (isFinite(n) && ROW_LIMIT_OPTIONS.indexOf(n) >= 0) {
					this.applyRowLimit(n);
					this.saveRowLimit();
				}
				continue;
			}
			if (key === 'view') {
				if (val === 'advanced' || val === 'detailed')
					this.viewMode = 'detailed';
				else if (val === 'simple')
					this.viewMode = 'simple';
				continue;
			}
			const el = document.getElementById('fwlive-' + key);
			if (el)
				el.value = val;
		}
	},

	readViewMode() {
		try {
			const v = localStorage.getItem('fwlive-view-mode');
			if (v === 'advanced' || v === 'detailed')
				return 'detailed';
			if (v === 'simple')
				return 'simple';
		} catch (e) {
			/* private mode / no storage */
		}

		return 'simple';
	},

	saveViewMode() {
		try {
			localStorage.setItem('fwlive-view-mode', this.viewMode);
		} catch (e) {
			/* private mode / no storage */
		}
	},

	readShowHostnames() {
		try {
			return localStorage.getItem('fwlive-show-hostnames') === '1';
		} catch (e) {
			return false;
		}
	},

	saveShowHostnames() {
		try {
			localStorage.setItem('fwlive-show-hostnames', this.showHostnames ? '1' : '0');
		} catch (e) {
			/* private mode / no storage */
		}
	},

	isLikelyIp(addr) {
		if (!addr)
			return false;

		return /^[\da-fA-F:.]+$/.test(addr);
	},

	activeColumns() {
		return COLUMN_SETS[this.viewMode] || COLUMN_SETS.simple;
	},

	columnLabel(col) {
		const labels = {
			time: _('Time'),
			action: _('Action'),
			rule: _('Rule'),
			iface: _('Interface'),
			iface_in: _('IN'),
			iface_out: _('OUT'),
			dir: _('Dir'),
			proto: _('Proto'),
			src: _('Source'),
			dst: _('Destination'),
			sport: _('SPort'),
			dport: _('DPort'),
			flags: _('Flags'),
			len: _('Len'),
			flow: _('Flow'),
			message: _('Message')
		};

		return labels[col] || col;
	},

	setViewMode(mode) {
		if (VIEW_MODES.indexOf(mode) < 0 || mode === this.viewMode)
			return;

		this.viewMode = mode;
		this.expandedRowId = null;
		this.saveViewMode();
		this.updateDetailToggleUi();
		this.renderThead();
		this.updateHash(this.readFilters());
		this.renderRows(true);
	},

	toggleDetailView(ev) {
		if (ev && ev.preventDefault)
			ev.preventDefault();

		this.setViewMode(this.viewMode === 'simple' ? 'detailed' : 'simple');
	},

	updateDetailToggleUi() {
		const btn = document.getElementById('fwlive-detail-toggle');
		if (btn) {
			const detailed = this.viewMode === 'detailed';
			btn.textContent = detailed ? _('Hide Detail') : _('Show Detail');
			btn.setAttribute('aria-pressed', detailed ? 'true' : 'false');
		}

		const map = document.querySelector('.fwlive-map');
		if (map)
			map.setAttribute('data-view', this.viewMode);

		this.updateFilterPanelUi();
	},

	updateFilterPanelUi() {
		const details = document.getElementById('fwlive-more-filters');
		if (!details)
			return;

		if (this.viewMode === 'detailed') {
			details.open = true;
			return;
		}

		const filters = this.readFilters();
		const hasExtra = !!(filters.interface || filters.src || filters.dst
			|| filters.sport || filters.dport);
		if (hasExtra)
			details.open = true;
	},

	onRowClick(rowId, ev) {
		if (this.viewMode !== 'simple')
			return;

		if (ev && ev.target && ev.target.closest
			&& ev.target.closest('a.fwlive-filter-link'))
			return;

		this.expandedRowId = this.expandedRowId === rowId ? null : rowId;
		this.renderRows(true);
	},

	flowCell(row) {
		const parts = [];
		const pushAddr = (addr, port, addrField, portField) => {
			if (!addr && !port)
				return;

			if (addr)
				parts.push(this.addrFilterLink(addrField, addr));
			if (port) {
				if (addr)
					parts.push(':');
				parts.push(this.filterLink(portField, port, port));
			}
		};

		pushAddr(row.src, row.sport, 'src', 'sport');
		if (parts.length && (row.dst || row.dport))
			parts.push(E('span', { 'class': 'fwlive-flow-arrow' }, ' → '));
		pushAddr(row.dst, row.dport, 'dst', 'dport');

		if (!parts.length)
			return '—';

		return E('span', { 'class': 'fwlive-flow' }, parts);
	},

	buildColumnCell(col, row) {
		const msgDisplay = log.formatMessageDisplay(row.message, this.messageLayout);
		const actionCell = row.action && row.action !== 'unknown'
			? this.filterLink('action', row.action, log.formatActionLabel(row.action))
			: log.formatActionLabel(row.action);

		switch (col) {
		case 'time':
			return E('td', { 'class': 'fwlive-time' },
				this.viewMode === 'simple'
					? log.formatTimestampCompact(row.timestamp)
					: log.formatTimestampLocal(row.timestamp));
		case 'action':
			return E('td', { 'class': log.actionRowClass(row.action) }, actionCell);
		case 'rule':
			return E('td', { 'class': 'fwlive-rule' }, this.ruleAdminLink(row.rule_hint, row.rule_label));
		case 'iface':
			return E('td', { 'class': 'fwlive-iface' }, this.ifaceLink(row.interface_in));
		case 'iface_in':
			return E('td', { 'class': 'fwlive-iface' }, this.ifaceLink(row.interface_in));
		case 'iface_out':
			return E('td', { 'class': 'fwlive-iface' }, this.ifaceLink(row.interface_out));
		case 'dir':
			return E('td', { 'class': 'fwlive-dir' }, log.formatCell(row.direction));
		case 'proto':
			return E('td', { 'class': 'fwlive-proto' }, this.filterLink('proto', row.proto));
		case 'src':
			return E('td', { 'class': 'fwlive-addr' }, this.addrFilterLink('src', row.src));
		case 'sport':
			return E('td', { 'class': 'fwlive-port' }, this.filterLink('sport', row.sport));
		case 'dst':
			return E('td', { 'class': 'fwlive-addr' }, this.addrFilterLink('dst', row.dst));
		case 'dport':
			return E('td', { 'class': 'fwlive-port' }, this.filterLink('dport', row.dport));
		case 'flags':
			return E('td', { 'class': 'fwlive-flags' }, log.formatCell(row.flags));
		case 'len':
			return E('td', { 'class': 'fwlive-len' }, row.length != null ? String(row.length) : '');
		case 'flow':
			return E('td', { 'class': 'fwlive-flow-cell' }, this.flowCell(row));
		case 'message':
			return E('td', {
				'class': 'fwlive-message',
				'title': row.message || ''
			}, msgDisplay || '—');
		default:
			return E('td', {}, '');
		}
	},

	renderThead() {
		const table = document.getElementById('fwlive-table');
		if (!table)
			return;

		const tr = table.querySelector('thead tr');
		if (!tr)
			return;

		const cols = this.activeColumns();
		tr.innerHTML = '';

		for (let i = 0; i < cols.length; i++) {
			const col = cols[i];
			const thClass = col === 'message' ? 'fwlive-th-message' : '';
			tr.appendChild(E('th', { 'class': thClass }, this.columnLabel(col)));
		}
	},

	async loadRulesMap() {
		try {
			const res = await callFwliveRules();
			this.rulesMap = (res && res.rules) || {};
		} catch (e) {
			this.rulesMap = {};
		}
	},

	resolveRuleLabel(hint) {
		if (!hint)
			return '';

		if (this.rulesMap[hint])
			return this.rulesMap[hint];

		const slug = hint.toLowerCase();
		if (this.rulesMap[slug])
			return this.rulesMap[slug];

		return log.formatRuleLabel(hint);
	},

	enrichEntry(row) {
		row.rule_label = this.resolveRuleLabel(row.rule_hint);
		return row;
	},

	async fetchEntries() {
		if (!this.sessionSeen)
			this.sessionSeen = new Set();

		const raw = await callFwlivePoll({ addresses: [ String(this.fetchLines) ] });
		const normalized = [];
		const seen = {};
		let pollNew = 0;

		for (let i = 0; i < raw.length; i++) {
			if (!log.isFirewallEvent(raw[i]))
				continue;

			const row = this.enrichEntry(log.normalizeEntry(raw[i]));
			if (seen[row.id])
				continue;
			seen[row.id] = true;
			if (!this.sessionSeen.has(row.id)) {
				this.sessionSeen.add(row.id);
				this.sessionNewTotal++;
				pollNew++;
			}
			normalized.push(row);
		}

		this.lastPollNewEvents = pollNew;

		/* Oldest-first ring buffer; filteredRows() reverses for newest-first display. */
		this.entries = normalized.slice(-this.ingestCap());
		this.trimEntriesToLiveCap();
	},

	ingestCap() {
		return this.paused ? FETCH_LINES_MAX : this.rowLimit;
	},

	trimEntriesToLiveCap() {
		if (this.paused || this.entries.length <= this.rowLimit)
			return;

		this.entries = this.entries.slice(-this.rowLimit);
	},

	statusSuffix() {
		const bits = [];
		if (this.paused) {
			const since = this.sessionNewTotal - (this.sessionAtPause || 0);
			if (since > 0)
				bits.push(_('+%d since pause').format(since));
		}

		const cap = this.ingestCap();
		if (this.entries.length >= cap && cap > 0)
			bits.push(_('buffer full'));
		if (this.floodSuppressed)
			bits.push(_('render paused (high rate)'));
		if (!this.paused && !this.followLive)
			bits.push(_('scroll frozen — scroll to top to follow live'));
		return bits.length ? ' — ' + bits.join(', ') : '';
	},

	refillRenderBucket() {
		const now = Date.now();
		if (!this.renderBucketMs)
			this.renderBucketMs = now;

		const elapsed = now - this.renderBucketMs;
		this.renderBucketMs = now;
		this.renderBucket = Math.min(
			RENDER_CAP_PER_SEC,
			this.renderBucket + (elapsed * RENDER_CAP_PER_SEC / 1000)
		);
	},

	consumeRenderBudget(cost) {
		if (cost <= 0) {
			this.floodSuppressed = false;
			return true;
		}

		this.refillRenderBucket();
		if (cost <= this.renderBucket) {
			this.renderBucket -= cost;
			this.floodSuppressed = false;
			return true;
		}

		this.floodSuppressed = true;
		return false;
	},

	/** Charge by new log events per poll, not full table size (avoids false throttle at high limits). */
	renderBudgetCost(rows) {
		const count = rows ? rows.length : 0;
		const headId = count ? rows[0].id : '';

		if (!count && !this.lastRenderedRowCount)
			return 0;

		if (count === this.lastRenderedRowCount && headId === this.lastRenderedHeadId)
			return 0;

		return Math.max(1, this.lastPollNewEvents || 1);
	},

	updateFloodBanner() {
		const el = document.getElementById('fwlive-flood');
		if (!el)
			return;

		if (this.floodSuppressed) {
			el.style.display = 'block';
			el.textContent = _('High event rate — table refresh is throttled to protect the browser. The buffer still updates; refresh will resume automatically.');
		} else {
			el.style.display = 'none';
			el.textContent = '';
		}
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

		const suffix = this.statusSuffix();

		if (this.paused) {
			status.className = 'fwlive-status fwlive-status-paused';
			if (this.pauseBufferLoading) {
				status.textContent = _('Paused — loading ingest buffer…');
				return;
			}
			status.textContent = matchCount
				? _('Paused — %d ingested, %d/%d shown when live (%d match filters). Enable auto-refresh to update the table.%s').format(this.entries.length, Math.min(matchCount, this.rowLimit), this.rowLimit, matchCount, suffix)
				: _('Paused — %d ingested (%d shown when live). Enable auto-refresh to update the table.%s').format(this.entries.length, this.rowLimit, suffix);
			return;
		}

		status.className = 'fwlive-status';
		const stored = this.entries.length;
		const limit = this.rowLimit;
		const session = this.sessionNewTotal;
		if (matchCount) {
			let line = _('Showing %d matching — %d/%d stored (limit %d)').format(matchCount, stored, limit, limit);
			if (session > stored)
				line += _(', %d seen this session').format(session);
			line += _(' (newest first).');
			status.textContent = line + suffix;
		} else if (stored) {
			status.textContent = _('No rows match filters — %d/%d stored (limit %d).%s').format(stored, limit, limit, suffix);
		} else {
			status.textContent = '';
		}
	},

	readRowLimit() {
		try {
			const n = parseInt(localStorage.getItem('fwlive-row-limit'), 10);
			if (ROW_LIMIT_OPTIONS.indexOf(n) >= 0)
				return n;
		} catch (e) {
			/* private mode / no storage */
		}

		return DEFAULT_ROW_LIMIT;
	},

	saveRowLimit() {
		try {
			localStorage.setItem('fwlive-row-limit', String(this.rowLimit));
		} catch (e) {
			/* private mode / no storage */
		}
	},

	applyRowLimit(limit) {
		const n = ROW_LIMIT_OPTIONS.indexOf(limit) >= 0 ? limit : DEFAULT_ROW_LIMIT;
		this.rowLimit = n;
		this.maxHistory = n;
		this.fetchLines = FETCH_LINES_MAX;
		this.visibleRows = n;
		if (!this.paused && this.entries.length > n)
			this.entries = this.entries.slice(-n);
	},

	updateStreamControlsUi() {
		const cb = document.getElementById('fwlive-autorefresh');
		const sel = document.getElementById('fwlive-limit');
		const hostCb = document.getElementById('fwlive-show-hostnames');
		if (cb)
			cb.checked = !this.paused;
		if (sel)
			sel.value = String(this.rowLimit);
		if (hostCb)
			hostCb.checked = !!this.showHostnames;
	},

	onShowHostnamesChange(ev) {
		this.showHostnames = !!(ev && ev.target && ev.target.checked);
		this.saveShowHostnames();

		if (this.showHostnames)
			this.resolveHostnamesForEntries(this.filteredRows());
		else
			this.renderRows(true);
	},

	onAutoRefreshChange(ev) {
		const wasPaused = this.paused;
		this.paused = !(ev && ev.target && ev.target.checked);
		this.updateStreamControlsUi();

		if (!wasPaused && this.paused) {
			this.sessionAtPause = this.sessionNewTotal;
			this.pauseBufferLoading = true;
			this.updateStatus();
			this.fetchEntries().then(() => {
				this.pauseBufferLoading = false;
				this.updateStatus();
			});
			return;
		}

		if (wasPaused && !this.paused)
			this.followLive = true;

		if (wasPaused && !this.paused) {
			this.trimEntriesToLiveCap();
			this.fetchEntries().then(() => this.renderRows(true));
			return;
		}

		if (this.paused)
			this.updateStatus();
		else
			this.renderRows(true);
	},

	onRowLimitChange(ev) {
		const n = parseInt(ev && ev.target ? ev.target.value : '', 10);
		if (!isFinite(n) || ROW_LIMIT_OPTIONS.indexOf(n) < 0)
			return;

		this.applyRowLimit(n);
		this.saveRowLimit();
		this.updateHash(this.readFilters());
		if (!this.paused)
			this.renderRows(true);
		else
			this.updateStatus();
		this.fetchEntries().then(() => {
			if (this.paused)
				this.updateStatus();
			else
				this.renderRows(true);
		});
	},

	limitSelectOptions() {
		const opts = [];
		for (let i = 0; i < ROW_LIMIT_OPTIONS.length; i++) {
			const n = ROW_LIMIT_OPTIONS[i];
			opts.push(E('option', { 'value': String(n) }, String(n)));
		}
		return opts;
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

	addrFilterLink(field, ip) {
		if (!ip)
			return log.formatCell(ip);

		const name = this.showHostnames && this.hostnameCache
			? this.hostnameCache.get(ip) : null;
		const display = name || ip;
		const title = name ? ip : _('Filter by %s').format(field);

		return E('a', {
			'href': '#',
			'class': 'fwlive-filter-link',
			'title': title,
			'click': this.filterClick.bind(this, field, ip)
		}, display);
	},

	collectIpsFromEntries(entries) {
		const ips = new Set();

		for (let i = 0; i < entries.length; i++) {
			const r = entries[i];
			if (r.src && this.isLikelyIp(r.src))
				ips.add(r.src);
			if (r.dst && this.isLikelyIp(r.dst))
				ips.add(r.dst);
		}

		return Array.from(ips);
	},

	async resolveHostnamesForEntries(entries) {
		if (!this.showHostnames || this.resolveInFlight)
			return;

		if (!this.hostnameCache)
			this.hostnameCache = new Map();
		if (!this.hostnameFailed)
			this.hostnameFailed = new Set();

		const ips = this.collectIpsFromEntries(entries);
		const need = [];

		for (let i = 0; i < ips.length && need.length < 32; i++) {
			const ip = ips[i];
			if (!this.hostnameCache.has(ip) && !this.hostnameFailed.has(ip))
				need.push(ip);
		}

		if (!need.length)
			return;

		this.resolveInFlight = true;

		try {
			const res = await callFwliveResolve({ addresses: need });
			const names = (res && res.names) || {};
			let updated = false;

			for (let i = 0; i < need.length; i++) {
				const ip = need[i];
				if (names[ip]) {
					this.hostnameCache.set(ip, names[ip]);
					updated = true;
				} else {
					this.hostnameFailed.add(ip);
				}
			}

			if (updated)
				this.renderRows(true);
		} catch (e) {
			/* resolve unavailable — show IPs */
		} finally {
			this.resolveInFlight = false;
		}
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
				E('span', { 'class': 'fwlive-chip-label' }, log.formatFilterChipLabel(spec.label, val)),
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

	readMessageLayout() {
		try {
			return localStorage.getItem('fwlive-msg-layout') === 'oneline' ? 'oneline' : 'wrap';
		} catch (e) {
			return 'wrap';
		}
	},

	saveMessageLayout() {
		try {
			localStorage.setItem('fwlive-msg-layout', this.messageLayout);
		} catch (e) {
			/* private mode / no storage */
		}
	},

	updateMessageLayoutUi() {
		const scroll = document.getElementById('fwlive-scroll');
		const btn = document.getElementById('fwlive-msg-layout');
		if (scroll) {
			scroll.classList.toggle('fwlive-msg-oneline', this.messageLayout === 'oneline');
			scroll.classList.toggle('fwlive-msg-wrap', this.messageLayout === 'wrap');
		}
		if (btn) {
			btn.textContent = this.messageLayout === 'oneline'
				? _('Message: one line')
				: _('Message: wrap');
		}
	},

	toggleMessageLayout() {
		this.messageLayout = this.messageLayout === 'oneline' ? 'wrap' : 'oneline';
		this.saveMessageLayout();
		this.updateMessageLayoutUi();
		if (this.paused)
			this.updateStatus();
		else
			this.renderRows(true);
	},

	renderRows(force) {
		const table = document.getElementById('fwlive-table');
		if (!table)
			return;

		const body = table.querySelector('tbody');
		const empty = document.getElementById('fwlive-empty');
		const scroll = document.getElementById('fwlive-scroll');
		this.updateHash(this.readFilters());

		const rows = this.filteredRows();
		const cost = force ? Math.max(1, rows.length) : this.renderBudgetCost(rows);

		if (!force && cost === 0) {
			this.floodSuppressed = false;
			this.updateFloodBanner();
			this.updateStatus(rows);
			return;
		}

		if (!force && !this.consumeRenderBudget(cost)) {
			this.updateFloodBanner();
			this.updateStatus(rows);
			return;
		}

		this.updateFloodBanner();

		const prevScroll = scroll ? scroll.scrollTop : 0;

		body.innerHTML = '';
		if (empty)
			empty.style.display = rows.length ? 'none' : 'block';
		this.updateStatus(rows);
		this.renderFilterChips();

		const cols = this.activeColumns();
		for (let i = 0; i < rows.length; i++) {
			const r = rows[i];
			const rowClass = [
				i % 2 ? 'fwlive-row-alt' : '',
				this.viewMode === 'simple' ? 'fwlive-row-clickable' : '',
				this.expandedRowId === r.id ? 'fwlive-row-expanded' : ''
			].filter(Boolean).join(' ');
			const cells = [];
			for (let c = 0; c < cols.length; c++)
				cells.push(this.buildColumnCell(cols[c], r));

			const tr = E('tr', {
				'class': rowClass,
				'click': this.viewMode === 'simple'
					? this.onRowClick.bind(this, r.id) : null
			}, cells);
			body.appendChild(tr);

			if (this.viewMode === 'simple' && this.expandedRowId === r.id) {
				body.appendChild(E('tr', { 'class': 'fwlive-msg-expand' }, [
					E('td', { 'colspan': String(cols.length) }, [
						E('div', { 'class': 'fwlive-msg-expand-label' }, _('Message')),
						E('pre', { 'class': 'fwlive-msg-expand-body' },
							log.formatMessageDisplay(r.message, 'wrap') || '—')
					])
				]));
			}
		}

		if (scroll) {
			if (!this.paused && this.followLive)
				scroll.scrollTop = 0;
			else
				scroll.scrollTop = prevScroll;
		}

		this.lastRenderedRowCount = rows.length;
		this.lastRenderedHeadId = rows.length ? rows[0].id : '';
	},

	onFilterInput() {
		if (this.paused) {
			this.renderFilterChips();
			this.updateStatus();
		} else {
			this.renderRows(true);
		}
	},

	onScrollArea(ev) {
		const scroll = ev && ev.target;
		if (!scroll || this.paused)
			return;

		this.followLive = scroll.scrollTop < 8;
		this.updateStatus();
	},

	attachHandlers() {
		const scroll = document.getElementById('fwlive-scroll');
		if (scroll)
			scroll.addEventListener('scroll', this.onScrollArea.bind(this));

		const ids = [ 'q', 'action', 'interface', 'proto', 'src', 'dst', 'sport', 'dport' ];
		for (let i = 0; i < ids.length; i++) {
			const el = document.getElementById('fwlive-' + ids[i]);
			if (!el)
				continue;
			el.addEventListener('input', this.onFilterInput.bind(this));
			if (el.tagName === 'SELECT')
				el.addEventListener('change', this.onFilterInput.bind(this));
		}

		const refreshCb = document.getElementById('fwlive-autorefresh');
		if (refreshCb)
			refreshCb.addEventListener('change', this.onAutoRefreshChange.bind(this));

		const limitSel = document.getElementById('fwlive-limit');
		if (limitSel)
			limitSel.addEventListener('change', this.onRowLimitChange.bind(this));

		const msgBtn = document.getElementById('fwlive-msg-layout');
		if (msgBtn)
			msgBtn.addEventListener('click', this.toggleMessageLayout.bind(this));

		const hostCb = document.getElementById('fwlive-show-hostnames');
		if (hostCb)
			hostCb.addEventListener('change', this.onShowHostnamesChange.bind(this));
	},

	async pollData() {
		await this.fetchEntries();
		if (this.paused)
			this.updateStatus();
		else
			this.renderRows(false);

		await this.resolveHostnamesForEntries(this.filteredRows());
	},

	load() {
		poll.add(this.pollData.bind(this), 1);
		return this.loadRulesMap().then(() => this.fetchEntries());
	},

	render() {
		return E('div', { 'class': 'cbi-map fwlive-map', 'data-view': 'simple' }, [
			E('style', {}, `
				.fwlive-map { max-width: none; width: 100%; }
				.fwlive-toolbar {
					display: flex;
					align-items: center;
					gap: 12px;
					margin-bottom: 10px;
					flex-wrap: wrap;
				}
				.fwlive-ctl {
					display: inline-flex;
					align-items: center;
					gap: 6px;
					font-size: 0.92em;
					white-space: nowrap;
				}
				#fwlive-limit { width: auto; min-width: 4.5em; }
				.fwlive-grid { display: grid; grid-template-columns: repeat(4, minmax(140px, 1fr)); gap: 8px; margin-bottom: 12px; }
				.fwlive-status { margin: 0; color: #666; font-size: 0.92em; flex: 1; min-width: 200px; }
				.fwlive-status-paused { color: #a65e00; font-weight: 600; }
				.fwlive-scroll {
					max-height: min(78vh, 800px);
					overflow: auto;
					border: 1px solid #ddd;
					border-radius: 3px;
					background: #fff;
					width: 100%;
				}
				#fwlive-table { margin: 0; width: 100%; table-layout: auto; border-collapse: collapse; }
				.fwlive-scroll.fwlive-msg-oneline #fwlive-table {
					width: max-content;
					min-width: 100%;
				}
				.fwlive-scroll.fwlive-msg-oneline tbody td { vertical-align: middle; }
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
					font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
					font-size: 0.85em;
					color: #444;
				}
				.fwlive-scroll.fwlive-msg-wrap .fwlive-message {
					min-width: 16em;
					max-width: none;
					white-space: normal;
					word-break: break-word;
				}
				.fwlive-scroll.fwlive-msg-oneline .fwlive-message {
					white-space: nowrap;
					max-width: none;
					min-width: 32em;
				}
				#fwlive-table th.fwlive-th-message,
				.fwlive-scroll.fwlive-msg-oneline .fwlive-message {
					width: 99%;
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
				.fwlive-flood {
					display: none;
					margin: 0 0 10px;
					padding: 8px 12px;
					background: #fff8e6;
					border: 1px solid #e6c200;
					border-radius: 3px;
					color: #664d00;
					font-size: 0.92em;
				}
				.fwlive-map[data-view="simple"] #fwlive-msg-layout { display: none; }
				.fwlive-help {
					margin: 10px 0 0;
					font-size: 0.92em;
					color: #555;
				}
				.fwlive-help ul { margin: 6px 0 0 1.2em; padding: 0; }
				.fwlive-help li { margin: 4px 0; }
				.fwlive-intro { margin: 0 0 12px; color: #444; }
				.fwlive-filter-panel { margin-bottom: 12px; }
				.fwlive-map[data-view="simple"] .fwlive-grid-core {
					display: grid;
					grid-template-columns: repeat(3, minmax(140px, 1fr));
					gap: 8px;
				}
				.fwlive-map[data-view="simple"] .fwlive-more-filters { margin-top: 8px; }
				.fwlive-map[data-view="simple"] .fwlive-grid-extra {
					display: grid;
					grid-template-columns: repeat(4, minmax(140px, 1fr));
					gap: 8px;
					margin-top: 8px;
				}
				.fwlive-map[data-view="detailed"] .fwlive-more-filters > summary { display: none; }
				.fwlive-map[data-view="detailed"] .fwlive-filter-panel {
					display: grid;
					grid-template-columns: repeat(4, minmax(140px, 1fr));
					gap: 8px;
				}
				.fwlive-map[data-view="detailed"] .fwlive-grid-core,
				.fwlive-map[data-view="detailed"] .fwlive-grid-extra,
				.fwlive-map[data-view="detailed"] .fwlive-more-filters { display: contents; }
				.fwlive-row-clickable { cursor: pointer; }
				.fwlive-row-expanded td { border-bottom-color: transparent; }
				.fwlive-msg-expand td {
					background: #f5f8fc;
					padding: 8px 12px 10px;
					border-bottom: 1px solid #dde4ee;
				}
				.fwlive-msg-expand-label {
					font-size: 0.82em;
					color: #666;
					margin-bottom: 4px;
					font-weight: 600;
				}
				.fwlive-msg-expand-body {
					margin: 0;
					white-space: pre-wrap;
					word-break: break-word;
					font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
					font-size: 0.85em;
					color: #333;
				}
				.fwlive-flow-arrow { color: #888; }
				.fwlive-flow-cell { white-space: nowrap; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.9em; }
				.fwlive-map[data-view="simple"] .fwlive-action.fwlive-pass { color: #157815; }
				.fwlive-map[data-view="simple"] .fwlive-action.fwlive-deny { color: #cc0000; }
				.fwlive-iface-badge {
					border-radius: 10px;
					padding: 2px 8px;
				}
			`),
			E('h2', {}, _('Firewall Live View')),
			E('p', { 'class': 'fwlive-intro' }, _('Live firewall log table — refreshes every second. Shows traffic your firewall already logs; use filters or Show Detail when you need more.')),
			E('div', { 'class': 'fwlive-toolbar' }, [
				E('label', { 'class': 'fwlive-ctl' }, [
					E('input', {
						'id': 'fwlive-autorefresh',
						'type': 'checkbox',
						'checked': 'checked'
					}),
					_('Auto-refresh')
				]),
				E('label', { 'class': 'fwlive-ctl', 'for': 'fwlive-limit' }, _('Limit')),
				E('select', {
					'id': 'fwlive-limit',
					'class': 'cbi-input-select'
				}, this.limitSelectOptions()),
				E('label', { 'class': 'fwlive-ctl' }, [
					E('input', {
						'id': 'fwlive-show-hostnames',
						'type': 'checkbox'
					}),
					_('Show hostnames')
				]),
				E('button', {
					'id': 'fwlive-detail-toggle',
					'class': 'cbi-button',
					'type': 'button',
					'aria-pressed': 'false',
					'click': this.toggleDetailView.bind(this)
				}, _('Show Detail')),
				E('button', {
					'id': 'fwlive-msg-layout',
					'class': 'cbi-button',
					'type': 'button'
				}, _('Message: wrap')),
				E('span', { 'id': 'fwlive-status', 'class': 'fwlive-status' }, '')
			]),
			E('div', { 'id': 'fwlive-flood', 'class': 'fwlive-flood' }, ''),
			E('div', { 'id': 'fwlive-filter-panel', 'class': 'fwlive-filter-panel' }, [
				E('div', { 'class': 'fwlive-grid fwlive-grid-core' }, [
					E('input', { 'id': 'fwlive-q', 'class': 'cbi-input-text', 'placeholder': _('Quick search') }),
					E('select', { 'id': 'fwlive-action', 'class': 'cbi-input-select' }, [
						E('option', { 'value': '' }, _('Any action')),
						E('option', { 'value': 'pass' }, 'pass'),
						E('option', { 'value': 'block' }, 'block'),
						E('option', { 'value': 'drop' }, 'drop'),
						E('option', { 'value': 'reject' }, 'reject'),
						E('option', { 'value': 'unknown' }, 'unknown'),
						E('option', { 'value': '!pass' }, _('not pass')),
						E('option', { 'value': '!drop' }, _('not drop')),
						E('option', { 'value': '!block' }, _('not block')),
						E('option', { 'value': '!reject' }, _('not reject'))
					]),
					E('input', { 'id': 'fwlive-proto', 'class': 'cbi-input-text', 'placeholder': _('Protocol (prefix ! to exclude)') })
				]),
				E('details', { 'id': 'fwlive-more-filters', 'class': 'fwlive-more-filters' }, [
					E('summary', {}, _('More filters')),
					E('div', { 'class': 'fwlive-grid fwlive-grid-extra' }, [
						E('input', { 'id': 'fwlive-interface', 'class': 'cbi-input-text', 'placeholder': _('Interface (prefix ! to exclude)') }),
						E('input', { 'id': 'fwlive-src', 'class': 'cbi-input-text', 'placeholder': _('Source IP contains (! to exclude)') }),
						E('input', { 'id': 'fwlive-sport', 'class': 'cbi-input-text', 'placeholder': _('Source port (! to exclude)') }),
						E('input', { 'id': 'fwlive-dst', 'class': 'cbi-input-text', 'placeholder': _('Destination IP contains (! to exclude)') }),
						E('input', { 'id': 'fwlive-dport', 'class': 'cbi-input-text', 'placeholder': _('Destination port (! to exclude)') })
					])
				])
			]),
			E('div', { 'id': 'fwlive-chips', 'class': 'fwlive-chips' }, []),
			E('div', {
				'id': 'fwlive-empty',
				'class': 'fwlive-empty',
				'style': 'display:none'
			}, [
				E('p', {}, _('No firewall events yet. Stock configs log nothing until you turn logging on — enable zone logging on WAN (Network → Firewall) for inbound drops, or add log to the rule you are debugging.')),
				E('p', {}, [
					_('Quick test in System → Terminal: '),
					E('code', {}, 'nft insert rule inet fw4 input ip protocol icmp icmp type echo-request log prefix "fwlive-ping " accept'),
					_(' then ping the router. For WAN scan/drop traffic, set '),
					E('code', {}, "option log '1'"),
					_(' on the wan zone and reload the firewall.')
				])
			]),
			E('div', { 'id': 'fwlive-scroll', 'class': 'fwlive-scroll fwlive-msg-wrap' }, [
				E('table', { 'id': 'fwlive-table', 'class': 'table cbi-section-table' }, [
					E('thead', {}, E('tr', {}, [])),
					E('tbody', {}, [])
				])
			]),
			E('p', { 'class': 'cbi-value-description' }, _('Click a row for the full log line. Show Detail for all columns. Prefix ! in a filter to exclude. Ctrl+click a rule to open firewall settings.')),
			E('details', { 'id': 'fwlive-help', 'class': 'fwlive-help' }, [
				E('summary', {}, _('Help')),
				E('ul', {}, [
					E('li', {}, _('The table updates automatically — no setup needed when your firewall already logs traffic.')),
					E('li', {}, _('Click a row to see the full log line (Simple view).')),
					E('li', {}, _('Click an IP, action, or protocol to filter.')),
					E('li', {}, _('Use Show Detail for all columns (flags, length, raw message).'))
				])
			])
		]);
	},

	addFooter() {
		this.viewMode = this.readViewMode();
		this.messageLayout = this.readMessageLayout();
		this.showHostnames = this.readShowHostnames();
		this.hostnameCache = new Map();
		this.hostnameFailed = new Set();
		this.applyRowLimit(this.readRowLimit());
		this.applyHash();
		this.attachHandlers();
		this.updateMessageLayoutUi();
		this.updateStreamControlsUi();
		this.updateDetailToggleUi();
		this.renderThead();
		this.renderRows(true);
		if (this.showHostnames)
			this.resolveHostnamesForEntries(this.filteredRows());
	}
});
