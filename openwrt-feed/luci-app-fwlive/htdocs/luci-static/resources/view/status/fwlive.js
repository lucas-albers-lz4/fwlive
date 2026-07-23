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
	method: 'rules'
});

const callFwliveResolve = rpc.declare({
	object: 'fwlive',
	method: 'resolve',
	params: [ 'addresses' ],
	expect: { names: {} }
});

const callFwliveLoggingStatus = rpc.declare({
	object: 'fwlive',
	method: 'logging_status',
	expect: { '': {
		wan_zone: null,
		wan_log: false,
		wan_log_limit: null,
		nf_log_ipv4: false,
		nf_log_ipv6: false,
		ready: false,
		blockers: []
	} }
});

const callFwliveEnableLogging = rpc.declare({
	object: 'fwlive',
	method: 'enable_wan_logging',
	expect: { '': { ok: false, changed: false, wan_zone: null } }
});

const callFwliveDisableLogging = rpc.declare({
	object: 'fwlive',
	method: 'disable_wan_logging',
	expect: { '': { ok: false, changed: false, wan_zone: null } }
});

const ROW_LIMIT_OPTIONS = [ 25, 50, 100, 250, 500, 1000, 2000 ];
const DEFAULT_ROW_LIMIT = 100;
const FETCH_LINES_MAX = 2000;
const RENDER_CAP_PER_SEC = 250; // DOM budget: ~250 new/updated rows per second on typical LuCI routers
const VIEW_MODES = [ 'simple', 'detailed' ];
const COLUMN_SETS = {
	simple: [ 'action', 'time', 'iface', 'flow', 'proto', 'rule' ],
	detailed: [ 'time', 'action', 'rule', 'iface_in', 'iface_out', 'dir', 'proto', 'src', 'sport', 'dst', 'dport', 'flags', 'len', 'message' ]
};

/* FWLIVE_TINT_HELPERS_START */
var FWLIVE_TINT_PAINT_DELTA_MIN = 8;
var FWLIVE_TINT_PASS_HEX = '#46a546';
var FWLIVE_TINT_DENY_HEX = '#ca3c3c';

