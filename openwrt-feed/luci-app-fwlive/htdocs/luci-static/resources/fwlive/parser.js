'use strict';

function parseKeyValueLog(message) {
	const out = {};
	const re = /\b([A-Z]+)=([^\s]+)/g;
	let match;

	while ((match = re.exec(message)) !== null)
		out[match[1]] = match[2];

	return out;
}

function detectAction(message) {
	const m = message.match(/\b(ACCEPT|ALLOW|PASS|DROP|REJECT|DENY|BLOCK)\b/i);
	return m ? m[1].toUpperCase() : 'UNKNOWN';
}

function normalizeEntry(entry) {
	const kv = parseKeyValueLog(entry.msg || '');
	const ts = entry.time ? new Date(entry.time).toISOString() : '';
	const proto = (kv.PROTO || '').toUpperCase();
	const action = detectAction(entry.msg || '');
	const src = kv.SRC || '';
	const dst = kv.DST || '';
	const sport = kv.SPT || '';
	const dport = kv.DPT || '';
	const iface = kv.IN || kv.OUT || '';
	const dir = kv.IN && kv.OUT ? 'forward' : (kv.IN ? 'in' : (kv.OUT ? 'out' : 'unknown'));

	return {
		id: [ts, action, src, dst, sport, dport, proto, iface, entry.msg || ''].join('|'),
		timestamp: ts,
		action: action,
		interface: iface,
		direction: dir,
		proto: proto,
		src: src,
		sport: sport,
		dst: dst,
		dport: dport,
		message: entry.msg || ''
	};
}

return {
	parseKeyValueLog: parseKeyValueLog,
	normalizeEntry: normalizeEntry
};
