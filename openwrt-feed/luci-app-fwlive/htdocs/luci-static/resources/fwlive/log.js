'use strict';
'require baseclass';

/**
 * LuCI wrapper — keep logic aligned with core/fwlive-log.js (see scripts/fwlive-test.sh).
 * PARSER_SYNC_VERSION: 4
 */
return baseclass.extend({
	NON_FIREWALL_PREFIX: /^(dnsmasq|procd|ubusd|netifd|odhcpd|logd|dropbear|uhttpd|hostapd|wpad)\b/i,
	FIREWALL_HINT: /\b(fw4|nft|iptables|kernel|firewall)\b/i,
	TCP_FLAG_TAIL: /\b(SYN|ACK|FIN|RST|PSH|URG)(?:\s+(?:SYN|ACK|FIN|RST|PSH|URG))*\s*$/i,
	NETFILTER_KV_GLUE: /([^\s])(?=(IN|OUT|SRC|DST|PROTO|SPT|DPT|LEN|MAC|TYPE|CODE|TTL|TOS|PREC|DF)=)/g,

	normalizeNetfilterMessage: function(message) {
		return (message || '').replace(this.NETFILTER_KV_GLUE, '$1 ');
	},

	parseKeyValueLog: function(message) {
		const out = {};
		const re = /\b([A-Z]+)=([^\s]+)/g;
		const normalized = this.normalizeNetfilterMessage(message);
		let match;

		while ((match = re.exec(normalized)) !== null)
			out[match[1]] = match[2];

		return out;
	},

	detectAction: function(message) {
		const m = message.match(/\b(ACCEPT|ALLOW|PASS|DROP|REJECT|DENY|BLOCK)\b/i);
		return m ? m[1].toUpperCase() : 'UNKNOWN';
	},

	normalizeAction: function(raw) {
		const a = (raw || '').toUpperCase();
		if (/^(ACCEPT|ALLOW|PASS)$/.test(a))
			return 'pass';
		if (a === 'DROP')
			return 'drop';
		if (a === 'REJECT')
			return 'reject';
		if (/^(DENY|BLOCK)$/.test(a))
			return 'block';
		return 'unknown';
	},

	DENY_ACTION: /\b(DROP|REJECT|DENY|BLOCK)\b/i,

	parseRuleHint: function(message) {
		let msg = this.normalizeNetfilterMessage(message || '').trim();
		msg = msg.replace(/^\[\s*[\d.]+\]\s*/, '');

		if (/^fw4:\s*/i.test(msg))
			return 'fw4';

		const beforeKv = msg.match(/^([A-Za-z0-9_.-]+)(?::|\s+)(?=IN=|OUT=|SRC=|DST=|PROTO=)/);
		if (beforeKv)
			return beforeKv[1];

		const colon = msg.match(/^([A-Za-z0-9_.-]+):/);
		if (colon) {
			const tag = colon[1].toLowerCase();
			if (tag !== 'kernel' && tag !== 'iptables')
				return colon[1];
		}

		return '';
	},

	formatRuleLabel: function(hint) {
		if (!hint)
			return '';

		if (hint === 'fw4')
			return 'Firewall4';

		return hint.replace(/-/g, ' ');
	},

	inferActionRaw: function(message, kv, actionRaw) {
		if (actionRaw && actionRaw !== 'UNKNOWN')
			return actionRaw;

		const msg = this.normalizeNetfilterMessage(message || '');
		/* Ignore KEY=value payloads so MAC=…DROP… / PASS=… do not suppress pass inference. */
		const withoutKv = msg.replace(/\b[A-Z]+=[^\s]*/g, ' ');
		if (this.DENY_ACTION.test(withoutKv))
			return 'UNKNOWN';

		if (/^kernel:/i.test(msg.trim()))
			return 'UNKNOWN';

		const hasTuple = !!(kv.IN || kv.OUT) && !!(kv.SRC || kv.DST || kv.PROTO);
		if (hasTuple)
			return 'PASS';

		return 'UNKNOWN';
	},

	parseFlags: function(message, kv) {
		if (kv.TCPFLAGS)
			return kv.TCPFLAGS;
		if (kv.FLAGS)
			return kv.FLAGS;

		const m = message.match(this.TCP_FLAG_TAIL);
		if (!m)
			return '';

		return m[0].trim().toUpperCase().replace(/\s+/g, ',');
	},

	parseLength: function(kv) {
		const len = kv.LEN || kv.LENGTH || '';
		if (!len)
			return null;

		const n = parseInt(len, 10);
		return isFinite(n) ? n : null;
	},

	timestampUnix: function(entry) {
		if (!entry || entry.time == null || entry.time === '')
			return null;

		if (typeof entry.time === 'string' && /^\d{4}-\d{2}-\d{2}[T ]/.test(entry.time)) {
			const ms = new Date(entry.time).getTime();
			if (isFinite(ms))
				return Math.floor(ms / 1000);
		}

		const n = Number(entry.time);
		if (!isFinite(n))
			return null;

		return n > 1e12 ? Math.floor(n / 1000) : Math.floor(n);
	},

	formatTimestampDisplay: function(entry) {
		const unix = this.timestampUnix(entry);
		if (unix == null)
			return '';

		return new Date(unix * 1000).toISOString();
	},

	formatTimestampLocal: function(unix) {
		if (unix == null || !isFinite(unix))
			return '';

		const d = new Date(unix * 1000);
		const pad = function(n) { return (n < 10 ? '0' : '') + n; };

		return '%d-%s-%s %s:%s:%s'.format(
			d.getFullYear(),
			pad(d.getMonth() + 1),
			pad(d.getDate()),
			pad(d.getHours()),
			pad(d.getMinutes()),
			pad(d.getSeconds())
		);
	},

	formatTimestampCompact: function(unix) {
		if (unix == null || !isFinite(unix))
			return '';

		const d = new Date(unix * 1000);
		const pad = function(n) { return (n < 10 ? '0' : '') + n; };

		return '%s:%s:%s'.format(pad(d.getHours()), pad(d.getMinutes()), pad(d.getSeconds()));
	},

	formatFlowDisplay: function(row) {
		const src = row && row.src ? String(row.src) : '';
		const dst = row && row.dst ? String(row.dst) : '';
		const sport = row && row.sport ? String(row.sport) : '';
		const dport = row && row.dport ? String(row.dport) : '';
		let left = src;
		let right = dst;

		if (sport)
			left = left ? (left + ':' + sport) : (':' + sport);
		if (dport)
			right = right ? (right + ':' + dport) : (':' + dport);

		if (!left && !right)
			return '—';
		if (!right)
			return left;
		if (!left)
			return '→ ' + right;

		return left + ' → ' + right;
	},

	formatCell: function(value) {
		if (value == null || value === '')
			return '';

		return String(value);
	},

	formatActionLabel: function(action) {
		const a = (action || '').toLowerCase();
		if (!a || a === 'unknown')
			return '—';
		return a;
	},

	formatMessageDisplay: function(message, layout) {
		let m = this.normalizeNetfilterMessage(message || '');
		m = m.replace(/^\[\s*[\d.]+\]\s*/, '');
		m = m.replace(/\bMAC=[^\s]+/g, '');
		m = m.replace(/\s+/g, ' ').trim();

		if (layout === 'oneline')
			return m;

		if (m.length > 240)
			return m.substring(0, 237) + '…';

		return m;
	},

	isFirewallEvent: function(entry) {
		const msg = this.normalizeNetfilterMessage((entry && entry.msg) || '');
		if (!msg.trim())
			return false;

		if (this.NON_FIREWALL_PREFIX.test(msg))
			return false;

		const kv = this.parseKeyValueLog(msg);
		const hasSrcDst = !!(kv.SRC && kv.DST);
		const hasNetfilterTuple = !!(kv.IN || kv.OUT) && !!(kv.SRC || kv.DST || kv.PROTO || kv.SPT || kv.DPT);
		const action = this.detectAction(msg);
		const hasActionAndContext = action !== 'UNKNOWN' && !!(kv.IN || kv.OUT || kv.PROTO || kv.SRC || kv.DST);

		if (hasSrcDst || hasNetfilterTuple || hasActionAndContext)
			return true;

		if (this.FIREWALL_HINT.test(msg) && action !== 'UNKNOWN')
			return true;

		return this.FIREWALL_HINT.test(msg) && !!(kv.IN || kv.OUT || kv.SRC || kv.DST || kv.PROTO);
	},

	makeEntryId: function(entry, tsUnix, action, src, dst, sport, dport, proto, ifaceIn, ifaceOut) {
		if (entry && entry.id != null && entry.id !== '')
			return 'log:' + entry.id;

		return [tsUnix, action, src, dst, sport, dport, proto, ifaceIn, ifaceOut, entry.msg || ''].join('|');
	},

	normalizeEntry: function(entry) {
		const kv = this.parseKeyValueLog(entry.msg || '');
		const tsUnix = this.timestampUnix(entry);
		const tsDisplay = this.formatTimestampDisplay(entry);
		const proto = (kv.PROTO || '').toUpperCase();
		const actionRaw = this.inferActionRaw(entry.msg || '', kv, this.detectAction(entry.msg || ''));
		const action = this.normalizeAction(actionRaw);
		const src = kv.SRC || '';
		const dst = kv.DST || '';
		const sport = kv.SPT || '';
		const dport = kv.DPT || '';
		const ifaceIn = kv.IN || '';
		const ifaceOut = kv.OUT || '';
		const iface = ifaceIn || ifaceOut || '';
		const dir = ifaceIn && ifaceOut ? 'forward' : (ifaceIn ? 'in' : (ifaceOut ? 'out' : 'unknown'));
		const flags = this.parseFlags(entry.msg || '', kv);
		const length = this.parseLength(kv);
		const ruleHint = this.parseRuleHint(entry.msg || '');
		const ruleLabel = this.formatRuleLabel(ruleHint);

		return {
			id: this.makeEntryId(entry, tsUnix, action, src, dst, sport, dport, proto, ifaceIn, ifaceOut),
			log_id: entry && entry.id != null ? Number(entry.id) : null,
			timestamp: tsUnix,
			timestamp_display: tsDisplay,
			rule_hint: ruleHint,
			rule_label: ruleLabel,
			action: action,
			action_raw: actionRaw,
			interface: iface,
			interface_in: ifaceIn,
			interface_out: ifaceOut,
			direction: dir,
			proto: proto,
			src: src,
			sport: sport,
			dst: dst,
			dport: dport,
			flags: flags,
			length: length,
			message: entry.msg || ''
		};
	},

	parseFilterValue: function(val) {
		const s = (val || '').trim();
		if (!s)
			return { negate: false, value: '' };

		if (s.charAt(0) === '!')
			return { negate: true, value: s.slice(1).trim() };

		return { negate: false, value: s };
	},

	toggleFilterNegation: function(val) {
		const p = this.parseFilterValue(val);
		if (!p.value)
			return val;

		return p.negate ? p.value : '!' + p.value;
	},

	formatFilterChipLabel: function(field, val) {
		const p = this.parseFilterValue(val);
		if (!p.value)
			return '';

		if (p.negate) {
			if (field === 'q' || field === 'src' || field === 'dst')
				return '%s: not contains %s'.format(field, p.value);

			return '%s: not %s'.format(field, p.value);
		}

		return '%s: %s'.format(field, val);
	},

	matchesTextField: function(haystack, spec) {
		const p = this.parseFilterValue(spec);
		if (!p.value)
			return true;

		const hit = (haystack || '').indexOf(p.value) !== -1;
		return p.negate ? !hit : hit;
	},

	matchesExactField: function(haystack, spec) {
		const p = this.parseFilterValue(spec);
		if (!p.value)
			return true;

		const want = p.value.toUpperCase();
		const got = (haystack || '').toUpperCase();
		const hit = got === want;
		return p.negate ? !hit : hit;
	},

	matchesFilter: function(row, filters) {
		if (filters.q) {
			const p = this.parseFilterValue(filters.q);
			if (p.value) {
				const keys = Object.keys(row);
				const parts = [];
				for (let i = 0; i < keys.length; i++)
					parts.push(row[keys[i]]);
				const blob = parts.join(' ').toLowerCase();
				const hit = blob.indexOf(p.value.toLowerCase()) !== -1;
				if (p.negate ? hit : !hit)
					return false;
			}
		}

		if (filters.action) {
			const p = this.parseFilterValue(filters.action);
			if (p.value) {
				const want = p.value.toLowerCase();
				const hit = row.action === want
					|| (row.action_raw || '').toUpperCase() === p.value.toUpperCase();
				if (p.negate ? hit : !hit)
					return false;
			}
		}

		if (filters.interface) {
			const p = this.parseFilterValue(filters.interface);
			if (p.value) {
				const iface = p.value;
				const hit = row.interface === iface
					|| row.interface_in === iface
					|| row.interface_out === iface;
				if (p.negate ? hit : !hit)
					return false;
			}
		}

		if (filters.proto && !this.matchesExactField(row.proto, filters.proto))
			return false;
		if (filters.src && !this.matchesTextField(row.src, filters.src))
			return false;
		if (filters.dst && !this.matchesTextField(row.dst, filters.dst))
			return false;
		if (filters.sport && !this.matchesExactField(row.sport, filters.sport))
			return false;
		if (filters.dport && !this.matchesExactField(row.dport, filters.dport))
			return false;
		return true;
	},

	actionRowClass: function(action) {
		const a = (action || '').toLowerCase();
		if (a === 'drop' || a === 'reject' || a === 'block')
			return 'fwlive-action fwlive-deny';
		if (a === 'pass')
			return 'fwlive-action fwlive-pass';
		return 'fwlive-action fwlive-unknown';
	}
});
