#!/usr/bin/env node
'use strict';

/**
 * Emit POSIX fwlive-is-firewall-event.sh from core CLASSIFY_SPEC.
 * Usage: node scripts/gen-shell-classifier.js > path/to/fwlive-is-firewall-event.sh
 *
 * The generated classifier is one BusyBox-awk program (constant process
 * count per poll, not O(entries)). is_firewall_event_msg stays as the
 * single-message API for tests / z3; the filter uses MODE=json.
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
		'BEGIN { if (MODE != "json") ORS = "" }',
		'{',
		'\tif (MODE == "json") {',
		'\t\tmsg = json_get_msg($0)',
		'\t\tif (is_fw(msg)) {',
		'\t\t\tif (out_n++) printf ","',
		'\t\t\tprintf "%s", $0',
		'\t\t}',
		'\t\tnext',
		'\t}',
		'\tbuf = (NR == 1) ? $0 : buf "\\n" $0',
		'}',
		'END {',
		'\tif (MODE != "json")',
		'\t\tprint is_fw(buf) ? 1 : 0',
		'}'
	].join('\n');
}

const awkBody = emitAwkProgram();

const out = [
	'# SPDX-License-Identifier: Apache-2.0',
	'# Copyright 2025-2026 Lucas Albers <lucas.b.albers@gmail.com>',
	'#',
	'# GENERATED FILE — do not edit. Run: ./scripts/gen-all.sh',
	'# source: core/fwlive-log.js CLASSIFY_SPEC',
	'# Shared isFirewallEvent parity logic (shell). Sourced by fwlive-log-filter.sh and tests.',
	'# Sourced library: do not add set -euo here (callers own strict mode, #291 C3).',
	'# One awk process classifies a batch (MODE=json) or one message (default).',
	'',
	'_fwlive_run_classify() {',
	'\tawk -v MODE="${1:-msg}" "$(cat <<\'AWK\'',
	awkBody,
	'AWK',
	')"',
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
	''
].join('\n');

process.stdout.write(out);
