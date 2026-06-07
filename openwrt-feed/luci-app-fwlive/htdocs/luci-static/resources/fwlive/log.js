'use strict';
'require baseclass';

/**
 * LuCI wrapper — keep logic aligned with core/fwlive-log.js (see scripts/fwlive-test.sh).
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

		if (typeof entry.time === 'string' && entry.time.indexOf('T') !== -1)
			return Math.floor(new Date(entry.time).getTime() / 1000);

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

	normalizeEntry: function(entry) {
		const kv = this.parseKeyValueLog(entry.msg || '');
		const tsUnix = this.timestampUnix(entry);
		const tsDisplay = this.formatTimestampDisplay(entry);
		const proto = (kv.PROTO || '').toUpperCase();
		const actionRaw = this.detectAction(entry.msg || '');
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

		return {
			id: [tsUnix, action, src, dst, sport, dport, proto, ifaceIn, ifaceOut, entry.msg || ''].join('|'),
			timestamp: tsUnix,
			timestamp_display: tsDisplay,
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

	matchesFilter: function(row, filters) {
		if (filters.q && !Object.values(row).join(' ').toLowerCase().includes(filters.q.toLowerCase()))
			return false;

		if (filters.action) {
			const want = filters.action.toLowerCase();
			const raw = (row.action_raw || '').toUpperCase();
			if (row.action !== want && raw !== filters.action.toUpperCase())
				return false;
		}

		if (filters.interface) {
			const iface = filters.interface;
			if (row.interface !== iface && row.interface_in !== iface && row.interface_out !== iface)
				return false;
		}

		if (filters.proto && row.proto !== filters.proto.toUpperCase())
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
	},

	actionRowClass: function(action) {
		const a = (action || '').toLowerCase();
		if (a === 'drop' || a === 'reject' || a === 'block')
			return 'fwlive-deny';
		if (a === 'pass')
			return 'fwlive-pass';
		return '';
	}
});
