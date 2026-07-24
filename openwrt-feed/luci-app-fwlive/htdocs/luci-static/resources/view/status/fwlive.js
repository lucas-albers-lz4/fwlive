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
'require fwlive.constants as constants';
'require fwlive.css as css';
'require fwlive.tint as tint';
'require fwlive.links as links';
'require fwlive.chips as chips';
'require fwlive.logging as logging';
'require fwlive.table as table';

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


return view.extend({
	rowLimit: constants.DEFAULT_ROW_LIMIT,
	maxHistory: constants.DEFAULT_ROW_LIMIT,
	fetchLines: constants.FETCH_LINES_MAX,
	visibleRows: constants.DEFAULT_ROW_LIMIT,
	entries: [],
	sessionSeen: null,
	sessionNewTotal: 0,
	sessionAtPause: 0,
	pauseBufferLoading: false,
	paused: false,
	messageLayout: 'wrap',
	renderBucket: constants.RENDER_CAP_PER_SEC,
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
	_loggingToolbarSig: '',
	_loggingEmptySig: '',
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
		if (this.rowLimit !== constants.DEFAULT_ROW_LIMIT)
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
				if (isFinite(n) && constants.ROW_LIMIT_OPTIONS.indexOf(n) >= 0) {
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

		map.style.setProperty('--fwlive-pass-color', tint.PASS_HEX);
		map.style.setProperty('--fwlive-deny-color', tint.DENY_HEX);
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
		const paintDelta = tint.cssColorPaintDelta(onBg, offBg);
		map.setAttribute('data-tint-probe-delta', String(paintDelta));
		map.setAttribute('data-tint-probe-on', onBg || '');
		map.setAttribute('data-tint-probe-off', offBg || '');
		const broken = tint.tintShouldEngageFallback({
			paintDelta: paintDelta,
			tokenResolved: !!passToken,
			minDelta: tint.PAINT_DELTA_MIN
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
		return constants.COLUMN_SETS[this.viewMode] || constants.COLUMN_SETS.simple;
	},

	setViewMode(mode) {
		if (constants.VIEW_MODES.indexOf(mode) < 0 || mode === this.viewMode)
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

	renderThead() {
		const el = document.getElementById('fwlive-table');
		if (!el)
			return;

		table.renderThead(el, { columns: this.activeColumns().slice() }, {});
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
		return links.firewallZonesPath();
	},

	firewallZonesUrl() {
		return links.firewallZonesUrl();
	},

	firewallZonesLink(label) {
		return links.firewallZonesLink(label);
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

	loggingState() {
		return {
			loggingStatus: this.loggingStatus,
			loggingBusy: this.loggingBusy,
			entriesLength: this.entries.length,
			loggingNotice: this.loggingNotice,
			firewallBackend: this.firewallBackend
		};
	},

	/* Stable signature so poll/renderRows does not wipe the logging button every
	   second (destroys the node between mousedown and click → needs a 2nd click). */
	loggingUiSignature() {
		const st = this.loggingStatus;
		/* Sort blockers so unstable backend order does not force a rebuild. */
		const blockers = (st && st.blockers)
			? st.blockers.slice().sort().join(',')
			: '';
		return [
			st ? (st.wan_log ? '1' : '0') : 'x',
			st ? String(st.wan_log_limit || '') : '',
			blockers,
			this.loggingBusy ? '1' : '0',
			/* entries empty bit: toolbar hides when !wan_log && no rows (logging.js). */
			this.entries.length ? '1' : '0',
			this.loggingNotice || '',
			this.firewallBackend || ''
		].join('|');
	},

	updateLoggingToolbarUi() {
		const bar = document.getElementById('fwlive-logging-bar');
		if (!bar)
			return;

		const sig = this.loggingUiSignature();
		if (sig === this._loggingToolbarSig)
			return;
		this._loggingToolbarSig = sig;

		logging.renderToolbar(bar, this.loggingState(), {
			onEnable: () => this.handleEnableLogging(),
			onDisable: () => this.handleDisableLogging()
		});
	},

	updateEmptyStateUi() {
		const empty = document.getElementById('fwlive-empty');
		if (!empty)
			return;

		const sig = this.loggingUiSignature();
		if (sig === this._loggingEmptySig)
			return;
		this._loggingEmptySig = sig;

		const visible = empty.style.display !== 'none';
		logging.renderEmptyState(empty, this.loggingState(), {
			onEnable: () => this.handleEnableLogging()
		});
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
		return this.paused ? constants.FETCH_LINES_MAX : this.rowLimit;
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
			constants.RENDER_CAP_PER_SEC,
			this.renderBucket + (elapsed * constants.RENDER_CAP_PER_SEC / 1000)
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
			if (constants.ROW_LIMIT_OPTIONS.indexOf(n) >= 0)
				return n;
		} catch (e) {
			/* private mode / no storage */
		}

		return constants.DEFAULT_ROW_LIMIT;
	},

	saveRowLimit() {
		try {
			localStorage.setItem('fwlive-row-limit', String(this.rowLimit));
		} catch (e) {
			/* private mode / no storage */
		}
	},

	applyRowLimit(limit) {
		const n = constants.ROW_LIMIT_OPTIONS.indexOf(limit) >= 0 ? limit : constants.DEFAULT_ROW_LIMIT;
		this.rowLimit = n;
		this.maxHistory = n;
		this.fetchLines = constants.FETCH_LINES_MAX;
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
		if (!isFinite(n) || constants.ROW_LIMIT_OPTIONS.indexOf(n) < 0)
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
		for (let i = 0; i < constants.ROW_LIMIT_OPTIONS.length; i++) {
			const n = constants.ROW_LIMIT_OPTIONS[i];
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
		return links.filterLink(field, value, label,
			(f, v, ev) => this.filterClick(f, v, ev));
	},

	addrFilterLink(field, ip) {
		return links.addrFilterLink(field, ip,
			this.showHostnames, this.hostnameCache,
			(f, v, ev) => this.filterClick(f, v, ev));
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
		return links.ruleAdminPath(hint, this.firewallBackend);
	},

	luciUrl(path) {
		return links.luciUrl(path);
	},

	ruleAdminLink(hint, label) {
		return links.ruleAdminLink(hint, label, this.firewallBackend,
			(f, v, ev) => this.filterClick(f, v, ev));
	},

	ifaceLink(value) {
		return links.ifaceLink(value, (f, v, ev) => this.filterClick(f, v, ev));
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

		chips.renderFilterChips(bar, {
			filters: Object.assign({}, this.readFilters()),
			chipFields: this.FILTER_CHIP_FIELDS
		}, {
			onInvert: (field, ev) => this.invertFilter(field, ev),
			onClear: (field, ev) => this.clearFilter(field, ev),
			onClearAll: (ev) => this.clearAllFilters(ev)
		});
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
		const el = document.getElementById('fwlive-table');
		if (!el)
			return;

		const body = el.querySelector('tbody');
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

		if (empty)
			empty.style.display = rows.length ? 'none' : 'block';
		this.updateStatus(rows);
		this.renderFilterChips();

		table.renderRows(body, {
			rows: rows.slice(),
			columns: this.activeColumns().slice(),
			viewMode: this.viewMode,
			messageLayout: this.messageLayout,
			expandedRowId: this.expandedRowId,
			rowTint: !!this.rowTint,
			showHostnames: !!this.showHostnames,
			hostnameCache: this.hostnameCache,
			firewallBackend: this.firewallBackend
		}, {
			onRowClick: (rowId, ev) => this.onRowClick(rowId, ev),
			onFilterClick: (field, value, ev) => this.filterClick(field, value, ev),
			actionRowTintClass: (action) => this.actionRowTintClass(action)
		});

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
			E('style', {}, css.styleText),
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
					E('li', { 'id': 'fwlive-manual-test' }, []),
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
		const testLi = document.getElementById('fwlive-manual-test');
		if (testLi)
			logging.renderManualTestNodes(testLi, { firewallBackend: this.firewallBackend }, {});
		if (this.showHostnames)
			this.resolveHostnamesForEntries(this.filteredRows());
	}
});
