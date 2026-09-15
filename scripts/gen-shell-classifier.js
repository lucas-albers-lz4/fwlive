#!/usr/bin/env node
'use strict';

/**
 * Emit the POSIX shell wrapper and standalone awk program used by
 * fwlive-is-firewall-event.sh from core CLASSIFY_SPEC.
 * Usage: node scripts/gen-shell-classifier.js > path/to/fwlive-is-firewall-event.sh
 *        node scripts/gen-shell-classifier.js --awk > path/to/fwlive-is-firewall-event.awk
 *
 * The generated classifier is one BusyBox-awk program (constant process
 * count per poll, not O(entries)). is_firewall_event_msg stays as the
 * single-message API for tests / z3; the filter uses MODE=json_reply and keeps
 * MODE=json for its entry-stream helper.
 */

const path = require('node:path');
const core = require(path.join(__dirname, '..', 'core', 'fwlive-log.js'));
const SPEC = core.CLASSIFY_SPEC;

function awkEscapeAlt(words) {
	return words.join('|');
}

function emitAwkPred(node) {
	if (node.kv)
		return node.kv.map(function(k) { return 'has_kv(s, "' + k + '")'; }).join(' && ');
	if (node.kvAny)
		return '(' + node.kvAny.map(function(k) { return 'has_kv(s, "' + k + '")'; }).join(' || ') + ')';
	if (node.action === 'known')
		return 'action != "UNKNOWN"';
	if (node.hint)
		return 'has_hint(s)';
	return '0';
}

function emitAwkAnd(node) {
	return node.and.map(emitAwkPred).join(' && ');
}

function emitAwkRules() {
	const lines = [];
	for (let i = 0; i < SPEC.rules.length; i++) {
		const rule = SPEC.rules[i];
		if (rule.or) {
			for (let j = 0; j < rule.or.length; j++)
				lines.push('\tif (' + emitAwkAnd(rule.or[j]) + ') return 1');
		} else if (rule.and) {
			lines.push('\tif (' + emitAwkAnd(rule) + ') return 1');
		}
	}
	return lines.join('\n');
}

