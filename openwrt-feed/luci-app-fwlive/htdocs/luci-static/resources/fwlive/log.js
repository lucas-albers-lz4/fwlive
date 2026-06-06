'use strict';
'require baseclass';

/**
 * LuCI wrapper — keep logic aligned with core/fwlive-log.js (see scripts/fwlive-test.sh).
 */
return baseclass.extend({
	NON_FIREWALL_PREFIX: /^(dnsmasq|procd|ubusd|netifd|odhcpd|logd|dropbear|uhttpd|hostapd|wpad)\b/i,
	FIREWALL_HINT: /\b(fw4|nft|iptables|kernel|firewall)\b/i,

	parseKeyValueLog: function(message) {
		const out = {};
		const re = /\b([A-Z]+)=([^\s]+)/g;
		let match;

		while ((match = re.exec(message)) !== null)
			out[match[1]] = match[2];

		return out;
	},

	detectAction: function(message) {
		const m = message.match(/\b(ACCEPT|ALLOW|PASS|DROP|REJECT|DENY|BLOCK)\b/i);
		return m ? m[1].toUpperCase() : 'UNKNOWN';
	},

	isFirewallEvent: function(entry) {
		const msg = (entry && entry.msg) || '';
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

	formatTimestamp: function(entry) {
		if (!entry || entry.time == null || entry.time === '')
			return '';

		if (typeof entry.time === 'string' && entry.time.indexOf('T') !== -1)
			return new Date(entry.time).toISOString();

		const n = Number(entry.time);
		if (!isFinite(n))
			return '';

		const ms = n > 1e12 ? n : n * 1000;
		return new Date(ms).toISOString();
	},

	normalizeEntry: function(entry) {
		const kv = this.parseKeyValueLog(entry.msg || '');
		const ts = this.formatTimestamp(entry);
		const proto = (kv.PROTO || '').toUpperCase();
		const action = this.detectAction(entry.msg || '');
		const src = kv.SRC || '';
		const dst = kv.DST || '';
		const sport = kv.SPT || '';
		const dport = kv.DPT || '';
		const ifaceIn = kv.IN || '';
		const ifaceOut = kv.OUT || '';
		const iface = ifaceIn || ifaceOut || '';
		const dir = ifaceIn && ifaceOut ? 'forward' : (ifaceIn ? 'in' : (ifaceOut ? 'out' : 'unknown'));

		return {
			id: [ts, action, src, dst, sport, dport, proto, iface, entry.msg || ''].join('|'),
			timestamp: ts,
			action: action,
			interface: iface,
			interface_in: ifaceIn,
			interface_out: ifaceOut,
			direction: dir,
			proto: proto,
			src: src,
			sport: sport,
			dst: dst,
			dport: dport,
			message: entry.msg || ''
		};
	},

	matchesFilter: function(row, filters) {
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
	},

	actionRowClass: function(action) {
		const a = (action || '').toUpperCase();
		if (a.match(/DROP|REJECT|DENY|BLOCK/))
			return 'fwlive-deny';
		if (a.match(/ACCEPT|ALLOW|PASS/))
			return 'fwlive-pass';
		return '';
	}
});
