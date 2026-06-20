'use strict';

/**
 * Shared firewall log parsing and filtering (Node CLI + unit tests).
 * Keep in sync with openwrt-feed/.../fwlive/log.js (LuCI baseclass wrapper).
 * PARSER_SYNC_VERSION: 2
 */

const NON_FIREWALL_PREFIX = /^(dnsmasq|procd|ubusd|netifd|odhcpd|logd|dropbear|uhttpd|hostapd|wpad)\b/i;
const FIREWALL_HINT = /\b(fw4|nft|iptables|kernel|firewall)\b/i;
const TCP_FLAG_TAIL = /\b(SYN|ACK|FIN|RST|PSH|URG)(?:\s+(?:SYN|ACK|FIN|RST|PSH|URG))*\s*$/i;
const NETFILTER_KV_GLUE = /([^\s])(?=(IN|OUT|SRC|DST|PROTO|SPT|DPT|LEN|MAC|TYPE|CODE|TTL|TOS|PREC|DF)=)/g;

/** nft log prefixes are concatenated with IN= in kernel lines (e.g. fwlive-pingIN=lo). */
function normalizeNetfilterMessage(message) {
	return (message || '').replace(NETFILTER_KV_GLUE, '$1 ');
}

function parseKeyValueLog(message) {
	const out = {};
	const re = /\b([A-Z]+)=([^\s]+)/g;
	const normalized = normalizeNetfilterMessage(message);
	let match;

	while ((match = re.exec(normalized)) !== null)
		out[match[1]] = match[2];

	return out;
}

function detectAction(message) {
	const m = message.match(/\b(ACCEPT|ALLOW|PASS|DROP|REJECT|DENY|BLOCK)\b/i);
	return m ? m[1].toUpperCase() : 'UNKNOWN';
}

function normalizeAction(raw) {
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
}

const DENY_ACTION = /\b(DROP|REJECT|DENY|BLOCK)\b/i;

/** Extract nft/fw4 log prefix or tag (e.g. fwlive-ping, fwlive-test, fw4). */
function parseRuleHint(message) {
	let msg = normalizeNetfilterMessage(message || '').trim();
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
}

/** Display label for rule_hint (UCI resolve deferred; cosmetic for now). */
function formatRuleLabel(hint) {
	if (!hint)
		return '';

	if (hint === 'fw4')
		return 'Firewall4';

	return hint.replace(/-/g, ' ');
}

/** nft `log … accept` lines often omit ACCEPT; infer pass when context is clearly non-deny. */
function inferActionRaw(message, kv, actionRaw) {
	if (actionRaw && actionRaw !== 'UNKNOWN')
		return actionRaw;

	const msg = normalizeNetfilterMessage(message || '');
	if (DENY_ACTION.test(msg))
		return 'UNKNOWN';

	if (/^kernel:/i.test(msg.trim()))
		return 'UNKNOWN';

	const hasTuple = !!(kv.IN || kv.OUT) && !!(kv.SRC || kv.DST || kv.PROTO);
	if (hasTuple)
		return 'PASS';

	return 'UNKNOWN';
}

function parseFlags(message, kv) {
	if (kv.TCPFLAGS)
		return kv.TCPFLAGS;
	if (kv.FLAGS)
		return kv.FLAGS;

	const m = message.match(TCP_FLAG_TAIL);
	if (!m)
		return '';

	return m[0].trim().toUpperCase().replace(/\s+/g, ',');
}

function parseLength(kv) {
	const len = kv.LEN || kv.LENGTH || '';
	if (!len)
		return null;

	const n = parseInt(len, 10);
	return Number.isFinite(n) ? n : null;
}

function timestampUnix(entry) {
	if (!entry || entry.time == null || entry.time === '')
		return null;

	if (typeof entry.time === 'string' && entry.time.includes('T'))
		return Math.floor(new Date(entry.time).getTime() / 1000);

	const n = Number(entry.time);
	if (!Number.isFinite(n))
		return null;

	return n > 1e12 ? Math.floor(n / 1000) : Math.floor(n);
}