function emitAwkProgram() {
	const glue = SPEC.glueKeys.join(' ');
	const prefixes = awkEscapeAlt(SPEC.nonFirewallPrefixes);
	const hints = awkEscapeAlt(SPEC.firewallHints.map(function(w) { return w.toLowerCase(); }));
	const actions = SPEC.actionWords.join(' ');

	return [
		'function normalize(s, keys, n, i, k) {',
		'\tn = split("' + glue + '", keys, " ")',
		'\tfor (i = 1; i <= n; i++) {',
		'\t\tk = keys[i]',
		'\t\twhile (match(s, "[^[:space:]]" k "="))',
		'\t\t\ts = substr(s, 1, RSTART) " " substr(s, RSTART + 1)',
		'\t}',
		'\treturn s',
		'}',
		'function trim(s) {',
		'\tsub(/^[[:space:]]+/, "", s)',
		'\tsub(/[[:space:]]+$/, "", s)',
		'\treturn s',
		'}',
		'function has_kv(s, key) {',
		'\treturn s ~ "(^|[^A-Za-z0-9_])" key "="',
		'}',
		'function has_hint(s, lc) {',
		'\tlc = tolower(s)',
		'\treturn lc ~ "(^|[^a-z0-9_])(' + hints + ')([^a-z0-9_]|$)"',
		'}',
		'function non_fw_prefix(s, lc) {',
		'\tlc = tolower(s)',
		'\treturn lc ~ "^(' + prefixes + ')([^a-z0-9_]|$)"',
		'}',
		'function detect_action(s, words, n, i, w, wl, lc, start, pos, before, afterc, best, bestpos) {',
		'\tn = split("' + actions + '", words, " ")',
		'\tlc = tolower(s)',
		'\tbest = ""',
		'\tbestpos = length(s) + 1',
		'\tfor (i = 1; i <= n; i++) {',
		'\t\tw = words[i]',
		'\t\twl = tolower(w)',
		'\t\tstart = 1',
		'\t\twhile (start <= length(lc) && match(substr(lc, start), wl)) {',
		'\t\t\tpos = start + RSTART - 1',
		'\t\t\tbefore = (pos == 1) ? " " : substr(lc, pos - 1, 1)',
		'\t\t\tafterc = substr(lc, pos + length(wl), 1)',
		'\t\t\tif (before !~ /[a-z0-9_]/ && (afterc == "" || afterc !~ /[a-z0-9_]/)) {',
		'\t\t\t\tif (pos < bestpos) { bestpos = pos; best = w }',
		'\t\t\t\tbreak',
		'\t\t\t}',
		'\t\t\tstart = pos + 1',
		'\t\t}',
		'\t}',
		'\treturn best == "" ? "UNKNOWN" : best',
		'}',
		'function json_unhex4(h, n, i, c, v) {',
		'\tn = 0',
		'\th = tolower(h)',
		'\tfor (i = 1; i <= 4; i++) {',
		'\t\tc = substr(h, i, 1)',
		'\t\tv = index("0123456789abcdef", c)',
		'\t\tif (v == 0) return -1',
		'\t\tn = n * 16 + v - 1',
		'\t}',
		'\treturn n',
		'}',
		'function json_get_msg(obj, s, i, c, esc, out, hex, n) {',
		'\tif (!match(obj, /"msg"[[:space:]]*:[[:space:]]*"/)) return ""',
		'\ts = substr(obj, RSTART + RLENGTH)',
		'\tout = ""',
		'\tesc = 0',
		'\tfor (i = 1; i <= length(s); i++) {',
		'\t\tc = substr(s, i, 1)',
		'\t\tif (esc) {',
		'\t\t\tif (c == "n") out = out "\\n"',
		'\t\t\telse if (c == "t") out = out "\\t"',
		'\t\t\telse if (c == "r") out = out "\\r"',
		'\t\t\telse if (c == "b") out = out "\\b"',
		'\t\t\telse if (c == "f") out = out "\\f"',
		'\t\t\telse if (c == "u") {',
		'\t\t\t\thex = substr(s, i + 1, 4)',
		'\t\t\t\tn = (length(hex) == 4) ? json_unhex4(hex) : -1',
		'\t\t\t\tif (n >= 1 && n <= 255) out = out sprintf("%c", n)',
		'\t\t\t\telse if (n < 0) out = out "u"',
		'\t\t\t\tif (n >= 0) i += 4',
		'\t\t\t} else out = out c',
		'\t\t\tesc = 0',
		'\t\t} else if (c == "\\\\") {',
		'\t\t\tesc = 1',
		'\t\t} else if (c == "\\"") {',
		'\t\t\treturn out',
		'\t\t} else {',
		'\t\t\tout = out c',
		'\t\t}',
		'\t}',
		'\treturn out',
		'}',
		'function is_fw(s, action) {',
		'\ts = trim(normalize(s))',
		'\tif (s == "") return 0',
		'\tif (non_fw_prefix(s)) return 0',
		'\taction = detect_action(s)',
		emitAwkRules(),
		'\treturn 0',
		'}',
		'function summary_kv(s, key, part) {',
		'\ts = normalize(s)',
		'\tif (!match(s, "(^|[[:space:]])" key "=[^[:space:]]+")) return ""',
		'\tpart = substr(s, RSTART, RLENGTH)',
		'\tsub(/^[^=]*=/, "", part)',
		'\treturn part',
		'}',
		'function summary_rule(s, first) {',
		'\ts = trim(normalize(s))',
		'\tsub(/^\\[[[:space:]]*[0-9.]+\\][[:space:]]*/, "", s)',
		'\tif (tolower(s) ~ /^fw4:[[:space:]]*/) return "fw4"',
		'\tfirst = s',
		'\tsub(/[[:space:]:].*/, "", first)',
		'\tif (first == "" || first ~ /^(IN|OUT|SRC|DST|PROTO|SPT|DPT|LEN|MAC|TYPE|CODE|TTL|TOS|PREC|DF)=/) return ""',
		'\tif (tolower(first) == "kernel" || tolower(first) == "iptables") return ""',
		'\treturn substr(first, 1, 64)',
		'}',
		'function summary_add_count(counts, key) {',
		'\tif (key != "") counts[key]++',
		'}',
		'function json_escape(s, out, i, c) {',
		'\tout = ""',
		'\tfor (i = 1; i <= length(s); i++) {',
		'\t\tc = substr(s, i, 1)',
		'\t\tif (c == "\\\\") out = out "\\\\\\\\"',
		'\t\telse if (c == "\\\"") out = out "\\\\\\\""',
		'\t\telse if (c == "\\n") out = out "\\\\n"',
		'\t\telse if (c == "\\r") out = out "\\\\r"',
		'\t\telse if (c == "\\t") out = out "\\\\t"',
		'\t\telse if (c < " ") out = out " "',
		'\t\telse out = out c',
		'\t}',
		'\treturn out',
		'}',
		'function summary_top(counts, limit, out, i, k, best, best_n) {',
		'\tfor (k in summary_picked) delete summary_picked[k]',
		'\tout = "["',
		'\tfor (i = 0; i < limit; i++) {',
		'\t\tbest = ""; best_n = 0',
		'\t\tfor (k in counts) {',
		'\t\t\tif (!(k in summary_picked) && (counts[k] > best_n || (counts[k] == best_n && (best == "" || k < best)))) {',
		'\t\t\t\tbest = k; best_n = counts[k]',
		'\t\t\t}',
		'\t\t}',
		'\t\tif (best == "") break',
		'\t\tsummary_picked[best] = 1',
		'\t\tif (i) out = out ","',
		'\t\tout = out "{\\"value\\":\\"" json_escape(best) "\\",\\"count\\":" best_n "}"',
		'\t}',
		'\treturn out "]"',
		'}',
		'function summary_add(s, action, src, dst, rule) {',
		'\tsummary_count++',
		'\taction = tolower(detect_action(normalize(s)))',
		'\tif (action == "drop" || action == "reject" || action == "deny" || action == "block") summary_add_count(summary_drop_counts, action)',
		'\tsrc = summary_kv(s, "SRC")',
		'\tif (src == "") src = summary_kv(s, "DST")',
		'\tif (src != "") summary_add_count(summary_talker_counts, substr(src, 1, 64))',
		'\trule = summary_rule(s)',
		'\tif (rule != "") summary_add_count(summary_rule_counts, rule)',
		'}',
		'function summary_json(out) {',
		'\tout = "{\\"scope\\":\\"top of shown sample\\",\\"top_talkers\\":" summary_top(summary_talker_counts, 3)',
		'\tout = out ",\\"top_drops\\":" summary_top(summary_drop_counts, 3)',
		'\tout = out ",\\"top_rules\\":" summary_top(summary_rule_counts, 3) "}"',
		'\t# Keep a conservative UTF-8 character budget: 256 characters is at most',
		'\t# 1024 bytes even when every character occupies four UTF-8 bytes.',
		'\tif (length(out) > 256) return "{\\"scope\\":\\"top of shown sample\\",\\"truncated\\":true}"',
		'\treturn out',
		'}',
		'BEGIN {',
		'\tif (MODE == "json_reply") {',
		'\t\tORS = ""',
		'\t\tprintf "{\\"log\\":["',
		'\t} else if (MODE != "json") ORS = ""',
		'}',
		'{',
		'\tif (MODE == "json" || MODE == "json_reply") {',
		'\t\tmsg = json_get_msg($0)',
		'\t\tif (is_fw(msg)) {',
		'\t\t\tif (SUMMARY != "0") summary_add(msg)',
		'\t\t\tif (out_n++) printf ","',
		'\t\t\tprintf "%s", $0',
		'\t\t}',
		'\t\tnext',
		'\t}',
		'\tbuf = (NR == 1) ? $0 : buf "\\n" $0',
		'}',
		'END {',
		'\tif (MODE == "json_reply") {',
		'\t\tprintf "],\\"messages_received\\":%d", NR',
		'\t\tif (SUMMARY != "0" && summary_count > 0) printf ",\\"summary\\":%s", summary_json()',
		'\t\tprintf "}"',
		'\t}',
		'\telse if (MODE != "json")',
		'\t\tprint is_fw(buf) ? 1 : 0',
		'}'
	].join('\n');
}