function fwliveParseCssRgbChannels(value) {
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

function fwliveCssColorPaintDelta(a, b) {
	const ca = fwliveParseCssRgbChannels(a);
	const cb = fwliveParseCssRgbChannels(b);
	/* Transparent vs opaque color is a real paint change (common off-state). */
	if (!ca && !cb)
		return 0;
	if (!ca && cb)
		return Math.abs(cb[0]) + Math.abs(cb[1]) + Math.abs(cb[2]);
	if (ca && !cb)
		return Math.abs(ca[0]) + Math.abs(ca[1]) + Math.abs(ca[2]);

	return Math.abs(ca[0] - cb[0]) + Math.abs(ca[1] - cb[1]) + Math.abs(ca[2] - cb[2]);
}

function fwliveTintShouldEngageFallback(opts) {
	const o = opts || {};
	const minDelta = (typeof o.minDelta === 'number') ? o.minDelta : FWLIVE_TINT_PAINT_DELTA_MIN;

	/* Visible paint is the success criterion; token/CSS.supports are only used when
	   paint cannot be measured (no delta sample yet). */
	if (typeof o.paintDelta === 'number')
		return o.paintDelta < minDelta;

	if (o.tokenResolved === false)
		return true;

	return false;
}
/* FWLIVE_TINT_HELPERS_END */

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
	rowTint: true,
	hostnameCache: null,
	hostnameFailed: null,
	resolveInFlight: false,
	lastRenderedRowCount: 0,
	lastRenderedHeadId: '',
	followLive: true,
	rulesMap: {},
	firewallBackend: 'nft',
	viewMode: 'simple',
	expandedRowId: null,
	loggingStatus: null,
	loggingBusy: false,
	loggingNotice: '',
	tintFallbackActive: false,
	tintProbeDone: false,

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
		const val = (id) => {
			const el = document.getElementById(id);
			return el ? (el.value || '') : '';
		};
		return {
			q: val('fwlive-q').trim(),
			action: val('fwlive-action'),
			interface: val('fwlive-interface'),
			proto: val('fwlive-proto'),
			src: val('fwlive-src').trim(),
			dst: val('fwlive-dst').trim(),
			sport: val('fwlive-sport').trim(),
			dport: val('fwlive-dport').trim()
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

	readRowTint() {
		try {
			const v = localStorage.getItem('fwlive-row-tint');
			if (v === null)
				return true;
			return v === '1';
		} catch (e) {
			return true;
		}
	},

	saveRowTint() {
		try {
			localStorage.setItem('fwlive-row-tint', this.rowTint ? '1' : '0');
		} catch (e) {
			/* private mode / no storage */
		}
	},

	actionRowTintClass(action) {
		const a = (action || '').toLowerCase();
		if (a === 'pass')
			return 'fwlive-row-pass';
		if (a === 'drop' || a === 'reject' || a === 'block')
			return 'fwlive-row-deny';
		return '';
	},

	applyTintFallback(map) {
		if (!map)
			return;

		map.style.setProperty('--fwlive-pass-color', FWLIVE_TINT_PASS_HEX);
		map.style.setProperty('--fwlive-deny-color', FWLIVE_TINT_DENY_HEX);
		map.setAttribute('data-tint-fallback', '1');
		this.tintFallbackActive = true;
		this.updateTintWarnUi();
	},

	clearTintFallback(map) {
		if (!map)
			return;

		map.style.removeProperty('--fwlive-pass-color');
		map.style.removeProperty('--fwlive-deny-color');
		map.removeAttribute('data-tint-fallback');
		this.tintFallbackActive = false;
		this.updateTintWarnUi();
	},

	updateTintWarnUi() {
		const el = document.getElementById('fwlive-tint-warn');
		if (!el)
			return;

		el.style.display = this.tintFallbackActive ? 'inline' : 'none';
	},

	probeRowTintPaint() {
		const map = document.querySelector('.fwlive-map');
		const body = document.querySelector('#fwlive-table tbody');
		if (!map || !body)
			return;

		/* Prefer a non-alt row — zebra --background-color-medium can look "tinted" when transparent. */
		let tr = body.querySelector('tr:not(.fwlive-row-alt)');
		if (!tr)
			tr = body.querySelector('tr');
		if (!tr)
			return;

		const td = tr.querySelector('td');
		if (!td || typeof getComputedStyle !== 'function')
			return;

		const hadPass = tr.classList.contains('fwlive-row-pass');
		const hadDeny = tr.classList.contains('fwlive-row-deny');
		const probeClass = hadDeny ? 'fwlive-row-deny' : 'fwlive-row-pass';

		tr.classList.remove('fwlive-row-pass', 'fwlive-row-deny');
		const offBg = getComputedStyle(td).backgroundColor;
		tr.classList.add(probeClass);
		const onBg = getComputedStyle(td).backgroundColor;

		tr.classList.remove('fwlive-row-pass', 'fwlive-row-deny');
		if (hadPass)
			tr.classList.add('fwlive-row-pass');
		if (hadDeny)
			tr.classList.add('fwlive-row-deny');

		const passToken = getComputedStyle(map).getPropertyValue('--fwlive-pass-color').trim();
		const paintDelta = fwliveCssColorPaintDelta(onBg, offBg);
		map.setAttribute('data-tint-probe-delta', String(paintDelta));
		map.setAttribute('data-tint-probe-on', onBg || '');
		map.setAttribute('data-tint-probe-off', offBg || '');
		const broken = fwliveTintShouldEngageFallback({
			paintDelta: paintDelta,
			tokenResolved: !!passToken,
			minDelta: FWLIVE_TINT_PAINT_DELTA_MIN
		});

		this.tintProbeDone = true;
		if (broken)
			this.applyTintFallback(map);
		else if (this.tintFallbackActive)
			this.clearTintFallback(map);
		else
			this.updateTintWarnUi();
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

	columnCellClass(col) {
		switch (col) {
		case 'time': return 'fwlive-time';
		case 'action': return 'fwlive-action';
		case 'rule': return 'fwlive-rule';
		case 'iface':
		case 'iface_in':
		case 'iface_out': return 'fwlive-iface';
		case 'dir': return 'fwlive-dir';
		case 'proto': return 'fwlive-proto';
		case 'src':
		case 'dst': return 'fwlive-addr';
		case 'sport':
		case 'dport': return 'fwlive-port';
		case 'flags': return 'fwlive-flags';
		case 'len': return 'fwlive-len';
		case 'flow': return 'fwlive-flow-cell';
		case 'message': return 'fwlive-message fwlive-th-message';
		default: return '';
		}
	},

	filterChipLabelNodes(field, val) {
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
			return E('td', { 'class': this.columnCellClass(col) },
				this.viewMode === 'simple'
					? log.formatTimestampCompact(row.timestamp)
					: log.formatTimestampLocal(row.timestamp));
		case 'action':
			return E('td', { 'class': log.actionRowClass(row.action) }, actionCell);
		case 'rule':
			return E('td', { 'class': this.columnCellClass(col) }, this.ruleAdminLink(row.rule_hint, row.rule_label));
		case 'iface':
			return E('td', { 'class': this.columnCellClass(col) }, this.ifaceLink(row.interface_in));
		case 'iface_in':
		case 'iface_out':
			return E('td', { 'class': this.columnCellClass(col) }, this.ifaceLink(
				col === 'iface_in' ? row.interface_in : row.interface_out));
		case 'dir':
			return E('td', { 'class': this.columnCellClass(col) }, log.formatCell(row.direction));
		case 'proto':
			return E('td', { 'class': this.columnCellClass(col) }, this.filterLink('proto', row.proto));
		case 'src':
			return E('td', { 'class': this.columnCellClass(col) }, this.addrFilterLink('src', row.src));
		case 'sport':
			return E('td', { 'class': this.columnCellClass(col) }, this.filterLink('sport', row.sport));
		case 'dst':
			return E('td', { 'class': this.columnCellClass(col) }, this.addrFilterLink('dst', row.dst));
		case 'dport':
			return E('td', { 'class': this.columnCellClass(col) }, this.filterLink('dport', row.dport));
		case 'flags':
			return E('td', { 'class': this.columnCellClass(col) }, log.formatCell(row.flags));
		case 'len':
			return E('td', { 'class': this.columnCellClass(col) }, row.length != null ? String(row.length) : '');
		case 'flow':
			return E('td', { 'class': this.columnCellClass(col) }, this.flowCell(row));
		case 'message':
			if (this.messageLayout === 'wrap') {
				return E('td', {
					'class': 'fwlive-message',
					'title': msgDisplay || ''
				}, E('div', { 'class': 'fwlive-message-wrap' }, msgDisplay || '—'));
			}
			return E('td', {
				'class': 'fwlive-message',
				'title': msgDisplay || ''
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
		let colgroup = table.querySelector('colgroup');

		if (!colgroup) {
			colgroup = E('colgroup', {});
			table.insertBefore(colgroup, table.firstChild);
		}

		colgroup.innerHTML = '';
		tr.innerHTML = '';

		for (let i = 0; i < cols.length; i++) {
			const col = cols[i];
			colgroup.appendChild(E('col', { 'class': 'fwlive-col fwlive-col-' + col.replace(/_/g, '-') }));
			tr.appendChild(E('th', { 'class': this.columnCellClass(col) }, this.columnLabel(col)));
		}
	},

	async loadRulesMap() {
		try {
			const res = await callFwliveRules();
			this.rulesMap = (res && res.rules) || {};
			this.firewallBackend = (res && res.backend) || 'nft';
		} catch (e) {
			this.rulesMap = {};
			this.firewallBackend = 'nft';
		}
		this.updateBackendUi();
	},

	backendDisplayLabel() {
		if (this.firewallBackend === 'iptables')
			return _('using iptables');
		if (this.firewallBackend === 'nft')
			return _('using fw4');
		return '';
	},

	updateBackendUi() {
		const map = document.querySelector('.fwlive-map');
		if (map)
			map.setAttribute('data-backend', this.firewallBackend || 'unknown');

		const label = document.getElementById('fwlive-backend');
		if (label)
			label.textContent = this.backendDisplayLabel();

		this.updateEmptyStateUi();
	},

	firewallZonesPath() {
		return 'admin/network/firewall/zones';
	},

	firewallZonesUrl() {
		return this.luciUrl(this.firewallZonesPath());
	},

	firewallZonesLink(label) {
		return E('a', {
			'href': this.firewallZonesUrl(),
			'class': 'fwlive-filter-link'
		}, label || _('Network → Firewall'));
	},

	loggingHasBlocker(code) {
		const blockers = (this.loggingStatus && this.loggingStatus.blockers) || [];
		return blockers.indexOf(code) >= 0;
	},

	loggingBlockerMessage() {
		if (this.loggingHasBlocker('no_wan_zone'))
			return 'no_wan_zone';

		if (this.loggingHasBlocker('nf_log_ipv4_missing') ||
		    this.loggingHasBlocker('nf_log_ipv6_missing'))
			return 'nf_log_missing';

		return '';
	},

	manualLoggingTestNodes() {
		if (this.firewallBackend === 'iptables') {
			return E('li', {}, [
				_('Manual test (System → Terminal): '),
				E('code', {}, 'iptables -I INPUT -p icmp --icmp-type echo-request -j LOG --log-prefix "fwlive-ping: "'),
				_(' then ping the router.')
			]);
		}

		return E('li', {}, [
			_('Manual test (System → Terminal): '),
			E('code', {}, 'nft insert rule inet fw4 input ip protocol icmp icmp type echo-request log prefix "fwlive-ping " accept'),
			_(' then ping the router.')
		]);
	},

	async loadLoggingStatus() {
		try {
			this.loggingStatus = await callFwliveLoggingStatus();
		} catch (e) {
			this.loggingStatus = null;
		}
		this.updateLoggingToolbarUi();
		this.updateEmptyStateUi();
	},

	async handleEnableLogging() {
		if (this.loggingBusy)
			return;

		this.loggingBusy = true;
		this.loggingNotice = '';
		this.updateEmptyStateUi();
		this.updateLoggingToolbarUi();

		try {
			const res = await callFwliveEnableLogging();
			if (!res || !res.ok) {
				if (res && res.error === 'nf_log_missing')
					this.loggingNotice = _('Cannot enable logging until kernel log modules are installed.');
				else
					this.loggingNotice = _('Could not enable logging.');
				await this.loadLoggingStatus();
				return;
			}

			if (res.changed)
				this.loggingNotice = _('WAN logging enabled. Blocked inbound traffic should appear shortly.');
			else
				this.loggingNotice = _('WAN logging is already enabled.');

			await this.loadLoggingStatus();
		} catch (e) {
			this.loggingNotice = _('Administrator access is required to enable logging.');
			await this.loadLoggingStatus();
		} finally {
			this.loggingBusy = false;
			this.updateEmptyStateUi();
			this.updateLoggingToolbarUi();
		}
	},

	async handleDisableLogging() {
		if (this.loggingBusy)
			return;

		this.loggingBusy = true;
		this.loggingNotice = '';
		this.updateLoggingToolbarUi();

		try {
			const res = await callFwliveDisableLogging();
			if (!res || !res.ok) {
				this.loggingNotice = _('Could not disable logging.');
				await this.loadLoggingStatus();
				return;
			}

			if (res.changed)
				this.loggingNotice = _('WAN logging disabled.');
			await this.loadLoggingStatus();
		} catch (e) {
			this.loggingNotice = _('Administrator access is required to disable logging.');
			await this.loadLoggingStatus();
		} finally {
			this.loggingBusy = false;
			this.updateEmptyStateUi();
			this.updateLoggingToolbarUi();
		}
	},

	updateLoggingToolbarUi() {
		const bar = document.getElementById('fwlive-logging-bar');
		if (!bar)
			return;

		bar.innerHTML = '';
		const st = this.loggingStatus;
		if (!st) {
			bar.style.display = 'none';
			return;
		}

		if (!st.wan_log && this.entries.length === 0) {
			bar.style.display = 'none';
			return;
		}

		bar.style.display = 'flex';
		const blocker = this.loggingBlockerMessage();
		if (blocker === 'no_wan_zone') {
			bar.appendChild(E('span', { 'class': 'fwlive-logging-status' },
				_('WAN logging unavailable: no WAN zone')));
			bar.appendChild(this.firewallZonesLink());
			return;
		}

		if (blocker === 'nf_log_missing') {
			bar.appendChild(E('span', { 'class': 'fwlive-logging-status' },
				_('WAN logging unavailable: missing kernel log modules')));
			return;
		}

		const limit = st.wan_log_limit || _('default 10/minute');
		if (st.wan_log) {
			bar.appendChild(E('span', { 'class': 'fwlive-logging-status' }, [
				_('WAN logging on ('),
				E('a', {
					'href': '#fwlive-help',
					'class': 'fwlive-filter-link',
					'title': _('This is the firewall zone log_limit. fwlive only displays events after fw3/fw4 applies this rate cap.'),
					'click': function(ev) {
						const help = document.getElementById('fwlive-help');
						if (ev && ev.preventDefault)
							ev.preventDefault();
						if (help) {
							help.open = true;
							help.scrollIntoView({ block: 'nearest' });
						}
					}
				}, limit),
				_(')')
			]));
			bar.appendChild(E('button', {
				'class': 'cbi-button cbi-button-action',
				'type': 'button',
				'disabled': this.loggingBusy ? '' : null,
				'click': this.handleDisableLogging.bind(this)
			}, this.loggingBusy ? _('Disabling…') : _('Disable logging')));
			return;
		}

		bar.appendChild(E('span', { 'class': 'fwlive-logging-status' },
			_('WAN logging off')));
		bar.appendChild(E('button', {
			'class': 'cbi-button cbi-button-action',
			'type': 'button',
			'disabled': this.loggingBusy ? '' : null,
			'click': this.handleEnableLogging.bind(this)
		}, this.loggingBusy ? _('Enabling…') : _('Enable logging')));
	},

	buildEmptyStateNodes() {
		const nodes = [];
		const st = this.loggingStatus;
		const blocker = this.loggingBlockerMessage();

		if (this.loggingNotice) {
			nodes.push(E('p', { 'class': 'fwlive-logging-notice' }, [
				this.loggingNotice,
				' ',
				this.firewallZonesLink()
			]));
		}

		if (blocker === 'no_wan_zone') {
			nodes.push(E('p', {}, [
				_('No WAN firewall zone found in /etc/config/firewall. Configure zones under '),
				this.firewallZonesLink()
			]));
			return nodes;
		}

		if (blocker === 'nf_log_missing') {
			nodes.push(E('p', {}, _('Kernel netfilter log modules are missing. Install kmod-nf-log-ipv4 and kmod-nf-log-ipv6 (or kmod-nf-log / kmod-nf-log6), then reload the firewall.')));
			nodes.push(E('p', {}, [
				E('code', {}, 'opkg update && opkg install kmod-nf-log-ipv4 kmod-nf-log-ipv6')
			]));
			return nodes;
		}

		if (st && st.wan_log) {
			nodes.push(E('p', {}, _('Logging is enabled on WAN. Waiting for firewall events — blocked inbound traffic appears here (not normal LAN browsing).')));
			nodes.push(E('p', {}, this.firewallZonesLink(_('Open firewall zone settings'))));
			return nodes;
		}

		nodes.push(E('p', {}, _('No firewall events yet. OpenWrt does not log firewall traffic until you turn it on.')));
		nodes.push(E('p', {}, _('Enable logging to record blocked inbound traffic on WAN (rate-limited). Normal LAN browsing is not logged.')));
		nodes.push(E('p', {}, [
			E('button', {
				'class': 'cbi-button cbi-button-action',
				'type': 'button',
				'disabled': this.loggingBusy ? '' : null,
				'click': this.handleEnableLogging.bind(this)
			}, this.loggingBusy ? _('Enabling…') : _('Enable logging')),
			' ',
			this.firewallZonesLink()
		]));
		return nodes;
	},

	updateEmptyStateUi() {
		const empty = document.getElementById('fwlive-empty');
		if (!empty)
			return;

		const visible = empty.style.display !== 'none';
		const nodes = this.buildEmptyStateNodes();
		empty.innerHTML = '';
		for (let i = 0; i < nodes.length; i++)
			empty.appendChild(nodes[i]);
		if (visible)
			empty.style.display = 'block';
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

		let raw;
		try {
			raw = await callFwlivePoll({ addresses: [ String(this.fetchLines) ] });
		} catch (e) {
			return;
		}
		if (!Array.isArray(raw))
			return;

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
		if (this.paused)
			this.mergeEntries(normalized);
		else
			this.entries = normalized.slice(-this.ingestCap());
		this.trimEntriesToLiveCap();
	},

	mergeEntries(normalized) {
		if (!normalized.length)
			return;

		const byId = {};
		for (let i = 0; i < this.entries.length; i++)
			byId[this.entries[i].id] = this.entries[i];
		for (let i = 0; i < normalized.length; i++)
			byId[normalized[i].id] = normalized[i];

		const merged = Object.keys(byId).map((id) => byId[id]);
		merged.sort((a, b) => {
			const ta = a.timestamp || 0;
			const tb = b.timestamp || 0;
			if (ta !== tb)
				return ta - tb;
			return (a.log_id || 0) - (b.log_id || 0);
		});
		this.entries = merged.slice(-this.ingestCap());
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
			if (this.pauseBufferLoading)
				bits.push(_('loading buffer'));
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

	pausedStatusText(matchCount) {
		const ingested = this.entries.length;
		const since = this.sessionNewTotal - (this.sessionAtPause || 0);
		const limit = this.rowLimit;
		const suffix = this.statusSuffix();

		if (this.pauseBufferLoading && ingested === 0)
			return _('Paused — loading ingest buffer…');

		if (matchCount) {
			if (since > 0)
				return _('Paused — %d ingested (+%d since pause), %d/%d shown when live (%d match filters). Enable auto-refresh to update the table.%s')
					.format(ingested, since, Math.min(matchCount, limit), limit, matchCount, suffix);
			return _('Paused — %d ingested, %d/%d shown when live (%d match filters). Enable auto-refresh to update the table.%s')
				.format(ingested, Math.min(matchCount, limit), limit, matchCount, suffix);
		}

		if (since > 0)
			return _('Paused — %d ingested (+%d since pause) (%d shown when live). Enable auto-refresh to update the table.%s')
				.format(ingested, since, limit, suffix);

		return _('Paused — %d ingested (%d shown when live). Enable auto-refresh to update the table.%s')
			.format(ingested, limit, suffix);
	},

	updateStatus(rows) {
		const status = document.getElementById('fwlive-status');
		if (!status)
			return;

		const matchCount = rows ? rows.length : this.filteredRows().length;
		const suffix = this.statusSuffix();

		if (this.paused) {
			status.className = 'fwlive-status fwlive-status-paused';
			try {
				status.textContent = this.pausedStatusText(matchCount);
			} catch (e) {
				status.textContent = 'Paused — ' + this.entries.length + ' ingested. Enable auto-refresh to update the table.';
			}
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
		const tintCb = document.getElementById('fwlive-row-tint');
		if (cb)
			cb.checked = !this.paused;
		if (sel)
			sel.value = String(this.rowLimit);
		if (hostCb)
			hostCb.checked = !!this.showHostnames;
		if (tintCb)
			tintCb.checked = !!this.rowTint;
	},

	onShowHostnamesChange(ev) {
		this.showHostnames = !!(ev && ev.target && ev.target.checked);
		this.saveShowHostnames();

		if (this.showHostnames)
			this.resolveHostnamesForEntries(this.filteredRows());
		else
			this.renderRows(true);
	},

	onRowTintChange(ev) {
		this.rowTint = !!(ev && ev.target && ev.target.checked);
		this.saveRowTint();
		this.tintProbeDone = false;
		this.renderRows(true);
	},

	onAutoRefreshChange(ev) {
		const wasPaused = this.paused;
		this.paused = !(ev && ev.target && ev.target.checked);
		this.updateStreamControlsUi();

		if (!wasPaused && this.paused) {
			this.sessionAtPause = this.sessionNewTotal;
			this.updateStatus();
			this.pauseBufferLoading = true;
			this.updateStatus();
			this.fetchEntries()
				.catch(function() {})
				.finally(function() {
					this.pauseBufferLoading = false;
					this.updateStatus();
				}.bind(this));
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

		this.setFilterFieldValue(field, value);
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

		if (this.firewallBackend === 'iptables')
			return 'admin/status/iptables';

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

	setFilterFieldValue(field, value) {
		const el = document.getElementById('fwlive-' + field);
		if (!el)
			return false;

		el.value = value;
		if (el.tagName === 'SELECT')
			el.dispatchEvent(new Event('change', { bubbles: true }));

		return true;
	},

	clearFilter(field, ev) {
		if (ev && ev.preventDefault)
			ev.preventDefault();

		this.setFilterFieldValue(field, '');
		this.onFilterInput();
	},

	invertFilter(field, ev) {
		if (ev) {
			ev.preventDefault();
			ev.stopPropagation();
		}

		const el = document.getElementById('fwlive-' + field);
		if (!el || !el.value)
			return;

		this.setFilterFieldValue(field, log.toggleFilterNegation(el.value));
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

			const parsed = log.parseFilterValue(val);
			const negated = parsed.negate;

			chips.push(E('span', {
				'class': 'fwlive-chip' + (negated ? ' fwlive-chip-negated' : '')
			}, [
				E('span', { 'class': 'fwlive-chip-label' }, this.filterChipLabelNodes(spec.label, val)),
				E('span', {
					'class': 'fwlive-chip-invert-wrap',
					'data-tip': negated ? _('Include instead') : _('Exclude instead')
				}, [
					E('button', {
						'type': 'button',
						'class': 'fwlive-chip-invert',
						'click': this.invertFilter.bind(this, spec.key)
					}, '≠')
				]),
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
			/* add/remove — classList.toggle(name, force) is unsupported on some 21.02-era browsers */
			if (this.messageLayout === 'oneline') {
				scroll.classList.add('fwlive-msg-oneline');
				scroll.classList.remove('fwlive-msg-wrap');
			} else {
				scroll.classList.add('fwlive-msg-wrap');
				scroll.classList.remove('fwlive-msg-oneline');
			}
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
		this.updateLoggingToolbarUi();

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
				this.expandedRowId === r.id ? 'fwlive-row-expanded' : '',
				this.rowTint ? this.actionRowTintClass(r.action) : ''
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

		if (rows.length && this.rowTint && !this.tintProbeDone) {
			const runProbe = () => {
				if (!this.tintProbeDone)
					this.probeRowTintPaint();
			};
			if (typeof requestAnimationFrame === 'function')
				requestAnimationFrame(() => requestAnimationFrame(runProbe));
			else
				setTimeout(runProbe, 0);
		} else if (!this.rowTint && this.tintFallbackActive) {
			this.clearTintFallback(document.querySelector('.fwlive-map'));
			this.tintProbeDone = false;
		}
	},

	onFilterInput() {
		this.renderRows(true);
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

		const hostCb = document.getElementById('fwlive-show-hostnames');
		if (hostCb)
			hostCb.addEventListener('change', this.onShowHostnamesChange.bind(this));

		const tintCb = document.getElementById('fwlive-row-tint');
		if (tintCb)
			tintCb.addEventListener('change', this.onRowTintChange.bind(this));
	},

	async pollData() {
		try {
			await this.fetchEntries();
		} catch (e) {
			/* keep existing buffer on poll errors */
		}

		if (this.paused)
			this.updateStatus();
		else
			this.renderRows(false);

		try {
			await this.resolveHostnamesForEntries(this.filteredRows());
		} catch (e) {
			/* resolve unavailable — show IPs */
		}
	},

	load() {
		poll.add(this.pollData.bind(this), 1);
		return Promise.all([
			this.loadRulesMap(),
			this.loadLoggingStatus()
		]).then(() => this.fetchEntries());
	},

	render() {
		return E('div', { 'class': 'cbi-map fwlive-map', 'data-view': 'simple' }, [
			E('style', {}, `
				.fwlive-map {
					max-width: none;
					width: 100%;
					--fwlive-pass-color: var(--success-color-high, var(--success-color, #46a546));
					--fwlive-deny-color: var(--error-color-high, var(--error-color, #ca3c3c));
					--fwlive-bg-medium: var(--background-color-medium, var(--white-color-low, #f9f9f9));
				}
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
				.fwlive-status { margin: 0; color: var(--text-color-medium); font-size: 0.92em; flex: 1; min-width: 200px; }
				.fwlive-status-paused { color: var(--warn-color-high); font-weight: 600; }
				.fwlive-scroll {
					max-height: min(78vh, 800px);
					overflow: auto;
					border: 1px solid var(--border-color-medium);
					border-radius: 3px;
					background: var(--background-color-high);
					width: 100%;
					scrollbar-gutter: stable;
				}
				#fwlive-table { margin: 0; width: 100%; table-layout: auto; border-collapse: collapse; }
				.fwlive-map[data-view="simple"] #fwlive-table { table-layout: fixed; width: 100%; }
				.fwlive-map[data-view="simple"] col.fwlive-col-action { width: 5rem; }
				.fwlive-map[data-view="simple"] col.fwlive-col-time { width: 5rem; }
				.fwlive-map[data-view="simple"] col.fwlive-col-iface { width: 5.5rem; }
				.fwlive-map[data-view="simple"] col.fwlive-col-proto { width: 4rem; }
				.fwlive-map[data-view="simple"] col.fwlive-col-rule { width: 12rem; }
				.fwlive-map[data-view="detailed"] .fwlive-scroll #fwlive-table {
					width: max-content;
					min-width: 100%;
				}
				.fwlive-map[data-view="detailed"] col.fwlive-col-time { width: 11rem; }
				.fwlive-map[data-view="detailed"] col.fwlive-col-action { width: 4.5rem; }
				.fwlive-map[data-view="detailed"] col.fwlive-col-rule { width: 8rem; }
				.fwlive-map[data-view="detailed"] col.fwlive-col-iface-in,
				.fwlive-map[data-view="detailed"] col.fwlive-col-iface-out { width: 3.5rem; }
				.fwlive-map[data-view="detailed"] col.fwlive-col-dir { width: 3rem; }
				.fwlive-map[data-view="detailed"] col.fwlive-col-proto { width: 3.25rem; }
				.fwlive-map[data-view="detailed"] col.fwlive-col-src,
				.fwlive-map[data-view="detailed"] col.fwlive-col-dst { width: 9rem; }
				.fwlive-map[data-view="detailed"] col.fwlive-col-sport,
				.fwlive-map[data-view="detailed"] col.fwlive-col-dport { width: 3.75rem; }
				.fwlive-map[data-view="detailed"] col.fwlive-col-flags { width: 5rem; }
				.fwlive-map[data-view="detailed"] col.fwlive-col-len { width: 3.25rem; }
				.fwlive-scroll.fwlive-msg-oneline #fwlive-table {
					width: max-content;
					min-width: 100%;
				}
				.fwlive-scroll.fwlive-msg-oneline tbody td { vertical-align: middle; }
				#fwlive-table thead th {
					position: sticky;
					top: 0;
					z-index: 2;
					background: var(--background-color-low);
					border-bottom: 2px solid var(--border-color-high);
					white-space: nowrap;
					padding: 5px 8px;
					font-size: 0.9em;
					font-weight: 600;
					vertical-align: top;
					text-align: left;
				}
				#fwlive-table thead th.fwlive-port,
				#fwlive-table thead th.fwlive-len {
					text-align: right;
				}
				.fwlive-map[data-view="simple"] #fwlive-table thead th,
				.fwlive-map[data-view="simple"] #fwlive-table tbody td {
					vertical-align: top;
				}
				#fwlive-table thead th.fwlive-action {
					font-weight: 700;
					text-transform: lowercase;
				}
				#fwlive-table tbody td {
					padding: 5px 8px;
					border-bottom: 1px solid var(--border-color-low);
					vertical-align: top;
					font-size: 0.92em;
				}
				.fwlive-row-alt td {
					background: #f9f9f9;
					background: var(--fwlive-bg-medium);
				}
				.fwlive-time, .fwlive-addr, .fwlive-port, .fwlive-len {
					font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
					white-space: nowrap;
				}
				.fwlive-port, .fwlive-len { text-align: right; }
				.fwlive-rule, .fwlive-iface, .fwlive-proto, .fwlive-dir, .fwlive-flags { white-space: nowrap; }
				.fwlive-rule { font-size: 0.88em; }
				.fwlive-rule-link {
					color: var(--primary-color-high);
					text-decoration: none;
					font-weight: 500;
				}
				.fwlive-rule-link:hover { text-decoration: underline; }
				.fwlive-iface-badge {
					display: inline-block;
					padding: 1px 6px;
					background: var(--background-color-low);
					border: 1px solid var(--border-color-medium);
					border-radius: 3px;
					font-size: 0.85em;
					text-decoration: none;
				}
				.fwlive-iface-badge:hover {
					background: var(--background-color-medium);
					border-color: var(--primary-color-medium);
				}
				.fwlive-action {
					font-weight: 700;
					text-transform: lowercase;
					white-space: nowrap;
				}
				.fwlive-deny { color: var(--fwlive-deny-color); }
				.fwlive-pass { color: var(--fwlive-pass-color); }
				#fwlive-table td.fwlive-action.fwlive-pass,
				#fwlive-table td.fwlive-action.fwlive-pass a.fwlive-filter-link {
					color: var(--fwlive-pass-color);
				}
				#fwlive-table td.fwlive-action.fwlive-deny,
				#fwlive-table td.fwlive-action.fwlive-deny a.fwlive-filter-link {
					color: var(--fwlive-deny-color);
				}
				#fwlive-table tbody tr.fwlive-row-pass td {
					background: rgba(70, 165, 70, 0.12);
					background: color-mix(in srgb, var(--fwlive-pass-color) 12%, transparent);
				}
				#fwlive-table tbody tr.fwlive-row-pass.fwlive-row-alt td {
					background: rgba(70, 165, 70, 0.18);
					background: color-mix(in srgb, var(--fwlive-pass-color) 12%, var(--fwlive-bg-medium));
				}
				#fwlive-table tbody tr.fwlive-row-deny td {
					background: rgba(202, 60, 60, 0.12);
					background: color-mix(in srgb, var(--fwlive-deny-color) 12%, transparent);
				}
				#fwlive-table tbody tr.fwlive-row-deny.fwlive-row-alt td {
					background: rgba(202, 60, 60, 0.18);
					background: color-mix(in srgb, var(--fwlive-deny-color) 12%, var(--fwlive-bg-medium));
				}
				.fwlive-map[data-tint-fallback="1"] #fwlive-table tbody tr.fwlive-row-pass td {
					background: rgba(70, 165, 70, 0.12);
				}
				.fwlive-map[data-tint-fallback="1"] #fwlive-table tbody tr.fwlive-row-pass.fwlive-row-alt td {
					background: rgba(70, 165, 70, 0.18);
				}
				.fwlive-map[data-tint-fallback="1"] #fwlive-table tbody tr.fwlive-row-deny td {
					background: rgba(202, 60, 60, 0.12);
				}
				.fwlive-map[data-tint-fallback="1"] #fwlive-table tbody tr.fwlive-row-deny.fwlive-row-alt td {
					background: rgba(202, 60, 60, 0.18);
				}
				.fwlive-unknown { color: var(--text-color-medium); font-weight: 500; }
				.fwlive-message {
					font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
					font-size: 0.85em;
					color: var(--text-color-high);
				}
				.fwlive-scroll.fwlive-msg-wrap .fwlive-message-wrap {
					display: block;
					min-width: 16em;
					max-width: 42em;
					white-space: normal;
					word-break: break-word;
					word-wrap: break-word;
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
				.fwlive-empty {
					margin: 12px 0;
					padding: 10px;
					background: var(--background-color-medium);
					border: 1px dashed var(--border-color-high);
				}
				.fwlive-logging-bar {
					display: none;
					align-items: center;
					gap: 10px;
					margin: 0 0 10px;
					flex-wrap: wrap;
				}
				.fwlive-logging-status {
					font-size: 0.92em;
					color: var(--text-color-medium);
				}
				.fwlive-logging-notice {
					color: var(--fwlive-pass-color);
				}
				.fwlive-filter-link {
					color: inherit;
					text-decoration: underline;
					text-decoration-style: dotted;
					cursor: pointer;
				}
				.fwlive-filter-link:hover { color: var(--primary-color-high); }
				.fwlive-chips {
					display: none;
					flex-wrap: wrap;
					align-items: center;
					gap: 6px;
					margin: 0 0 10px;
				}
				.fwlive-chip-label {
					line-height: 1.3;
				}
				.fwlive-chip-not {
					font-weight: 700;
				}
				.fwlive-chip {
					display: inline-flex;
					align-items: center;
					gap: 4px;
					padding: 2px 8px;
					background: var(--background-color-low);
					border: 1px solid var(--border-color-medium);
					border-radius: 3px;
					font-size: 0.88em;
				}
				.fwlive-chip-negated {
					border-style: dashed;
					background: var(--background-color-medium);
				}
				.fwlive-chip-invert-wrap {
					position: relative;
					display: inline-flex;
				}
				.fwlive-chip-invert-wrap::before {
					content: attr(data-tip);
					position: absolute;
					bottom: calc(100% + 6px);
					left: 50%;
					transform: translateX(-50%);
					white-space: nowrap;
					padding: 4px 8px;
					font-size: 0.85em;
					font-weight: normal;
					color: var(--text-color-high);
					background: var(--background-color-high);
					border: 1px solid var(--border-color-medium);
					border-radius: 3px;
					box-shadow: 0 2px 6px rgba(0, 0, 0, 0.12);
					opacity: 0;
					visibility: hidden;
					pointer-events: none;
					z-index: 20;
					transition: opacity 0.15s ease 1.5s, visibility 0s linear 2s;
				}
				.fwlive-chip-invert-wrap:hover::before,
				.fwlive-chip-invert-wrap:focus-within::before {
					opacity: 1;
					visibility: visible;
					transition: opacity 0.12s ease 0.35s, visibility 0s;
				}
				.fwlive-chip-invert {
					color: var(--text-color-medium);
					background: none;
					border: none;
					padding: 0;
					font: inherit;
					font-weight: 700;
					line-height: 1;
					cursor: pointer;
				}
				.fwlive-chip-invert:hover { color: var(--primary-color-high); }
				.fwlive-chip-remove {
					color: var(--text-color-medium);
					text-decoration: none;
					font-weight: 700;
					line-height: 1;
				}
				.fwlive-chip-remove:hover { color: var(--fwlive-deny-color); }
				.fwlive-chip-clear {
					font-size: 0.88em;
					margin-left: 4px;
				}
				.fwlive-flood {
					display: none;
					margin: 0 0 10px;
					padding: 8px 12px;
					background: var(--background-color-low);
					border: 1px solid var(--warn-color-high);
					border-radius: 3px;
					color: var(--text-color-high);
					font-size: 0.92em;
				}
				.fwlive-tint-warn {
					display: none;
					color: var(--warn-color-high);
					font-size: 0.92em;
					font-weight: 600;
					white-space: nowrap;
				}
				.fwlive-map[data-view="simple"] #fwlive-msg-layout { display: none; }
				.fwlive-help {
					margin: 10px 0 0;
					font-size: 0.92em;
					color: var(--text-color-medium);
				}
				.fwlive-help ul { margin: 6px 0 0 1.2em; padding: 0; }
				.fwlive-help li { margin: 4px 0; }
				.fwlive-intro { margin: 0 0 12px; color: var(--text-color-high); }
				.fwlive-backend {
					font-size: 0.65em;
					font-weight: normal;
					color: var(--text-color-medium);
					margin-left: 8px;
					vertical-align: middle;
				}
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
					background: var(--background-color-low);
					padding: 8px 12px 10px;
					border-bottom: 1px solid var(--border-color-medium);
				}
				.fwlive-msg-expand-label {
					font-size: 0.82em;
					color: var(--text-color-medium);
					margin-bottom: 4px;
					font-weight: 600;
				}
				.fwlive-msg-expand-body {
					margin: 0;
					white-space: pre-wrap;
					word-break: break-word;
					font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
					font-size: 0.85em;
					color: var(--text-color-high);
				}
				.fwlive-flow-arrow { color: var(--text-color-low); }
				.fwlive-flow-cell { white-space: nowrap; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.9em; }
				.fwlive-map[data-view="simple"] #fwlive-table td.fwlive-action.fwlive-pass,
				.fwlive-map[data-view="simple"] #fwlive-table td.fwlive-action.fwlive-pass a.fwlive-filter-link {
					color: var(--fwlive-pass-color);
				}
				.fwlive-map[data-view="simple"] #fwlive-table td.fwlive-action.fwlive-deny,
				.fwlive-map[data-view="simple"] #fwlive-table td.fwlive-action.fwlive-deny a.fwlive-filter-link {
					color: var(--fwlive-deny-color);
				}
				.fwlive-iface-badge {
					border-radius: 10px;
					padding: 2px 8px;
				}
			`),
			E('h2', {}, [
				_('Firewall Live View'),
				E('span', { 'id': 'fwlive-backend', 'class': 'fwlive-backend' }, '')
			]),
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
				E('label', { 'class': 'fwlive-ctl' }, [
					E('input', {
						'id': 'fwlive-row-tint',
						'type': 'checkbox',
						'checked': 'checked'
					}),
					_('Row tint')
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
					'type': 'button',
					'click': this.toggleMessageLayout.bind(this)
				}, _('Message: wrap')),
				E('span', { 'id': 'fwlive-status', 'class': 'fwlive-status' }, ''),
				E('span', {
					'id': 'fwlive-tint-warn',
					'class': 'fwlive-tint-warn',
					'title': _('Row tint used a local color fallback because the active LuCI theme did not apply pass/deny backgrounds.')
				}, _('Theme tint fallback active'))
			]),
			E('div', { 'id': 'fwlive-flood', 'class': 'fwlive-flood' }, ''),
			E('div', { 'id': 'fwlive-logging-bar', 'class': 'fwlive-logging-bar' }, []),
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
						E('option', { 'value': '!reject' }, _('not reject')),
						E('option', { 'value': '!unknown' }, _('not unknown'))
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
			}, []),
			E('div', { 'id': 'fwlive-scroll', 'class': 'fwlive-scroll fwlive-msg-wrap' }, [
				E('table', { 'id': 'fwlive-table', 'class': 'table cbi-section-table' }, [
					E('thead', {}, E('tr', {}, [])),
					E('tbody', {}, [])
				])
			]),
			E('p', { 'class': 'cbi-value-description' }, _('Click a row for the full log line. Show Detail for all columns. Click a cell to filter; use ≠ on a chip to exclude. Ctrl+click a rule to open firewall settings.')),
			E('details', { 'id': 'fwlive-help', 'class': 'fwlive-help' }, [
				E('summary', {}, _('Help')),
				E('ul', {}, [
					E('li', {}, _('The table updates automatically when your firewall logs traffic. Use Enable logging if the table is empty on a stock config.')),
					E('li', {}, _('Enable logging turns on WAN zone drop/reject logging (same as Network → Firewall). LAN browsing is not logged by default.')),
					E('li', {}, _('The rate shown next to WAN logging is the firewall zone log_limit. OpenWrt defaults to 10/minute when no explicit limit is configured; fwlive does not impose this cap.')),
					this.manualLoggingTestNodes(),
					E('li', {}, _('Click a row to see the full log line (Simple view).')),
					E('li', {}, _('Click an IP, action, or protocol to filter; click ≠ on a filter chip to exclude that value instead.')),
					E('li', {}, _('Use Show Detail for all columns (flags, length, raw message).')),
					E('li', {}, _('If Row tint looks missing, the active LuCI theme may omit success/error CSS variables; fwlive falls back to local colors (air-gapped, no data leaves the device).'))
				])
			])
		]);
	},

	addFooter() {
		this.viewMode = this.readViewMode();
		this.messageLayout = this.readMessageLayout();
		this.showHostnames = this.readShowHostnames();
		this.rowTint = this.readRowTint();
		this.hostnameCache = new Map();
		this.hostnameFailed = new Set();
		this.applyRowLimit(this.readRowLimit());
		this.applyHash();
		this.attachHandlers();
		this.updateMessageLayoutUi();
		this.updateStreamControlsUi();
		this.updateDetailToggleUi();
		this.renderThead();
		this.updateLoggingToolbarUi();
		this.updateEmptyStateUi();
		this.updateBackendUi();
		this.updateTintWarnUi();
		this.renderRows(true);
		if (this.showHostnames)
			this.resolveHostnamesForEntries(this.filteredRows());
	}
});