function formatTimestampDisplay(entry) {
	const unix = timestampUnix(entry);
	if (unix == null)
		return '';

	return new Date(unix * 1000).toISOString();
}

function isFirewallEvent(entry) {
	const msg = normalizeNetfilterMessage((entry && entry.msg) || '');
	if (!msg.trim())
		return false;

	if (NON_FIREWALL_PREFIX.test(msg))
		return false;

	const kv = parseKeyValueLog(msg);
	const hasSrcDst = !!(kv.SRC && kv.DST);
	const hasNetfilterTuple = !!(kv.IN || kv.OUT) && !!(kv.SRC || kv.DST || kv.PROTO || kv.SPT || kv.DPT);
	const action = detectAction(msg);
	const hasActionAndContext = action !== 'UNKNOWN' && !!(kv.IN || kv.OUT || kv.PROTO || kv.SRC || kv.DST);

	if (hasSrcDst || hasNetfilterTuple || hasActionAndContext)
		return true;

	if (FIREWALL_HINT.test(msg) && action !== 'UNKNOWN')
		return true;

	return FIREWALL_HINT.test(msg) && !!(kv.IN || kv.OUT || kv.SRC || kv.DST || kv.PROTO);
}

function makeEntryId(entry, tsUnix, action, src, dst, sport, dport, proto, ifaceIn, ifaceOut) {
	if (entry && entry.id != null && entry.id !== '')
		return 'log:' + entry.id;

	return [tsUnix, action, src, dst, sport, dport, proto, ifaceIn, ifaceOut, entry.msg || ''].join('|');
}