const awkBody = emitAwkProgram();

const awkOut = [
	'# SPDX-License-Identifier: Apache-2.0',
	'# Copyright 2025-2026 Lucas Albers <lucas.b.albers@gmail.com>',
	'#',
	'# GENERATED FILE — do not edit. Run: ./scripts/gen-all.sh',
	'# source: core/fwlive-log.js CLASSIFY_SPEC',
	'# Standalone awk program loaded by fwlive-is-firewall-event.sh.',
	'',
	awkBody,
	''
].join('\n');

const out = [
	'# SPDX-License-Identifier: Apache-2.0',
	'# Copyright 2025-2026 Lucas Albers <lucas.b.albers@gmail.com>',
	'#',
	'# GENERATED FILE — do not edit. Run: ./scripts/gen-all.sh',
	'# source: core/fwlive-log.js CLASSIFY_SPEC',
	'# Shared isFirewallEvent parity logic (shell). Sourced by fwlive-log-filter.sh and tests.',
	'# Sourced library: do not add set -euo here (callers own strict mode, #291 C3).',
	'# One awk process classifies a batch (MODE=json/json_reply) or one message (default).',
	'',
	'# The caller sets FILTER_DIR when this file is sourced. Resolve the asset',
	'# once, not once per classification call.',
	'CLASSIFY_AWK="${FILTER_DIR:-${0%/*}}/fwlive-is-firewall-event.awk"',
	'',
	'_fwlive_run_classify() {',
	'\tawk -v MODE="${1:-msg}" -v SUMMARY="${FWLIVE_SUMMARY:-1}" -f "$CLASSIFY_AWK"',
	'}',
	'',
	'is_firewall_event_msg() {',
	'\t_r=$(printf \'%s\' "$1" | _fwlive_run_classify msg)',
	'\t[ "$_r" = 1 ]',
	'}',
	'',
	'_fwlive_filter_json_entries() {',
	'\t_fwlive_run_classify json',
	'}',
	'',
	'_fwlive_filter_json_reply() {',
	'\t_fwlive_run_classify json_reply',
	'}',
	''
].join('\n');

if (process.argv.length > 2 && process.argv[2] !== '--awk') {
	console.error('usage: gen-shell-classifier.js [--awk]');
	process.exit(2);
}
process.stdout.write(process.argv[2] === '--awk' ? awkOut : out);