function normalizeEntry(entry) {
	const kv = parseKeyValueLog(entry.msg || '');
	const tsUnix = timestampUnix(entry);
	const tsDisplay = formatTimestampDisplay(entry);
	const proto = (kv.PROTO || '').toUpperCase();
	const actionRaw = inferActionRaw(entry.msg || '', kv, detectAction(entry.msg || ''));
	const action = normalizeAction(actionRaw);
	const src = kv.SRC || '';
	const dst = kv.DST || '';
	const sport = kv.SPT || '';
	const dport = kv.DPT || '';
	const ifaceIn = kv.IN || '';
	const ifaceOut = kv.OUT || '';
	const iface = ifaceIn || ifaceOut || '';
	const dir = ifaceIn && ifaceOut ? 'forward' : (ifaceIn ? 'in' : (ifaceOut ? 'out' : 'unknown'));
	const flags = parseFlags(entry.msg || '', kv);
	const length = parseLength(kv);
	const ruleHint = parseRuleHint(entry.msg || '');
	const ruleLabel = formatRuleLabel(ruleHint);

	return {
		id: makeEntryId(entry, tsUnix, action, src, dst, sport, dport, proto, ifaceIn, ifaceOut),
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
}

/** Leading `!` negates the predicate (is not / not contains). */
function parseFilterValue(val) {
	const s = (val || '').trim();
	if (!s)
		return { negate: false, value: '' };

	if (s.charAt(0) === '!')
		return { negate: true, value: s.slice(1).trim() };

	return { negate: false, value: s };
}

function formatFilterChipLabel(field, val) {
	const p = parseFilterValue(val);
	if (!p.value)
		return '';

	if (p.negate) {
		if (field === 'q' || field === 'src' || field === 'dst')
			return field + ': not contains ' + p.value;

		return field + ': not ' + p.value;
	}

	return field + ': ' + val;
}

function matchesTextField(haystack, spec) {
	const p = parseFilterValue(spec);
	if (!p.value)
		return true;

	const hit = (haystack || '').includes(p.value);
	return p.negate ? !hit : hit;
}

function matchesExactField(haystack, spec) {
	const p = parseFilterValue(spec);
	if (!p.value)
		return true;

	const want = p.value.toUpperCase();
	const got = (haystack || '').toUpperCase();
	const hit = got === want;
	return p.negate ? !hit : hit;
}

function matchesFilter(row, filters) {
	if (filters.q) {
		const p = parseFilterValue(filters.q);
		if (p.value) {
			const blob = Object.values(row).join(' ').toLowerCase();
			const hit = blob.includes(p.value.toLowerCase());
			if (p.negate ? hit : !hit)
				return false;
		}
	}

	if (filters.action) {
		const p = parseFilterValue(filters.action);
		if (p.value) {
			const want = p.value.toLowerCase();
			const hit = row.action === want
				|| (row.action_raw || '').toUpperCase() === p.value.toUpperCase();
			if (p.negate ? hit : !hit)
				return false;
		}
	}

	if (filters.interface) {
		const p = parseFilterValue(filters.interface);
		if (p.value) {
			const iface = p.value;
			const hit = row.interface === iface
				|| row.interface_in === iface
				|| row.interface_out === iface;
			if (p.negate ? hit : !hit)
				return false;
		}
	}

	if (filters.proto && !matchesExactField(row.proto, filters.proto))
		return false;
	if (filters.src && !matchesTextField(row.src, filters.src))
		return false;
	if (filters.dst && !matchesTextField(row.dst, filters.dst))
		return false;
	if (filters.sport && !matchesExactField(row.sport, filters.sport))
		return false;
	if (filters.dport && !matchesExactField(row.dport, filters.dport))
		return false;
	return true;
}

function actionRowClass(action) {
	const a = (action || '').toLowerCase();
	if (a === 'drop' || a === 'reject' || a === 'block')
		return 'fwlive-deny';
	if (a === 'pass')
		return 'fwlive-pass';
	return '';
}

function filterLogEntries(entries, options) {
	const opts = options || {};
	const list = Array.isArray(entries) ? entries : [];
	const out = [];
	const seen = {};

	for (let i = 0; i < list.length; i++) {
		const raw = list[i];
		if (!isFirewallEvent(raw))
			continue;

		const row = normalizeEntry(raw);
		if (seen[row.id])
			continue;
		seen[row.id] = true;
		out.push(row);
	}

	const max = opts.maxHistory || out.length;
	return out.slice(-max);
}

function statsLogEntries(entries) {
	const list = Array.isArray(entries) ? entries : [];
	let firewall = 0;
	let noise = 0;

	for (let i = 0; i < list.length; i++) {
		if (isFirewallEvent(list[i]))
			firewall++;
		else
			noise++;
	}

	return { total: list.length, firewall: firewall, noise: noise };
}

function readInputPayload(buffer) {
	const text = buffer.trim();
	if (!text)
		return { log: [] };

	const parsed = JSON.parse(text);
	if (Array.isArray(parsed))
		return { log: parsed };
	if (parsed && Array.isArray(parsed.log))
		return parsed;
	return { log: [] };
}

function cliMain(argv) {
	const cmd = argv[2] || 'filter';
	const fs = require('node:fs');

	function runOn(text) {
		const payload = readInputPayload(text);
		if (cmd === 'stats') {
			console.log(JSON.stringify(statsLogEntries(payload.log), null, 2));
			return;
		}
		const rows = filterLogEntries(payload.log);
		console.log(JSON.stringify(rows, null, 2));
	}

	const file = argv[3];
	if (file) {
		runOn(fs.readFileSync(file, 'utf8'));
		return;
	}

	if (process.stdin.isTTY) {
		console.error('usage: node core/fwlive-log.js <filter|stats> [file.json]');
		console.error('       ... | node core/fwlive-log.js filter');
		process.exit(1);
	}

	const chunks = [];
	process.stdin.setEncoding('utf8');
	process.stdin.on('data', (c) => chunks.push(c));
	process.stdin.on('end', () => runOn(chunks.join('')));
}

module.exports = {
	normalizeNetfilterMessage,
	parseKeyValueLog,
	parseRuleHint,
	formatRuleLabel,
	detectAction,
	inferActionRaw,
	normalizeAction,
	parseFlags,
	parseLength,
	timestampUnix,
	formatTimestampDisplay,
	isFirewallEvent,
	normalizeEntry,
	parseFilterValue,
	formatFilterChipLabel,
	matchesFilter,
	actionRowClass,
	filterLogEntries,
	statsLogEntries,
	readInputPayload,
	NON_FIREWALL_PREFIX,
	FIREWALL_HINT
};

if (require.main === module)
	cliMain(process.argv);
